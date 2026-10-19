local PS, VS = "vclouds_ps30", "fog_vs30"
local LIGHT_PS, LIGHT_VS = "vcloudlight_ps30", "aurora_vs30"

if SERVER then
	shaderpack.AddResources({ VS, PS, LIGHT_PS, LIGHT_VS }, { "materials/shaderpack/procsky/cloudshape.vtf", "materials/shaderpack/procsky/clouddetail.vtf" })

	return
end

local vclouds = shaderpack.vclouds or {}
shaderpack.vclouds = vclouds
local procsky, cover, depthslices = shaderpack.procsky, shaderpack.cover, shaderpack.depthslices

local ENABLED = CreateClientConVar("cl_draw_vclouds", "0", true, false, "draw volumetric clouds instead of the skybox deck")

local BASE_OVER_FLOOR = 5000
local SKY_BASE = 3000
local COVERAGE_BASE = 0.38
local COVERAGE_SWING = 0.1
local COVERAGE_OVERCAST = 0.8
local COVERAGE_PERIOD_A = 1200
local COVERAGE_PERIOD_B = 1900
local NIGHT_GAIN = 0.2
local NIGHT_ELEV = -6
local LOG_RANGE = 12
local EXPOSURE = 0.8
local OVERCAST_LIGHT = 0.3
local OVERCAST_AMB = 0.55

local active = false

function vclouds.IsActive()
	return active
end

local MAP_SIZE = 512
local MAP_EXTENT = 80000
local MAP_BAKE_EVERY = 4

local MAT, LIGHT_MAT, lightMap
local materialSerial = 0
local mapExtra = Matrix()
local mapOrigin = Vector()
local mapReady = false

local function build()
	materialSerial = materialSerial + 1
	local suffix = os.time() .. "_" .. materialSerial

	lightMap = GetRenderTargetEx("ms_vcloudlight_" .. MAP_SIZE, MAP_SIZE, MAP_SIZE, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 12, 0, IMAGE_FORMAT_RGBA16161616F)
	if not shaderpack.UsableRT(lightMap, MAP_SIZE, MAP_SIZE) then
		lightMap = nil
		return false
	end

	MAT = CreateShaderMaterial("ms_vclouds_" .. suffix, {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$texture2"] = "shaderpack/procsky/cloudshape",
		["$texture3"] = "shaderpack/procsky/clouddetail",
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

	LIGHT_MAT = CreateShaderMaterial("ms_vcloudlight_" .. suffix, {
		["$pixshader"] = LIGHT_PS,
		["$vertexshader"] = LIGHT_VS,
		["$texture2"] = "shaderpack/procsky/cloudshape",
		["$texture3"] = "shaderpack/procsky/clouddetail",
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
		["$alpha_blend"] = 0,
		["$additive"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = MAP_EXTENT, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 1, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = MAP_SIZE, ["$c2_z"] = 0, ["$c2_w"] = 0,
	})
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

local function baseZ()
	local lvl = cover and cover.SkyLevel()

	if not lvl then return SKY_BASE end

	return lvl.floor + BASE_OVER_FLOOR
end

function vclouds.GetLayer()
	if not active then return end

	return baseZ(), coverage()
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

local litLight, litAmb = { 0, 0, 0 }, { 0, 0, 0 }

local function lighting()
	if procsky and procsky.GetCloudLighting then
		local dir, light, amb = procsky.GetCloudLighting()
		local _, _, elev = procsky.GetLights()
		local overcast = shaderpack.Overcast()
		local gain = Lerp(math.Clamp(elev / NIGHT_ELEV, 0, 1), 1, NIGHT_GAIN) * Lerp(overcast, 1, OVERCAST_LIGHT) * EXPOSURE
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
	setConstant(LIGHT_MAT, "$c2", coverage())

	render.PushRenderTarget(lightMap)
	render.OverrideAlphaWriteEnable(true, true)
	render.SetMaterial(LIGHT_MAT)
	render.DrawScreenQuad()
	render.OverrideAlphaWriteEnable(false)
	render.PopRenderTarget()

	mapExtra:SetUnpacked(
		mapOrigin.x, mapOrigin.y, 1 / MAP_EXTENT, 1,
		0, 0, 0, 0,
		0, 0, 0, 0,
		0, 0, 0, 0
	)
	MAT:SetMatrix("$viewprojmat", mapExtra)
	mapReady = true
end

local function draw()
	if not MAT and not build() then return end

	local eye = EyePos()
	lastEye = eye
	local fwd = EyeAngles():Forward()
	local tonemap = render.GetToneMappingScaleLinear().x
	local sun, lightHue, lightScale, ambHue, ambScale, base, cov = vclouds.Layer(tonemap)
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
	hook.Remove("PreDrawTranslucentRenderables", "ms_vclouds")
	hook.Remove("RenderScreenspaceEffects", "ms_vclouds")
	hook.Remove("PreRender", "ms_vclouds")
	depthslices.RemoveEffect("ms_vclouds")
	active = false
end

local function start()
	stop()
	active = true
	mapReady = false
	hook.Add("PreRender", "ms_vclouds", bakeLight)
	depthslices.AddEffect("ms_vclouds", ORDER, draw, true, function() return active end)
end

shaderpack.Toggle("ms_vclouds", ENABLED, { PS, VS, LIGHT_PS, LIGHT_VS }, start, stop)()
