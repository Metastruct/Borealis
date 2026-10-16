local PS, VS = "fog_ps30", "fog_vs30"

if SERVER then
	shaderpack.AddResources({ VS, PS }, { "materials/shaderpack/procsky/fognoise.vtf" })

	return
end

-- Volumetric fog: a height layer ray marched per pixel by fog_ps30 and
-- composited over the frame before the translucent pass, so glass, particles
-- and the viewmodel draw on top.  Depth comes from two sources and the nearer
-- wins: the engine's depth pass (exact, but only what the engine draws) and the
-- coarse slice capture in sh_depthslices, shared with the volumetric clouds, so
-- Lua-drawn things like PAC3 parts occlude the fog too.
--
-- Density follows tod's weather: fog weather (tod.fog) is a ground layer,
-- rain (tod.rain) a taller thin haze, the two profiles blended by their share
-- of the total.  The base follows the ground under the player.  Colour is the
-- horizon colour tod set as the engine fog colour.

local fog = shaderpack.fog or {}
shaderpack.fog = fog

local cover, depthslices = shaderpack.cover, shaderpack.depthslices
local FOG_ENABLED = CreateClientConVar("cl_draw_fog", "1", true, false, "draw volumetric fog in fog, rain and snow weather")

local PROFILES = { -- extinction per unit at the base, height falloff in units, noise strength
	fog = { density = 0.0002, falloff = 250, noise = 0.8 },
	rain = { density = 0.00025, falloff = 600, noise = 0.4 },
	snow = { density = 0.0002, falloff = 700, noise = 0.5 },
}
local SUN_GAIN = 1 -- sun in-scatter share, 0..1
local VOLUMETRIC_WEATHERS = { rain = true, fog = true, snow = true }
local BASE_LIFT = 40 -- fog base above the ground under the player
local BASE_RATE = 0.5 -- share of the remaining gap closed per second when the ground changes
local BASE_TRACE_INTERVAL = 0.25

--------------------------------------------------------------------------
-- material, a new one every start so a kept one never lacks a constant
--------------------------------------------------------------------------
local MAT
local materialSerial = 0

local function build()
	materialSerial = materialSerial + 1
	MAT = CreateShaderMaterial("ms_fog_" .. os.time() .. "_" .. materialSerial, {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$texture2"] = "shaderpack/procsky/fognoise",
		["$linearread_basetexture"] = 0,
		["$linearread_texture1"] = 1, -- depth and noise are data
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
		["$linearread_texture4"] = 1,
		["$linearwrite"] = 0,
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 1, ["$c2_w"] = 0,
		["$c3_x"] = 1, ["$c3_y"] = 1, ["$c3_z"] = 1, ["$c3_w"] = 1,
	}, "screenspace_general_8tex")
	return true
end

--------------------------------------------------------------------------
-- weather, sun and base
--------------------------------------------------------------------------
local toLinear, setConstant = shaderpack.ToLinear, shaderpack.SetConstant

-- total density and the density-weighted falloff and noise strength, or 0
local function weather()
	if not tod then return 0 end

	local density, falloff, noise = 0, 0, 0
	for name, profile in pairs(PROFILES) do
		local w = tod[name]
		local d = profile.density * (w and w.amount or 0)
		density = density + d
		falloff = falloff + profile.falloff * d
		noise = noise + profile.noise * d
	end

	if density <= 0 then return 0 end

	return density, falloff / density, noise / density
end

local base, targetBase, nextTrace = nil, nil, 0

-- eased so level changes on stacked maps do not snap the layer
local function currentBase()
	local now = RealTime()
	if now >= nextTrace then
		nextTrace = now + BASE_TRACE_INTERVAL
		local eye = EyePos()
		local tr = util.TraceLine({ start = eye, endpos = eye - Vector(0, 0, 4000), mask = MASK_SOLID_BRUSHONLY })
		if tr.Hit then targetBase = tr.HitPos.z + BASE_LIFT end
	end
	if not targetBase then return base or EyePos().z - 24 end
	if not base then base = targetBase end
	base = base + (targetBase - base) * math.min(1, RealFrameTime() * BASE_RATE)

	return base
end

local active = false

local function think()
	active = weather() > 0
	if tod and tod.SetVolumetricFog and tod.volumetric_fog ~= VOLUMETRIC_WEATHERS then
		tod.SetVolumetricFog(VOLUMETRIC_WEATHERS)
	end
end

function fog.Layer()
	if not active or not base then return 0, 1, 0 end

	local density, falloff = weather()
	if density <= 0 then return 0, 1, 0 end

	return density, falloff, base
end

local function prepare()
	if active then
		cover.Update(EyePos())
	end
end

--------------------------------------------------------------------------
-- rendering
--------------------------------------------------------------------------
local quadColor = Color(SUN_GAIN * 255, 0, 0, 255)
local extra = Matrix()
local ORDER = 20 -- the near volume: this composites over the clouds

local function draw()
	local density, falloff, noise = weather()
	if density <= 0 then return end

	local coverRT = cover.Texture()
	if not coverRT then return end

	if not MAT and not build() then return end

	MAT:SetTexture("$texture3", coverRT)
	local spans = cover.Spans()
	MAT:SetTexture("$texture4", spans or coverRT)
	extra:SetField(1, 1, spans and 1 or 0)
	MAT:SetMatrix("$viewprojmat", extra)

	local eye = EyePos()
	local fwd = EyeAngles():Forward()
	local sun = shaderpack.SunDir()
	local tonemap = render.GetToneMappingScaleLinear().x
	local fr, fg, fb = render.GetFogColor()

	setConstant(MAT, "$c0", eye.x, eye.y, eye.z, density)
	setConstant(MAT, "$c1", fwd.x, fwd.y, fwd.z, CurTime() % 3600)
	setConstant(MAT, "$c2", sun.x, sun.y, sun.z, currentBase())
	setConstant(MAT, "$c3", toLinear(fr) * tonemap, toLinear(fg) * tonemap, toLinear(fb) * tonemap, falloff)
	quadColor.g = noise * 255
	quadColor.b = depthslices.Samples()

	return depthslices.Composite(MAT, quadColor)
end

--------------------------------------------------------------------------
-- lifecycle
--------------------------------------------------------------------------
local function stop()
	hook.Remove("Think", "ms_fog")
	hook.Remove("PreRender", "ms_fog")
	hook.Remove("PreDrawTranslucentRenderables", "ms_fog")
	depthslices.RemoveEffect("ms_fog")
	active = false
	if tod and tod.SetVolumetricFog then
		tod.SetVolumetricFog(nil)
	end
end

local function start()
	stop()
	hook.Add("Think", "ms_fog", think)
	hook.Add("PreRender", "ms_fog", prepare)
	depthslices.AddEffect("ms_fog", ORDER, draw, true, function() return active end)
end

shaderpack.Toggle("ms_fog", FOG_ENABLED, { PS, VS }, start, stop)()
