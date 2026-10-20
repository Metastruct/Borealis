local PS, BLEND_PS, VS, QUAD_VS = "ssao_ps30", "ssao_blend_ps30", "fog_vs30", "aurora_vs30"

if SERVER then
	shaderpack.AddResources({ PS, BLEND_PS, VS, QUAD_VS })

	return
end

local depthslices = shaderpack.depthslices
local ENABLED = CreateClientConVar("cl_draw_ssao", "1", true, false, "darken creases and contact points with screen-space ambient occlusion")
local RADIUS = CreateClientConVar("cl_ssao_radius", "24", true, false, "ambient occlusion radius in units", 4, 256)
local INTENSITY = CreateClientConVar("cl_ssao_intensity", "3", true, false, "ambient occlusion contrast", 0, 8)
local STRENGTH = CreateClientConVar("cl_ssao_strength", "1", true, false, "share of the ambient occlusion applied to the frame", 0, 1)
local AMBIENT = CreateClientConVar("cl_ssao_ambient", "0.25", true, false, "brightness up to which a pixel counts as ambient lit, brighter pixels lose at most this much", 0, 4)
local DEBUG = CreateClientConVar("cl_ssao_debug", "0", false, false, "show the ambient occlusion term alone")
local HALF_RES = CreateClientConVar("cl_ssao_halfres", "1", true, false, "compute the ambient occlusion at half resolution")

local ORDER = -1
local MAX_SCREEN = 0.12
local CLAMP = 4 + 8

local setConstant, usableRT = shaderpack.SetConstant, shaderpack.UsableRT

local AO_MAT, BLEND_MAT, AO_RT
local materialSerial = 0

local function build()
	materialSerial = materialSerial + 1
	local stamp = os.time() .. "_" .. materialSerial
	AO_MAT = CreateShaderMaterial("ms_ssao_" .. stamp, {
		["$pixshader"] = PS,
		["$vertexshader"] = QUAD_VS,
		["$linearread_basetexture"] = 1,
		["$alpha_blend"] = 0,
		["$additive"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
	})
	BLEND_MAT = CreateShaderMaterial("ms_ssao_blend_" .. stamp, {
		["$pixshader"] = BLEND_PS,
		["$vertexshader"] = VS,
		["$linearread_basetexture"] = 0,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$linearwrite"] = 0,
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
		["$ignorez"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
	})
end

local function target(w, h)
	if usableRT(AO_RT, w, h) then return AO_RT end

	local rt = GetRenderTargetEx("ms_ssao_" .. w .. "x" .. h, w, h, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, CLAMP, 0, IMAGE_FORMAT_RGBA16161616F)
	if not usableRT(rt, w, h) then return end
	AO_RT = rt

	return rt
end

local function draw()
	local depth = render.GetResolvedFullFrameDepth()
	if not usableRT(depth) then return end

	local w, h = ScrW(), ScrH()
	local half = HALF_RES:GetBool()
	local aw, ah = half and math.ceil(w / 2) or w, half and math.ceil(h / 2) or h
	local rt = target(aw, ah)
	if not rt then return end

	local halfW, halfH, vs = depthslices.ViewTan()
	AO_MAT:SetTexture("$basetexture", depth)
	setConstant(AO_MAT, "$c0", 1 / w, 1 / h, halfW, halfH)
	setConstant(AO_MAT, "$c1", RADIUS:GetFloat(), INTENSITY:GetFloat(), h, h * MAX_SCREEN)
	setConstant(AO_MAT, "$c2", aw, ah, half and 2 or 1)

	render.PushRenderTarget(rt)
	render.SetMaterial(AO_MAT)
	render.DrawScreenQuad()
	render.PopRenderTarget()

	BLEND_MAT:SetTexture("$texture2", rt)
	setConstant(BLEND_MAT, "$c0", 1 / aw, 1 / ah, STRENGTH:GetFloat(), DEBUG:GetBool() and 1 or 0)
	setConstant(BLEND_MAT, "$c1", vs.znear, vs.zfar, AMBIENT:GetFloat())

	return depthslices.Composite(BLEND_MAT, color_white)
end

local function stop()
	depthslices.RemoveEffect("ms_ssao")
end

local function start()
	stop()
	build()
	depthslices.AddEffect("ms_ssao", ORDER, draw, false, function() return true end)
end

shaderpack.Toggle("ms_ssao", ENABLED, { PS, BLEND_PS, VS, QUAD_VS }, start, stop)()

list.Set("PostProcess", "Ambient Occlusion", {
	icon = "gui/postprocess/base.png",
	convar = "cl_draw_ssao",
	category = "Borealis",
	cpanel = function(panel)
		panel:Help("Darkens creases and contact points that ambient light cannot reach.")
		panel:CheckBox("Enable", "cl_draw_ssao")
		panel:NumSlider("Intensity", "cl_ssao_intensity", 0, 8, 2)
		panel:NumSlider("Radius", "cl_ssao_radius", 4, 256, 0)
		panel:NumSlider("Ambient level", "cl_ssao_ambient", 0, 4, 2)
		panel:NumSlider("Strength", "cl_ssao_strength", 0, 1, 2)
		panel:CheckBox("Half resolution", "cl_ssao_halfres")
		panel:CheckBox("Show occlusion only", "cl_ssao_debug")
	end,
})
