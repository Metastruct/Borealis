local PS, VS = "vcloud_shadows_ps30", "fog_vs30"

if SERVER then
	shaderpack.AddResources({ VS, PS }, { "materials/shaderpack/procsky/cloudshape.vtf", "materials/shaderpack/procsky/clouddetail.vtf" })

	return
end

local procsky, vclouds, depthslices = shaderpack.procsky, shaderpack.vclouds, shaderpack.depthslices

local STRENGTH = 2.0

local MIN_ELEV, FADE_ELEV = 2, 10
local ORDER = 5
local TIME_WRAP = 3600

local MAT
local materialSerial = 0

local function build()
	materialSerial = materialSerial + 1
	MAT = CreateShaderMaterial("ms_vcloud_shadows_" .. os.time() .. "_" .. materialSerial, {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$texture2"] = "shaderpack/procsky/cloudshape",
		["$texture3"] = "shaderpack/procsky/clouddetail",
		["$linearread_basetexture"] = 0,
		["$linearread_texture1"] = 1,
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

	local z, cover = vclouds.GetLayer()
	if not z then
		active = false

		return
	end

	local sun, elev = sunInfo()
	local overcast = shaderpack.Overcast()
	local g = STRENGTH * math.Clamp((elev - MIN_ELEV) / FADE_ELEV, 0, 1) * (1 - overcast)
	if g <= 0.001 then
		active = false

		return
	end

	layerZ, coverage, gain, sunDir = z, cover, g, sun
	active = true
end

local quadColor = Color(255, 255, 0, 255)

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

local function stop()
	hook.Remove("Think", "ms_vcloud_shadows")
	depthslices.RemoveEffect("ms_vcloud_shadows")
	active = false
end

local function start()
	stop()
	MAT = nil
	hook.Add("Think", "ms_vcloud_shadows", update)
	depthslices.AddEffect("ms_vcloud_shadows", ORDER, draw, false, function() return active end)
end

shaderpack.Toggle("ms_vcloud_shadows", nil, { PS, VS }, start, stop)()
