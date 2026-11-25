local PS, VS = "borealis_vclouds_ps30", "borealis_fog_vs30"
local LIGHT_PS, LIGHT_VS = "borealis_vcloudlight_ps30", "borealis_passthrough_vs30"
local SHAPE, DETAIL = "shaderpack/procsky/cloudshape", "shaderpack/procsky/clouddetail"

if SERVER then
	shaderpack.AddResources({ VS, PS, LIGHT_PS, LIGHT_VS }, { SHAPE, DETAIL })

	return
end

local vclouds = shaderpack.vclouds or {}
shaderpack.vclouds = vclouds
local procsky, cover, depthslices = shaderpack.procsky, shaderpack.cover, shaderpack.depthslices

local ENABLED = CreateClientConVar("borealis_vclouds", "0", true, false, "draw volumetric clouds instead of the skybox deck")

local BASE_OVER_FLOOR = 5000
local BASE_OVER_FLOOR_OVERCAST = 3200
local SKY_BASE = 3000
local SKY_BASE_OVERCAST = 1200
local COVERAGE_BASE = 0.38
local COVERAGE_SWING = 0.1
local COVERAGE_OVERCAST = 0.8
local COVERAGE_STRATUS = 0.93
local COVERAGE_PERIOD_A = 1200
local COVERAGE_PERIOD_B = 1900
local NIGHT_GAIN = 0.2
local NIGHT_ELEVATION = -6
local LOG_RANGE = 12
local EXPOSURE = 0.8
local OVERCAST_LIGHT = 0.3
local OVERCAST_AMB = 0.55
local OVERCAST_DENSITY = 2.5
local VOLUME_OVERCAST_LIGHT = 1.2
local VOLUME_OVERCAST_GREY = 0.7
local CLOUD_THICKNESS = 6000
local CIRRUS_ABOVE = 8000
local CIRRUS_WIND_X, CIRRUS_WIND_Y = 140, 52
local CIRRUS_MIN_OPACITY = 0.01

local active = false

function vclouds.IsActive()
	return active
end

local MAP_SIZE = 512
local MAP_EXTENT = 80000
local MAP_BAKE_EVERY = 4

local SKY3D_FAR_FRAC = 0.98
local SKY3D_ZFAR = 56755
local SKY3D_OVERSIZE = 6
local SKY3D_NEAR = 12
local RT_CLAMP = 4 + 8

local MAT, LIGHT_MAT, lightMap, sky3dMask
local materialSerial = 0
local cloudConstants = Matrix()
local mapOrigin = Vector()
local mapReady = false

local function build()
	materialSerial = materialSerial + 1
	local suffix = os.time() .. "_" .. materialSerial

	lightMap = GetRenderTargetEx("borealis_vcloudlight_" .. MAP_SIZE, MAP_SIZE, MAP_SIZE, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 12, 0, IMAGE_FORMAT_RGBA16161616F)
	if not shaderpack.UsableRT(lightMap, MAP_SIZE, MAP_SIZE) then
		lightMap = nil
		return false
	end

	MAT = CreateShaderMaterial("borealis_vclouds_" .. suffix, {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$texture2"] = SHAPE,
		["$texture3"] = DETAIL,
		["$linearread_basetexture"] = 0,
		["$linearread_texture1"] = 1,
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
		["$c3_x"] = 0, ["$c3_y"] = 1, ["$c3_z"] = 0, ["$c3_w"] = 0,
	}, "screenspace_general_8tex")
	MAT:SetTexture("$texture4", lightMap)

	LIGHT_MAT = CreateShaderMaterial("borealis_vcloudlight_" .. suffix, {
		["$pixshader"] = LIGHT_PS,
		["$vertexshader"] = LIGHT_VS,
		["$texture2"] = SHAPE,
		["$texture3"] = DETAIL,
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
		["$alpha_blend"] = 0,
		["$additive"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = MAP_EXTENT, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 1, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = MAP_SIZE, ["$c2_z"] = 0, ["$c2_w"] = 0,	})
	sky3dMask = nil
	mapReady = false

	return true
end

local TAU = math.pi * 2

local function coverage()
	local t = os.time()
	local wander = (math.sin(t / COVERAGE_PERIOD_A * TAU) + math.sin(t / COVERAGE_PERIOD_B * TAU)) * 0.5
	local base = COVERAGE_BASE + COVERAGE_SWING * wander
	local overcast = shaderpack.Overcast()

	return Lerp(overcast, base, COVERAGE_OVERCAST)
end

local function volumeCoverage()
	return Lerp(shaderpack.Overcast(), coverage(), COVERAGE_STRATUS)
end

local function densityGain()
	return Lerp(shaderpack.Overcast(), 1, OVERCAST_DENSITY)
end
local function baseZ()
	local lvl = cover and cover.SkyLevel()
	local overcast = shaderpack.Overcast()

	if not lvl then return Lerp(overcast, SKY_BASE, SKY_BASE_OVERCAST) end

	return lvl.floor + Lerp(overcast, BASE_OVER_FLOOR, BASE_OVER_FLOOR_OVERCAST)
end

function vclouds.GetLayer()
	if not active then return end

	return baseZ(), volumeCoverage()
end

local packColor, toLinear, setConstant = shaderpack.PackColor, shaderpack.ToLinear, shaderpack.SetConstant

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
local fogStart, fogRange, fogDensity = 0, 1, 0

local function readFog()
	fogDensity = 0
	if render.GetFogMode() == MATERIAL_FOG_NONE then return end
	local params = tod and tod.CurrentParams
	fogDensity = math.Clamp(params and params.fog_max_density or 1, 0, 1)
	if fogDensity <= 0 then return end

	local r, g, b = render.GetFogColor()
	fogLinear[1], fogLinear[2], fogLinear[3] = toLinear(r), toLinear(g), toLinear(b)
	local first, last = render.GetFogDistances()
	fogStart, fogRange = first, last - first
end

local function fogRamp(tonemap)
	readFog()
	if fogDensity <= 0 then return 0, 0, 0 end

	local hue, scale = splitColor(fogLinear, tonemap)
	local start = math.Clamp(math.floor(fogStart / FOG_START_STEP), 0, 255)
	local range = math.Clamp(math.floor(fogRange / FOG_RANGE_STEP), 1, 255)

	return hue, start * 65536 + range * 256 + math.floor(fogDensity * 255), scale
end

local WHITE = { 1, 1, 1 }
local SKY_BLUE = { 0.35, 0.45, 0.62 }

local litLight, litAmb = { 0, 0, 0 }, { 0, 0, 0 }

local function lighting()
	if procsky and procsky.GetCloudLighting then
		local dir, light, amb = procsky.GetCloudLighting()
		local _, _, elevation = procsky.GetLights()
		local overcast = shaderpack.Overcast()
		local gain = Lerp(math.Clamp(elevation / NIGHT_ELEVATION, 0, 1), 1, NIGHT_GAIN) * Lerp(overcast, 1, OVERCAST_LIGHT) * EXPOSURE
		local ambGain = Lerp(overcast, 1, OVERCAST_AMB) * EXPOSURE
		for i = 1, 3 do
			litLight[i] = light[i] * gain
			litAmb[i] = amb[i] * ambGain
		end

		return dir, litLight, litAmb
	end

	local params = tod and tod.CurrentParams
	local sun = params and isangle(params.sun_angles) and -params.sun_angles:Forward() or Vector(0, 0, 1)

	return sun, WHITE, SKY_BLUE
end

function vclouds.Layer(tonemap)
	local sun, light, amb = lighting()
	local lightHue, lightScale = splitColor(light, tonemap)
	local ambHue, ambScale = splitColor(amb, tonemap)

	return sun, lightHue, lightScale, ambHue, ambScale, baseZ(), coverage()
end

vclouds.Fog = fogRamp

local volLight, volAmb = { 0, 0, 0 }, { 0, 0, 0 }

local function greyed(out, c, grey, gain)
	local l = (c[1] * 0.2126 + c[2] * 0.7152 + c[3] * 0.0722) * grey
	for i = 1, 3 do
		out[i] = (c[i] * (1 - grey) + l) * gain
	end

	return out
end

local function volumeLayer(tonemap)
	local sun, light, amb = lighting()
	local overcast = shaderpack.Overcast()
	local grey = overcast * VOLUME_OVERCAST_GREY
	local lightHue, lightScale = splitColor(greyed(volLight, light, grey, Lerp(overcast, 1, VOLUME_OVERCAST_LIGHT)), tonemap)
	local ambHue, ambScale = splitColor(greyed(volAmb, amb, grey, 1), tonemap)

	return sun, lightHue, lightScale, ambHue, ambScale, baseZ()
end

local cirrusSun, cirrusAmb = { 0, 0, 0 }, { 0, 0, 0 }

function vclouds.Cirrus(eye, tonemap, m)
	local clouds = shaderpack.clouds
	if not active and not (clouds and clouds.IsActive()) then return end

	local overcast = shaderpack.Overcast()
	local height = baseZ() + CLOUD_THICKNESS + CIRRUS_ABOVE - eye.z
	if 1 - overcast < CIRRUS_MIN_OPACITY or height <= 0 then return end

	local _, light, amb = lighting()
	local grey = overcast * VOLUME_OVERCAST_GREY
	greyed(cirrusSun, light, grey, Lerp(overcast, 1, VOLUME_OVERCAST_LIGHT) * tonemap)
	greyed(cirrusAmb, amb, grey, tonemap)
	local time = CurTime() % 3600
	m:SetUnpacked(
		eye.x - CIRRUS_WIND_X * time, eye.y - CIRRUS_WIND_Y * time, height, 1 - overcast,
		cirrusSun[1], cirrusSun[2], cirrusSun[3], fogStart,
		cirrusAmb[1], cirrusAmb[2], cirrusAmb[3], math.max(fogRange, 1),
		fogLinear[1] * tonemap, fogLinear[2] * tonemap, fogLinear[3] * tonemap, fogDensity
	)

	return true
end

local quadColor = Color(255, 255, 0, 255)
local ORDER = 10
local lastEye

local function bakeLight()
	if not MAT and not build() then return end
	if mapReady and FrameNumber() % MAP_BAKE_EVERY ~= 0 then return end

	local eye = lastEye or EyePos()
	local texel = MAP_EXTENT / MAP_SIZE
	local sun = lighting()
	mapOrigin.x = math.Round(eye.x / texel) * texel
	mapOrigin.y = math.Round(eye.y / texel) * texel

	setConstant(LIGHT_MAT, "$c0", mapOrigin.x, mapOrigin.y, nil, CurTime() % 3600)
	setConstant(LIGHT_MAT, "$c1", sun.x, sun.y, sun.z, baseZ())
	setConstant(LIGHT_MAT, "$c2", volumeCoverage(), nil, densityGain(), shaderpack.Overcast())
	render.PushRenderTarget(lightMap)
	render.OverrideAlphaWriteEnable(true, true)
	render.SetMaterial(LIGHT_MAT)
	render.DrawScreenQuad()
	render.OverrideAlphaWriteEnable(false)
	render.PopRenderTarget()

	cloudConstants:SetUnpacked(
		mapOrigin.x, mapOrigin.y, 1 / MAP_EXTENT, 1,
		0, 0, 0, 0,
		0, 0, 0, 0,
		0, 0, 0, 0
	)
	mapReady = true
end

local ALPHA_CLEAR, ALPHA_OPAQUE = Color(0, 0, 0, 0), Color(255, 255, 255, 255)
local sky3dFrame = -1

local function sky3dMaskReady()
	local w, h = ScrW(), ScrH()
	if shaderpack.UsableRT(sky3dMask, w, h) then return true end

	local rt = GetRenderTargetEx("borealis_vclouds_sky3d_" .. w .. "x" .. h, w, h, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, RT_CLAMP, 0, IMAGE_FORMAT_RGBA8888)
	if not shaderpack.UsableRT(rt, w, h) then return false end

	sky3dMask = rt
	MAT:SetTexture("$texture5", rt)

	return true
end

local function captureSky3D(bDepth, _, b3DSky)
	if bDepth or not b3DSky or render.GetRenderTarget() then return end
	if not MAT and not build() then return end
	if not sky3dMaskReady() then return end

	local eye, fwd = EyePos(), EyeAngles():Forward()
	local halfW, halfH, vs = shaderpack.ViewTan()
	local near = math.max(SKY3D_NEAR, vs.znear * 1.5)
	local far = math.min(vs.zfar, SKY3D_ZFAR) * SKY3D_FAR_FRAC

	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	render.SetColorMaterial()

	render.OverrideDepthEnable(true, false)
	cam.IgnoreZ(true)
	render.DrawQuadEasy(eye + fwd * near, -fwd, halfW * near * SKY3D_OVERSIZE, halfH * near * SKY3D_OVERSIZE, ALPHA_CLEAR, 0)
	cam.IgnoreZ(false)
	render.DrawQuadEasy(eye + fwd * far, -fwd, halfW * far * SKY3D_OVERSIZE, halfH * far * SKY3D_OVERSIZE, ALPHA_OPAQUE, 0)
	render.CopyRenderTargetToTexture(sky3dMask)

	cam.IgnoreZ(true)
	render.DrawQuadEasy(eye + fwd * near, -fwd, halfW * near * SKY3D_OVERSIZE, halfH * near * SKY3D_OVERSIZE, ALPHA_OPAQUE, 0)
	cam.IgnoreZ(false)
	render.OverrideDepthEnable(false, false)

	render.OverrideBlend(false)
	render.OverrideAlphaWriteEnable(false, false)
	render.OverrideColorWriteEnable(false, false)
	sky3dFrame = FrameNumber()
end

local function draw()
	if not MAT and not build() then return end

	cloudConstants:SetField(2, 1, sky3dFrame == FrameNumber() and 1 or 0)
	cloudConstants:SetField(2, 2, densityGain())
	cloudConstants:SetField(2, 3, shaderpack.Overcast())
	MAT:SetMatrix("$viewprojmat", cloudConstants)

	local eye = EyePos()
	if bit.band(util.PointContents(eye), CONTENTS_SOLID) ~= 0 then return end

	lastEye = eye
	local fwd = EyeAngles():Forward()
	local tonemap = shaderpack.ToneMapScale()
	local sun, lightHue, lightScale, ambHue, ambScale, base = volumeLayer(tonemap)
	local cov = volumeCoverage()
	local fogHue, fogPacked, fogScale = fogRamp(tonemap)

	setConstant(MAT, "$c0", eye.x, eye.y, eye.z, lightHue)
	setConstant(MAT, "$c1", fwd.x, fwd.y, fwd.z, CurTime() % 3600)
	setConstant(MAT, "$c2", sun.x, sun.y, sun.z, ambHue)
	setConstant(MAT, "$c3", base, fogHue, cov, fogPacked)

	quadColor.r = ambScale * 255
	quadColor.g = lightScale * 255
	quadColor.b = depthslices.Samples()
	quadColor.a = fogScale * 255

	return depthslices.Composite(MAT, quadColor)
end

local function stop()
	hook.Remove("PreDrawTranslucentRenderables", "borealis_vclouds")
	hook.Remove("PostDrawTranslucentRenderables", "borealis_vclouds")
	hook.Remove("RenderScreenspaceEffects", "borealis_vclouds")
	hook.Remove("PreRender", "borealis_vclouds")
	depthslices.RemoveEffect("borealis_vclouds")
	active = false
end

local function start()
	stop()
	active = true
	mapReady = false
	hook.Add("PreRender", "borealis_vclouds", bakeLight)
	hook.Add("PostDrawTranslucentRenderables", "borealis_vclouds", captureSky3D)
	depthslices.AddEffect("borealis_vclouds", ORDER, draw, true, function() return active end)
end

shaderpack.Toggle("borealis_vclouds", ENABLED, { PS, VS, LIGHT_PS, LIGHT_VS }, start, stop, { SHAPE, DETAIL }, true)()
