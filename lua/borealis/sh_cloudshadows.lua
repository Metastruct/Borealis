local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

if SERVER then
	if not resource.AddShader then return end

	resource.AddShader("fog_vs30")
	resource.AddShader("cloudshadows_slab_ps30")
	resource.AddFile("materials/procsky/cloudshape.vtf")
	resource.AddFile("materials/procsky/clouddetail.vtf")

	return
end

-- Cloud shadows: the shade sh_vclouds' slab throws on the world, marched by
-- cloudshadows_slab_ps30 and composited over the frame before the clouds and
-- the fog, so the layer and the haze sit over shaded ground instead of under
-- it.
--
-- The placement and the coverage come from vclouds.GetLayer, so the shade on
-- the ground belongs to the same field sh_vclouds is drawing overhead rather
-- than to a second guess at it.  Every scale, wind and cut in the shader
-- matches vclouds_ps30 for the same reason.
--
-- Only the volumetric slab casts.  The flat skybox deck (sh_tod_build) does
-- not: its own cut is smoothstep(t, t + 0.38) over a 4 octave fbm that sits
-- tightly around 0.5, so its shade is structurally capped near nothing and
-- was invisible in play.  So this has no switch of its own and follows
-- cl_draw_vclouds: with no slab overhead there is nothing to cast, update
-- leaves it inactive, and it then asks for no depth pass and draws no quad.
--
-- The shader shares the fog's vertex shader (a near-plane quad passing its
-- world and clip position) and rebuilds each pixel's world position from the
-- engine's depth pass.  It does not use the slice capture: one log spaced
-- index is far too coarse to rebuild a position from, and shade sampled
-- hundreds of units off looks worse than none, so what the depth pass misses
-- (PAC3 parts, clientside models) goes unshaded.
--
-- The 3D skybox's geometry is in the frame with its own main-view depth, which
-- puts it past the shader's distance fade, so it keeps out of this.

-- How far a fully covered pixel goes toward the shader's shadow colour.  Past 1
-- it overshoots that colour and keeps going darker, which is where the shade
-- starts to read at the coverage this map runs: 0.85 took only 17 percent off
-- the red channel, spread evenly over the frame with no lit ground beside it,
-- and that is invisible.  Picked by eye in play; 2.5 would take red to zero.
local STRENGTH = 4.0

-- The sun ray to the slab is (height / sun.z) long, so a sun near the horizon
-- drags one cloud's shade across the whole map.  Shade fades out well before
-- that, which also costs the low sun the shadows it would throw the furthest.
local MIN_ELEV, FADE_ELEV = 2, 10 -- degrees of sun elevation: nothing at MIN, full at MIN + FADE
local NEAR = 12 -- the quad sits this far in front of the eye
local QUAD_OVERSIZE = 6 -- sized past the frustum, the shader uses the clip position
local ORDER = 5 -- the farthest volume: the clouds and then the fog composite over this
local TIME_WRAP = 3600 -- the same clock sh_vclouds sends, or the two disagree on where a cloud is
local PS, VS = "cloudshadows_slab_ps30", "fog_vs30"

--------------------------------------------------------------------------
-- material, a new one every start so a kept one never lacks a constant
--------------------------------------------------------------------------
local MAT
local materialSerial = 0

-- The render targets do not exist yet while the map loads, and asking for one
-- then hands back a 32 x 32 error texture that answers IsError with false.
-- Bound as the depth, every pixel reads as one distance and the whole frame
-- takes the same shade.
local function usableRT(t)
	return t ~= nil and not t:IsError() and t:Width() > 64
end

local function build()
	materialSerial = materialSerial + 1
	MAT = CreateMaterial("ms_cloudshadows_" .. os.time() .. "_" .. materialSerial, "screenspace_general", {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$basetexture"] = "",
		["$texture1"] = "",
		["$texture2"] = "procsky/cloudshape",
		["$texture3"] = "procsky/clouddetail",
		["$linearread_basetexture"] = 0,
		["$linearread_texture1"] = 1, -- depth and both volumes are data
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
		["$linearwrite"] = 0,
		["$ignorez"] = 1,
		["$vertexcolor"] = 1,
		["$vertextransform"] = 1,
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
		["<dx90"] = { ["$no_draw"] = 1 },
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 1, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})

	return true
end

--------------------------------------------------------------------------
-- what is overhead, and how hard it shades
--------------------------------------------------------------------------
local active = false
local layerZ, coverage, gain = 0, 0, 0
local sunDir = Vector(0, 0, 1)

-- direction to the sun and its elevation in degrees
local function sunInfo()
	if procsky and procsky.GetLights then
		local sun, _, elev = procsky.GetLights()

		return sun, elev
	end

	local params = tod and tod.CurrentParams
	local sun = params and isangle(params.sun_angles) and -params.sun_angles:Forward() or Vector(0, 0, 1)

	return sun, math.deg(math.asin(math.Clamp(sun.z, -1, 1)))
end

local function update()
	if not (vclouds and vclouds.GetLayer) then
		active = false

		return
	end

	local z, cover = vclouds.GetLayer()
	if not z then
		active = false

		return
	end

	local sun, elev = sunInfo()
	-- a closed sky has no shaft of direct light left for a cloud to interrupt
	local overcast = procsky and procsky.GetOvercast and procsky.GetOvercast() or 0
	local g = STRENGTH * math.Clamp((elev - MIN_ELEV) / FADE_ELEV, 0, 1) * (1 - overcast)
	if g <= 0.001 then
		active = false

		return
	end

	layerZ, coverage, gain, sunDir = z, cover, g, sun
	active = true
end

--------------------------------------------------------------------------
-- rendering
--------------------------------------------------------------------------
local quadColor = Color(255, 255, 0, 255) -- blue is the shader's debug view, off

local function draw()
	if not active then return end

	-- rebound every frame: the targets are recreated across a map change and a
	-- material built before they existed holds the error texture forever
	local depth, fb = render.GetResolvedFullFrameDepth(), render.GetScreenEffectTexture()
	if not usableRT(depth) or not usableRT(fb) then return end
	if not MAT and not build() then return end

	local eye = EyePos()
	local fwd = EyeAngles():Forward()
	local vs = render.GetViewSetup()
	local halfW = math.tan(math.rad(vs.fov) * 0.5)
	local halfH = halfW / vs.aspect

	render.UpdateScreenEffectTexture()
	MAT:SetTexture("$texture1", depth)
	MAT:SetTexture("$basetexture", fb)

	MAT:SetFloat("$c0_x", eye.x)
	MAT:SetFloat("$c0_y", eye.y)
	MAT:SetFloat("$c0_z", eye.z)
	MAT:SetFloat("$c0_w", CurTime() % TIME_WRAP)
	MAT:SetFloat("$c1_x", fwd.x)
	MAT:SetFloat("$c1_y", fwd.y)
	MAT:SetFloat("$c1_z", fwd.z)
	MAT:SetFloat("$c1_w", layerZ)
	MAT:SetFloat("$c2_x", sunDir.x)
	MAT:SetFloat("$c2_y", sunDir.y)
	MAT:SetFloat("$c2_z", sunDir.z)
	MAT:SetFloat("$c2_w", coverage)
	MAT:SetFloat("$c3_w", gain)

	-- alpha writes stay off so the slice indices survive for the next effect;
	-- sh_depthslices puts the frame's alpha back after the translucent pass
	depthslices.KeepAlpha(function()
		render.OverrideDepthEnable(true, false)
		render.SetMaterial(MAT)
		render.DrawQuadEasy(eye + fwd * NEAR, -fwd, halfW * NEAR * QUAD_OVERSIZE, halfH * NEAR * QUAD_OVERSIZE, quadColor, 0)
		render.OverrideDepthEnable(false, false)
	end)
end

--------------------------------------------------------------------------
-- lifecycle
--------------------------------------------------------------------------
local function stop()
	hook.Remove("Think", "ms_cloudshadows")
	hook.Remove("NeedsDepthPass", "ms_cloudshadows")
	depthslices.RemoveEffect("ms_cloudshadows")
	active = false
end

local function start()
	stop()
	MAT = nil
	hook.Add("Think", "ms_cloudshadows", update)
	-- NeedsDepthPass takes the FIRST non-nil return of all its hooks, so
	-- returning false here would cancel another consumer's true and leave the
	-- depth buffer stale.  Ask when it is needed, stay silent otherwise.
	hook.Add("NeedsDepthPass", "ms_cloudshadows", function()
		if active then return true end
	end)
	depthslices.AddEffect("ms_cloudshadows", ORDER, draw)
end

local function shadersAvailable()
	return file.Exists("shaders/fxc/" .. PS .. ".vcs", "GAME") and file.Exists("shaders/fxc/" .. VS .. ".vcs", "GAME")
end

local function apply()
	if shadersAvailable() then
		start()
	elseif HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
		hook.Add("ShaderMounted", "ms_cloudshadows", function()
			hook.Remove("ShaderMounted", "ms_cloudshadows")
			if shadersAvailable() then
				start()
			end
		end)
	end
end

hook.Remove("ShaderMounted", "ms_cloudshadows")
apply()
