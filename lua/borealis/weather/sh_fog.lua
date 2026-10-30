local PS, VS = "borealis_fog_ps30", "borealis_fog_vs30"
local NOISE = "shaderpack/procsky/fognoise"

if SERVER then
	shaderpack.AddResources({ VS, PS }, { NOISE })

	return
end

local fog = shaderpack.fog or {}
shaderpack.fog = fog

local cover, depthslices = shaderpack.cover, shaderpack.depthslices
local FOG_ENABLED = CreateClientConVar("cl_draw_fog", "0", true, false, "draw volumetric fog in fog, rain and snow weather")

local PROFILES = {
	fog = { density = 0.0002, falloff = 250, noise = 0.8 },
	rain = { density = 0.00025, falloff = 600, noise = 0.4 },
	snow = { density = 0.0002, falloff = 700, noise = 0.5 },
}
local SUN_GAIN = 1
local VOLUMETRIC_WEATHERS = { rain = true, fog = true, snow = true }
local BASE_HEIGHT = 40
local BASE_RATE = 0.5
local BASE_TRACE_INTERVAL = 0.25

local MAT
local materialSerial = 0

local function build()
	materialSerial = materialSerial + 1
	MAT = CreateShaderMaterial("borealis_fog_" .. os.time() .. "_" .. materialSerial, {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$texture2"] = NOISE,
		["$linearread_basetexture"] = 0,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
		["$linearread_texture4"] = 1,
		["$linearread_texture5"] = 1,
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

local toLinear, setConstant = shaderpack.ToLinear, shaderpack.SetConstant

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

local function currentBase()
	local now = RealTime()
	if now >= nextTrace then
		nextTrace = now + BASE_TRACE_INTERVAL
		local eye = EyePos()
		local tr = util.TraceLine({ start = eye, endpos = eye - Vector(0, 0, 4000), mask = MASK_SOLID_BRUSHONLY })
		if tr.Hit then targetBase = tr.HitPos.z + BASE_HEIGHT end
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
		local eye = EyePos()
		cover.Update(eye)
		cover.UpdateExposure(eye)
	end
end

local quadColor = Color(SUN_GAIN * 255, 0, 0, 255)
local extra = Matrix()
local ORDER = 20

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
	local exposure, ex, ey, einv, ez = cover.Exposure()
	MAT:SetTexture("$texture5", exposure or coverRT)
	extra:SetField(2, 1, ex or 0)
	extra:SetField(2, 2, ey or 0)
	extra:SetField(2, 3, einv or 0)
	extra:SetField(2, 4, ez or 0)
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

local function stop()
	hook.Remove("Think", "borealis_fog")
	hook.Remove("PreRender", "borealis_fog")
	hook.Remove("PreDrawTranslucentRenderables", "borealis_fog")
	depthslices.RemoveEffect("borealis_fog")
	active = false
	if tod and tod.SetVolumetricFog then
		tod.SetVolumetricFog(nil)
	end
end

local function start()
	stop()
	hook.Add("Think", "borealis_fog", think)
	hook.Add("PreRender", "borealis_fog", prepare)
	depthslices.AddEffect("borealis_fog", ORDER, draw, true, function() return active end)
end

shaderpack.Toggle("borealis_fog", FOG_ENABLED, { PS, VS, unpack(cover.EXPOSURE_SHADERS) }, start, stop, { NOISE })()
