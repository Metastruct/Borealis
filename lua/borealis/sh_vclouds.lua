local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

if SERVER then
	if not resource.AddShader then return end

	resource.AddShader("fog_vs30")
	resource.AddShader("vclouds_ps30")
	resource.AddFile("materials/procsky/cloudshape.vtf")
	resource.AddFile("materials/procsky/clouddetail.vtf")

	return
end

-- Volumetric clouds: a world-space slab ray marched by vclouds_ps30 and
-- composited over the frame before the translucent pass, so the clouds live in
-- the world instead of the skybox: geometry occludes them, they have real
-- perspective, and flying into the layer puts the camera inside them.
--
-- Off by default, and while on it replaces the skybox deck (sh_tod_build reads
-- vclouds.IsActive).  The slab's height comes from the level the eye is in, see
-- BASE_OVER_FLOOR below.
--
-- It shares the fog's vertex shader (a near-plane quad passing its world and
-- clip position) and the fog's depth handling twice over: the engine's depth
-- pass (exact, but only what the engine draws, and sky pixels there are exactly
-- 1.0) and a coarse slice capture of the real frame, so things drawn from Lua
-- hooks (PAC3 parts, clientside models) occlude the clouds too.  The nearer of
-- the two wins.  The slice capture lives in sh_depthslices and is shared with
-- the fog, so whichever draws first pays for it and both read the same alpha.
--
-- The engine fogs the world and never this quad, so the shader fogs the clouds
-- itself off the engine's own ramp, and sh_depthslices composites them before
-- the volumetric fog, which is the nearer volume.  Without either one a far
-- layer hangs in front of the haze instead of dissolving into it.
--
-- The slab's thickness and density are art values inside vclouds_ps30, next to
-- the rest of its shape, because the material has four constants and they are
-- spent on what changes per frame.

local ENABLED = CreateClientConVar("cl_draw_vclouds", "0", true, false, "draw volumetric clouds instead of the skybox deck")

-- The slab stands this far over the floor of whichever outdoor level the camera
-- is in (sh_skylevels), which puts it inside the build area's own air, the one
-- place where flying into the layer makes sense, and over the sky of the
-- fishing level, which has barely 3000 units of air beneath it.  Sitting above
-- a sky costs nothing, since sky pixels never clip the march.
local BASE_OVER_FLOOR = 5000 -- unless the level hangs its layer by the top
local THICK = 3500 -- the slab's own thickness, which lives in vclouds_ps30
local SKY_BASE = 3000 -- slab base outside every level
-- Coverage drifts instead of sitting still, and sits low most of the time: two
-- slow sines with periods that do not divide into each other, so the pattern
-- never repeats cleanly, off a wall clock every client shares.  Weather takes
-- it over entirely, which is the only time the flat deck closes up either.
local COVERAGE_BASE = 0.38 -- 0 clear, 1 solid
local COVERAGE_SWING = 0.1 -- how far it wanders either side of the base
local COVERAGE_OVERCAST = 0.8 -- where tod's rain and snow take it
local COVERAGE_PERIOD_A = 1200 -- seconds
local COVERAGE_PERIOD_B = 1900
-- procsky's moon light is an art value tuned for the flat deck, ~200x its own
-- night ambient, and a volumetric integrates it over a whole cloud, so direct
-- light fades to this share once the sun is well down
local NIGHT_GAIN = 0.2
local NIGHT_ELEV = -6 -- sun elevation, in degrees, where NIGHT_GAIN is reached
local NEAR = 12 -- the quad sits this far in front of the eye
local QUAD_OVERSIZE = 6 -- sized past the frustum, the shader uses the clip position
local LOG_RANGE = 12 -- light scales span 2^-12 .. 2^12, matches vclouds_ps30
local PS, VS = "vclouds_ps30", "fog_vs30"

vclouds = vclouds or {}

local active = false

function vclouds.IsActive()
	return active
end

--------------------------------------------------------------------------
-- material, rebuilt on every start so a kept one never lacks a constant
--------------------------------------------------------------------------
local MAT
local materialSerial = 0

-- the render targets do not exist while the map loads, and asking then hands
-- back a 32 x 32 error texture that answers IsError with false
local function usableRT(t)
	return t ~= nil and not t:IsError() and t:Width() > 64
end

local function build()
	materialSerial = materialSerial + 1
	MAT = CreateMaterial("ms_vclouds_" .. os.time() .. "_" .. materialSerial, "screenspace_general", {
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
		["$c3_x"] = 0, ["$c3_y"] = 1, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})

	return true
end

--------------------------------------------------------------------------
-- placement and lighting
--------------------------------------------------------------------------
local TAU = math.pi * 2

local function coverage()
	local t = os.time()
	local wander = (math.sin(t / COVERAGE_PERIOD_A * TAU) + math.sin(t / COVERAGE_PERIOD_B * TAU)) * 0.5
	local base = COVERAGE_BASE + COVERAGE_SWING * wander
	local overcast = procsky and procsky.GetOvercast and procsky.GetOvercast() or 0

	return Lerp(overcast, base, COVERAGE_OVERCAST)
end

local function baseZ()
	local lvl = skylevels and skylevels.Get()

	if not lvl then return SKY_BASE end

	return lvl.clouds and lvl.clouds - THICK or lvl.floor + BASE_OVER_FLOOR
end

local function packColor(r, g, b)
	return math.floor(math.Clamp(r, 0, 1) * 255) * 65536 + math.floor(math.Clamp(g, 0, 1) * 255) * 256 + math.floor(math.Clamp(b, 0, 1) * 255)
end

-- a colour splits into an 8 bit hue and a log encoded scale: one 8 bit triple
-- cannot hold both a midday sun and a moonlit ambient of 0.002
local function encodeScale(s)
	return math.Clamp((math.log(math.max(s, 1e-6), 2) / LOG_RANGE + 1) * 0.5, 0, 1)
end

local function splitColor(c, gain)
	local m = math.max(c[1], c[2], c[3]) * gain
	if m <= 0 then return 0, 0 end

	return packColor(c[1] * gain / m, c[2] * gain / m, c[3] * gain / m), encodeScale(m)
end

local FOG_START_STEP, FOG_RANGE_STEP = 64, 128
local fogLinear = { 0, 0, 0 }

local function toLinear(c)
	c = c / 255

	return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

-- The same fog the engine gave the world: a hue and a log scale like the light,
-- and one packed float holding the start in 64 unit steps, the range in 128 unit
-- steps and the max density in 8 bits, which is 24 bits, all a mantissa carries
-- exactly.  Nothing reads the max density back out of the engine, so it comes
-- from tod's own config, and 1 without it: the fog the world got, not less.
local function fogRamp(tonemap)
	if render.GetFogMode() == MATERIAL_FOG_NONE then return 0, 0, 0 end
	local params = tod and tod.CurrentParams
	local maxDensity = math.Clamp(params and params.fog_max_density or 1, 0, 1)
	if maxDensity <= 0 then return 0, 0, 0 end

	local r, g, b = render.GetFogColor()
	fogLinear[1], fogLinear[2], fogLinear[3] = toLinear(r), toLinear(g), toLinear(b)
	local hue, scale = splitColor(fogLinear, tonemap)
	local first, last = render.GetFogDistances()
	local start = math.Clamp(math.floor(first / FOG_START_STEP), 0, 255)
	local range = math.Clamp(math.floor((last - first) / FOG_RANGE_STEP), 1, 255)

	return hue, start * 65536 + range * 256 + math.floor(maxDensity * 255), scale
end

local WHITE = { 1, 1, 1 }
local SKY_BLUE = { 0.35, 0.45, 0.62 }

local nightLight = { 0, 0, 0 }

-- direction to the sun and the cloud lighting procsky already derives, with
-- the direct term pulled down once the sun is below the horizon
local function lighting()
	if procsky and procsky.GetCloudLighting then
		local dir, light, amb = procsky.GetCloudLighting()
		local _, _, elev = procsky.GetLights()
		local gain = Lerp(math.Clamp(elev / NIGHT_ELEV, 0, 1), 1, NIGHT_GAIN)
		if gain < 1 then
			for i = 1, 3 do
				nightLight[i] = light[i] * gain
			end

			return dir, nightLight, amb
		end

		return dir, light, amb
	end

	local params = tod and tod.CurrentParams
	local sun = params and isangle(params.sun_angles) and -params.sun_angles:Forward() or Vector(0, 0, 1)

	return sun, WHITE, SKY_BLUE
end

--------------------------------------------------------------------------
-- rendering
--------------------------------------------------------------------------
local quadColor = Color(255, 255, 0, 255)
local ORDER = 10 -- the far volume: the fog composites over these

local function draw()
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
	local sun, light, amb = lighting()
	local tonemap = render.GetToneMappingScaleLinear().x
	local lightHue, lightScale = splitColor(light, tonemap)
	local ambHue, ambScale = splitColor(amb, tonemap)
	local fogHue, fogPacked, fogScale = fogRamp(tonemap)

	depthslices.Capture()
	render.UpdateScreenEffectTexture()
	MAT:SetTexture("$texture1", depth)
	MAT:SetTexture("$basetexture", fb)

	MAT:SetFloat("$c0_x", eye.x)
	MAT:SetFloat("$c0_y", eye.y)
	MAT:SetFloat("$c0_z", eye.z)
	MAT:SetFloat("$c0_w", lightHue)
	MAT:SetFloat("$c1_x", fwd.x)
	MAT:SetFloat("$c1_y", fwd.y)
	MAT:SetFloat("$c1_z", fwd.z)
	MAT:SetFloat("$c1_w", CurTime() % 3600)
	MAT:SetFloat("$c2_x", sun.x)
	MAT:SetFloat("$c2_y", sun.y)
	MAT:SetFloat("$c2_z", sun.z)
	MAT:SetFloat("$c2_w", ambHue)
	MAT:SetFloat("$c3_x", baseZ())
	MAT:SetFloat("$c3_y", fogHue)
	MAT:SetFloat("$c3_z", coverage())
	MAT:SetFloat("$c3_w", fogPacked)

	quadColor.r = ambScale * 255
	quadColor.g = lightScale * 255
	quadColor.a = fogScale * 255

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
	hook.Remove("NeedsDepthPass", "ms_vclouds")
	hook.Remove("PreDrawTranslucentRenderables", "ms_vclouds")
	hook.Remove("RenderScreenspaceEffects", "ms_vclouds")
	depthslices.RemoveEffect("ms_vclouds")
	active = false
end

local function start()
	stop()
	active = true
	-- NeedsDepthPass takes the FIRST non-nil return of all its hooks, so
	-- returning false here would cancel another consumer's true and leave the
	-- depth buffer stale.  Ask when it is needed, stay silent otherwise.
	hook.Add("NeedsDepthPass", "ms_vclouds", function()
		if active then return true end
	end)
	depthslices.AddEffect("ms_vclouds", ORDER, draw)
end

local function shadersAvailable()
	return file.Exists("shaders/fxc/" .. PS .. ".vcs", "GAME") and file.Exists("shaders/fxc/" .. VS .. ".vcs", "GAME")
end

local function apply()
	if not ENABLED:GetBool() then
		stop()

		return
	end

	if shadersAvailable() then
		start()
	elseif HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
		hook.Add("ShaderMounted", "ms_vclouds", function()
			hook.Remove("ShaderMounted", "ms_vclouds")
			if ENABLED:GetBool() and shadersAvailable() then
				start()
			end
		end)
	end
end

cvars.RemoveChangeCallback("cl_draw_vclouds", "ms_vclouds")
cvars.AddChangeCallback("cl_draw_vclouds", apply, "ms_vclouds")
hook.Remove("ShaderMounted", "ms_vclouds")
apply()
