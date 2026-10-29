local PS, VS = "borealis_vcloud_shadows_ps30", "borealis_fog_vs30"
local MAP_PS, MAP_VS = "borealis_vcloudshadowmap_ps30", "borealis_passthrough_vs30"
local SHAPE, DETAIL = "shaderpack/procsky/cloudshape", "shaderpack/procsky/clouddetail"

if SERVER then
	shaderpack.AddResources({ VS, PS, MAP_PS, MAP_VS }, { SHAPE, DETAIL })

	return
end

local procsky, vclouds, cover, depthslices = shaderpack.procsky, shaderpack.vclouds, shaderpack.cover, shaderpack.depthslices

local MIN_ELEV, FADE_ELEV = 2, 10
local MIN_SUN_Z = 0.03
local ORDER = 5
local TIME_WRAP = 3600

local MAP_SIZE = 512
local MAP_EXTENT = 48000
local MAP_BAKE_EVERY = 4
local MAP_BAKE_PHASE = 2

local MAT, MAP_MAT, shadowMap
local materialSerial = 0
local mapExtra = Matrix()
local mapX, mapY = 0, 0
local mapReady = false

local function build()
	materialSerial = materialSerial + 1
	local suffix = os.time() .. "_" .. materialSerial

	shadowMap = GetRenderTargetEx("borealis_vcloudshadow_" .. MAP_SIZE, MAP_SIZE, MAP_SIZE, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 12, 0, IMAGE_FORMAT_RGBA16161616F)
	if not shaderpack.UsableRT(shadowMap, MAP_SIZE, MAP_SIZE) then
		shadowMap = nil

		return false
	end

	MAT = CreateShaderMaterial("borealis_vcloud_shadows_" .. suffix, {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
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
	}, "screenspace_general_8tex")
	MAT:SetTexture("$texture2", shadowMap)

	MAP_MAT = CreateShaderMaterial("borealis_vcloudshadowmap_" .. suffix, {
		["$pixshader"] = MAP_PS,
		["$vertexshader"] = MAP_VS,
		["$texture2"] = SHAPE,
		["$texture3"] = DETAIL,
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
		["$alpha_blend"] = 0,
		["$additive"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = MAP_EXTENT, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 1, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = MAP_SIZE, ["$c2_z"] = 0, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})
	mapReady = false

	return true
end

local active = false
local layerZ, coverage, gain = 0, 0, 0
local sunDir = Vector(0, 0, 1)

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

	local z, cov = vclouds.GetLayer()
	if not z then
		active = false

		return
	end

	local sun, elev = sunInfo()
	local g = math.Clamp((elev - MIN_ELEV) / FADE_ELEV, 0, 1) * (1 - shaderpack.Overcast())
	if g <= 0.001 then
		active = false

		return
	end

	layerZ, coverage, gain, sunDir = z, cov, g, sun
	active = true
end

local setConstant = shaderpack.SetConstant
local lastEye

local function bakeMap()
	if not active then return end
	if not MAT and not build() then return end

	local eye = lastEye or EyePos()
	cover.UpdateExposure(eye)
	if mapReady and FrameNumber() % MAP_BAKE_EVERY ~= MAP_BAKE_PHASE then return end

	local texel = MAP_EXTENT / MAP_SIZE
	local lift = math.max(layerZ - eye.z, 0) / math.max(sunDir.z, MIN_SUN_Z)
	mapX = math.Round((eye.x + sunDir.x * lift) / texel) * texel
	mapY = math.Round((eye.y + sunDir.y * lift) / texel) * texel

	setConstant(MAP_MAT, "$c0", mapX, mapY, nil, CurTime() % TIME_WRAP)
	setConstant(MAP_MAT, "$c1", sunDir.x, sunDir.y, sunDir.z, layerZ)
	setConstant(MAP_MAT, "$c2", coverage)
	setConstant(MAP_MAT, "$c3", eye.x, eye.y, eye.z)

	render.PushRenderTarget(shadowMap)
	render.OverrideAlphaWriteEnable(true, true)
	render.SetMaterial(MAP_MAT)
	render.DrawScreenQuad()
	render.OverrideAlphaWriteEnable(false)
	render.PopRenderTarget()
	mapReady = true
end

local quadColor = Color(255, 255, 0, 255)

local function draw()
	if not active or not mapReady then return end

	local eye = EyePos()
	lastEye = eye
	local fwd = EyeAngles():Forward()
	local spans = cover and cover.Spans()
	setConstant(MAT, "$c0", eye.x, eye.y, eye.z, gain)
	setConstant(MAT, "$c1", fwd.x, fwd.y, fwd.z, layerZ)
	setConstant(MAT, "$c2", sunDir.x, sunDir.y, sunDir.z)
	MAT:SetTexture("$texture3", spans or shadowMap)
	local exposure, ex, ey, einv, ez = cover.Exposure()
	MAT:SetTexture("$texture4", exposure or shadowMap)
	mapExtra:SetUnpacked(
		mapX, mapY, 1 / MAP_EXTENT, spans and 1 or 0,
		ex or 0, ey or 0, einv or 0, ez or 0,
		0, 0, 0, 0,
		0, 0, 0, 0
	)
	MAT:SetMatrix("$viewprojmat", mapExtra)
	quadColor.b = depthslices.Samples()
	depthslices.Composite(MAT, quadColor)
end

local function stop()
	hook.Remove("Think", "borealis_vcloud_shadows")
	hook.Remove("PreRender", "borealis_vcloud_shadows")
	depthslices.RemoveEffect("borealis_vcloud_shadows")
	active = false
end

local function start()
	stop()
	MAT = nil
	hook.Add("Think", "borealis_vcloud_shadows", update)
	hook.Add("PreRender", "borealis_vcloud_shadows", bakeMap)
	depthslices.AddEffect("borealis_vcloud_shadows", ORDER, draw, false, function() return active end)
end

shaderpack.Toggle("borealis_vcloud_shadows", nil, { PS, VS, MAP_PS, MAP_VS, unpack(cover.EXPOSURE_SHADERS) }, start, stop, { SHAPE, DETAIL })()
