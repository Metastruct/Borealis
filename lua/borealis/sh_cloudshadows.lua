local PS, VS = "cloudshadows_slab_ps30", "fog_vs30"

if SERVER then
	shaderpack.AddResources({ VS, PS }, { "materials/shaderpack/procsky/cloudshape.vtf", "materials/shaderpack/procsky/clouddetail.vtf" })

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
-- engine's depth pass.
--
-- The 3D skybox's geometry is in the frame with its own main-view depth, which
-- puts it past the shader's distance fade, so it keeps out of this.

local procsky, vclouds, depthslices = shaderpack.procsky, shaderpack.vclouds, shaderpack.depthslices

-- How far a fully covered pixel goes toward the shader's shadow colour.  Past 1
-- it overshoots that colour and keeps going darker, which is where the shade
-- starts to read at the coverage this map runs: 0.85 took only 17 percent off
-- the red channel, spread evenly over the frame with no lit ground beside it,
-- and that is invisible.  Picked by eye in play; 2.5 would take red to zero.
local STRENGTH = 2.0

-- The sun ray to the slab is (height / sun.z) long, so a sun near the horizon
-- drags one cloud's shade across the whole map.  Shade fades out well before
-- that, which also costs the low sun the shadows it would throw the furthest.
local MIN_ELEV, FADE_ELEV = 2, 10 -- degrees of sun elevation: nothing at MIN, full at MIN + FADE
local ORDER = 5 -- the farthest volume: the clouds and then the fog composite over this
local TIME_WRAP = 3600 -- the same clock sh_vclouds sends, or the two disagree on where a cloud is

--------------------------------------------------------------------------
-- material, a new one every start so a kept one never lacks a constant
--------------------------------------------------------------------------
local MAT
local materialSerial = 0

local function build()
	materialSerial = materialSerial + 1
	MAT = CreateShaderMaterial("ms_cloudshadows_" .. os.time() .. "_" .. materialSerial, {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$texture2"] = "shaderpack/procsky/cloudshape",
		["$texture3"] = "shaderpack/procsky/clouddetail",
		["$linearread_basetexture"] = 0,
		["$linearread_texture1"] = 1, -- depth and both volumes are data
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
		["$linearwrite"] = 0,
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
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

	return sun, shaderpack.Elevation(sun)
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
	local overcast = shaderpack.Overcast()
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
local quadColor = Color(255, 255, 0, 255) -- blue is the MSAA sample count, past 64 the shader's debug view

local function draw()
	if not active then return end

	if not MAT and not build() then return end

	local eye = EyePos()
	local fwd = EyeAngles():Forward()
	shaderpack.SetConstant(MAT, "$c0", eye.x, eye.y, eye.z, CurTime() % TIME_WRAP)
	shaderpack.SetConstant(MAT, "$c1", fwd.x, fwd.y, fwd.z, layerZ)
	shaderpack.SetConstant(MAT, "$c2", sunDir.x, sunDir.y, sunDir.z, coverage)
	MAT:SetFloat("$c3_w", gain)
	quadColor.b = depthslices.Samples()
	depthslices.Composite(MAT, quadColor)
end

--------------------------------------------------------------------------
-- lifecycle
--------------------------------------------------------------------------
local function stop()
	hook.Remove("Think", "ms_cloudshadows")
	depthslices.RemoveEffect("ms_cloudshadows")
	active = false
end

local function start()
	stop()
	MAT = nil
	hook.Add("Think", "ms_cloudshadows", update)
	depthslices.AddEffect("ms_cloudshadows", ORDER, draw, false, function() return active end)
end

shaderpack.WhenMounted("ms_cloudshadows", { PS, VS }, start)
