local PS, VS = "borealis_grade_ps30", "borealis_passthrough_vs30"

if SERVER then
	shaderpack.AddResources({ PS, VS })

	return
end

local grade = shaderpack.grade or {}
shaderpack.grade = grade

local ENABLED = CreateClientConVar("cl_draw_grade", "1", true, false, "colour grade the frame from the time of day")
local SHARPEN_ENABLED = CreateClientConVar("cl_draw_sharpen", "1", true, false, "sharpen the frame with contrast adaptive sharpening")
local SHARPEN = CreateClientConVar("cl_sharpen", "0.4", true, false, "contrast adaptive sharpening strength, 0 turns it off", 0, 1)

local NEUTRAL = Vector(1, 1, 1)
local EPSILON = 1e-3

local setConstant = shaderpack.SetConstant

local MAT
local materialSerial = 0

local function build()
	materialSerial = materialSerial + 1
	MAT = CreateShaderMaterial("borealis_grade_" .. os.time() .. "_" .. materialSerial, {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$linearread_basetexture"] = 0,
		["$linearwrite"] = 0,
		["$alpha_blend"] = 0,
		["$additive"] = 0,
		["$ignorez"] = 1,
		["$c0_x"] = 1, ["$c0_y"] = 1, ["$c0_z"] = 1, ["$c0_w"] = 1,
		["$c1_x"] = 1, ["$c1_y"] = 1, ["$c1_z"] = 1, ["$c1_w"] = 1,
		["$c2_x"] = 1, ["$c2_y"] = 1, ["$c2_z"] = 1, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})
end

local function balanced(v, gain)
	v = isvector(v) and v or NEUTRAL
	local luma = math.max(v.x * 0.2126 + v.y * 0.7152 + v.z * 0.0722, EPSILON)
	gain = (gain or 1) / luma

	return v.x * gain, v.y * gain, v.z * gain
end

local function neutral(v)
	return not isvector(v) or (math.abs(v.x - v.y) < EPSILON and math.abs(v.y - v.z) < EPSILON)
end

local graded = false

local function draw()
	if render.GetRenderTarget() then return end
	graded = true

	local C = ENABLED:GetBool() and tod and tod.CurrentParams or {}
	local exposure = C.grade_exposure or 0
	local contrast = C.grade_contrast or 1
	local saturation = C.grade_saturation or 1
	local active = not (math.abs(exposure) < EPSILON and math.abs(contrast - 1) < EPSILON and math.abs(saturation - 1) < EPSILON
		and neutral(C.grade_white) and neutral(C.grade_shadows) and neutral(C.grade_highlights))
	local sharpness = SHARPEN_ENABLED:GetBool() and SHARPEN:GetFloat() or 0
	if not active and sharpness <= 0 then return end

	local wr, wg, wb = balanced(C.grade_white, 2 ^ exposure)
	local sr, sg, sb = balanced(C.grade_shadows)
	local hr, hg, hb = balanced(C.grade_highlights)
	setConstant(MAT, "$c0", wr, wg, wb, contrast)
	setConstant(MAT, "$c1", sr, sg, sb, saturation)
	setConstant(MAT, "$c2", hr, hg, hb)
	setConstant(MAT, "$c3", 1 / ScrW(), 1 / ScrH(), sharpness > 0 and -1 / Lerp(sharpness, 8, 5) or 0)

	render.UpdateScreenEffectTexture()
	MAT:SetTexture("$basetexture", render.GetScreenEffectTexture())
	render.SetMaterial(MAT)
	render.DrawScreenQuad()
end

local running = false

local function wrapper(gm, ...)
	if grade.original then grade.original(gm, ...) end
	if running then draw() end
end

local function wrap()
	local gm = GAMEMODE
	if not gm or grade.gm == gm then return end
	grade.gm, grade.original, grade.wrapper = gm, gm.RenderScreenspaceEffects, wrapper
	gm.RenderScreenspaceEffects = wrapper
end

local function fallback()
	wrap()
	if not graded then draw() end
	graded = false
end

local function stop()
	running = false
	hook.Remove("PostDrawEffects", "borealis_grade")
	local gm = grade.gm
	if gm and gm.RenderScreenspaceEffects == grade.wrapper then
		gm.RenderScreenspaceEffects = grade.original
		grade.gm, grade.original, grade.wrapper = nil, nil, nil
	end
end

local function start()
	stop()
	build()
	running = true
	wrap()
	hook.Add("PostDrawEffects", "borealis_grade", fallback)
end

shaderpack.Toggle("borealis_grade", nil, { PS, VS }, start, stop)()

shaderpack.PostProcess("Colour Grading", {
	icon = "gui/postprocess/base.png",
	convar = "cl_draw_grade",
	category = "Borealis",
	cpanel = function(panel)
		panel:Help("Grades the frame's contrast, saturation and tint from the time of day.")
		panel:CheckBox("Enable", "cl_draw_grade")
	end,
})

shaderpack.PostProcess("Sharpening", {
	icon = "gui/postprocess/base.png",
	convar = "cl_draw_sharpen",
	category = "Borealis",
	cpanel = function(panel)
		panel:Help("Contrast adaptive sharpening. Sharpens soft detail and leaves strong edges alone.")
		panel:CheckBox("Enable", "cl_draw_sharpen")
		panel:NumSlider("Strength", "cl_sharpen", 0, 1, 2)
	end,
})
