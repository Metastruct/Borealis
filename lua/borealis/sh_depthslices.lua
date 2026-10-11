local MARK_PS, MARK_VS = "depthmark_ps30", "fog_vs30"

if SERVER then
	shaderpack.AddResources({ MARK_VS, MARK_PS })

	return
end

local depthslices = shaderpack.depthslices or {}
shaderpack.depthslices = depthslices

local SLICES = 32 -- both ends and the ratio are baked into fog_ps30 and vclouds_ps30
local NEAR = 16
local FAR = 8000
local QUAD_NEAR = 12 -- the clearing quad sits this far in front of the eye
local OVERSIZE = 6 -- quads are sized past the frustum
local MARK_BIAS = 0.002
local CLAMP = 4 + 8

depthslices.SLICES, depthslices.NEAR, depthslices.FAR = SLICES, NEAR, FAR
-- on the module, so reloading this file does not drop what is registered
depthslices.effects = depthslices.effects or {}

local dist = {}
do
	local ratio = (FAR / NEAR) ^ (1 / (SLICES - 1))
	depthslices.RATIO = ratio
	for k = 0, SLICES - 1 do
		dist[k] = NEAR * ratio ^ k
	end
end

local AA = GetConVar("mat_antialias")

function depthslices.Samples()
	return math.Clamp(AA and AA:GetInt() or 1, 1, 16)
end

local ALPHA1 = Color(0, 0, 0, 255)
local sliceColor = Color(0, 0, 0, 0)
local capturedFrame = -1
local dirtyFrame = -1
local refogFrame = -1
local MARK, CODES
local markRetry = 0

local function quad(eye, fwd, halfW, halfH, t, col)
	render.DrawQuadEasy(eye + fwd * t, -fwd, halfW * t * OVERSIZE, halfH * t * OVERSIZE, col, 0)
end

local function quadNear(vs)
	return math.max(QUAD_NEAR, vs.znear * 1.5)
end

local function viewFan()
	local halfW, halfH, vs = shaderpack.ViewTan()

	return EyePos(), EyeAngles():Forward(), halfW, halfH, vs
end

local function fillAlpha(col)
	local eye, fwd, halfW, halfH, vs = viewFan()

	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	render.SetColorMaterial()
	render.OverrideDepthEnable(true, false)
	quad(eye, fwd, halfW, halfH, quadNear(vs), col)
	render.OverrideDepthEnable(false, false)
	render.OverrideBlend(false)
	render.OverrideAlphaWriteEnable(false, false)
	render.OverrideColorWriteEnable(false, false)
end

-- Safe to call from several effects in one frame: only the first does the work.
function depthslices.Capture()
	if capturedFrame == FrameNumber() then return end
	capturedFrame = FrameNumber()
	dirtyFrame = capturedFrame

	local eye, fwd, halfW, halfH, vs = viewFan()
	local first = 0
	while first < SLICES and dist[first] <= vs.znear do
		first = first + 1
	end

	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	render.SetColorMaterial()
	render.OverrideDepthEnable(true, false)
	sliceColor.a = first
	quad(eye, fwd, halfW, halfH, quadNear(vs), sliceColor)
	render.OverrideDepthEnable(false, false)
	for k = first, SLICES - 1 do
		sliceColor.a = k + 1
		quad(eye, fwd, halfW, halfH, dist[k], sliceColor)
	end
	render.OverrideBlend(false)
	render.OverrideAlphaWriteEnable(false, false)
	render.OverrideColorWriteEnable(false, false)
end

function depthslices.Invalidate()
	capturedFrame = -1
end

function depthslices.SkipRefog()
	refogFrame = -1
end

local depthFrame, depthFresh = -1, false

function depthslices.BeginDepthWrite()
	if depthFrame ~= FrameNumber() then
		depthFrame = FrameNumber()
		depthFresh = hook.Run("NeedsDepthPass") == true
	end
	if not depthFresh then return false end

	render.PushRenderTarget(render.GetResolvedFullFrameDepth())
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MIN, BLEND_ONE, BLEND_ONE, BLENDFUNC_MIN)

	return true
end

function depthslices.EndDepthWrite()
	render.OverrideBlend(false)
	render.PopRenderTarget()
end

-- an effect's own quad must not touch alpha, or the next effect reads its
-- output instead of the slice indices
function depthslices.KeepAlpha(draw)
	render.OverrideAlphaWriteEnable(true, false)
	draw()
	render.OverrideAlphaWriteEnable(false, false)
end

-- The render targets do not exist yet while the map loads, and asking for one
-- then hands back a 32 x 32 error texture that answers IsError with false.
-- Bound as the depth, it reads as garbage.  They are rebound every frame: the
-- targets are recreated across a map change and a material built before they
-- existed holds the error texture forever.
function depthslices.Composite(mat, color)
	local depth, fb = render.GetResolvedFullFrameDepth(), render.GetScreenEffectTexture()
	if not shaderpack.UsableRT(depth) or not shaderpack.UsableRT(fb) then return false end

	depthslices.Capture()
	render.UpdateScreenEffectTexture()
	mat:SetTexture("$texture1", depth)
	mat:SetTexture("$basetexture", fb)

	local eye, fwd, halfW, halfH, vs = viewFan()
	depthslices.KeepAlpha(function()
		render.OverrideDepthEnable(true, false)
		render.SetMaterial(mat)
		quad(eye, fwd, halfW, halfH, quadNear(vs), color)
		render.OverrideDepthEnable(false, false)
	end)

	return true
end

--------------------------------------------------------------------------
-- the ordered composite pass
--------------------------------------------------------------------------
local function byOrder(a, b)
	return a.order < b.order
end

-- order is a distance: the farther volume takes the lower number
function depthslices.AddEffect(name, order, draw, refog, needsDepth)
	depthslices.RemoveEffect(name)
	local t = depthslices.effects
	t[#t + 1] = { name = name, order = order, draw = draw, refog = refog, needsDepth = needsDepth }
	table.sort(t, byOrder)
end

function depthslices.RemoveEffect(name)
	local t = depthslices.effects
	for i = #t, 1, -1 do
		if t[i].name == name then
			table.remove(t, i)
		end
	end
end

local usableRT = shaderpack.UsableRT

local function markReady()
	local w, h = ScrW(), ScrH()
	if MARK and usableRT(CODES, w, h) then return true end
	if RealTime() < markRetry then return false end
	markRetry = RealTime() + 5

	if not shaderpack.Available({ MARK_PS, MARK_VS }) then return false end

	local codes = GetRenderTargetEx("ms_depthslices_codes_" .. w .. "x" .. h, w, h, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, CLAMP, 0, IMAGE_FORMAT_RGBA8888)
	if not usableRT(codes, w, h) then return false end

	CODES = codes
	MARK = CreateShaderMaterial("ms_depthslices_mark_" .. w .. "x" .. h .. "_" .. os.time(), {
		["$pixshader"] = MARK_PS,
		["$vertexshader"] = MARK_VS,
		["$basetexture"] = codes:GetName(),
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$linearwrite"] = 0,
		["$ignorez"] = 0,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
		["$c0_x"] = 3, ["$c0_y"] = 30000, ["$c0_z"] = MARK_BIAS, ["$c0_w"] = 0,
	})

	return true
end

local function refog()
	local eye, fwd, halfW, halfH, vs = viewFan()
	render.UpdateScreenEffectTexture()
	MARK:SetTexture("$texture2", render.GetScreenEffectTexture())
	MARK:SetTexture("$basetexture", CODES)
	MARK:SetTexture("$texture1", render.GetResolvedFullFrameDepth())
	shaderpack.SetConstant(MARK, "$c0", vs.znear, vs.zfar, nil, depthslices.Samples())

	capturedFrame = -1
	depthslices.Capture()

	render.SetStencilWriteMask(255)
	render.SetStencilTestMask(255)
	render.SetStencilReferenceValue(1)
	render.ClearStencil()
	render.SetStencilEnable(true)
	render.SetStencilCompareFunction(STENCIL_ALWAYS)
	render.SetStencilPassOperation(STENCIL_KEEP)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_REPLACE)

	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, false)
	render.SetMaterial(MARK)
	render.OverrideDepthEnable(true, true)
	quad(eye, fwd, halfW, halfH, quadNear(vs), color_white)
	render.OverrideDepthEnable(false, false)
	render.OverrideAlphaWriteEnable(false, false)
	render.OverrideColorWriteEnable(false, false)

	render.SetStencilZFailOperation(STENCIL_KEEP)
	render.SetStencilCompareFunction(STENCIL_NOTEQUAL)
	fillAlpha(ALPHA1)

	render.SetStencilCompareFunction(STENCIL_EQUAL)
	local t = depthslices.effects
	for i = 1, #t do
		if t[i].refog then
			t[i].draw()
		end
	end
	fillAlpha(ALPHA1)
	render.SetStencilEnable(false)
end

-- NeedsDepthPass takes the FIRST non-nil return of all its hooks, so
-- returning false here would cancel another consumer's true and leave the
-- depth buffer stale.  Ask when it is needed, stay silent otherwise.
hook.Add("NeedsDepthPass", "ms_depthslices", function()
	local t = depthslices.effects
	for i = 1, #t do
		local needsDepth = t[i].needsDepth
		if needsDepth and needsDepth() then return true end
	end
end)

hook.Add("PreDrawTranslucentRenderables", "ms_depthslices_effects", function(bDepth, bSkybox, b3DSky)
	if bDepth or bSkybox or b3DSky or render.GetRenderTarget() then return end
	local t = depthslices.effects
	local wantsRefog = false
	for i = 1, #t do
		if t[i].draw() and t[i].refog then
			wantsRefog = true
		end
	end

	if wantsRefog and markReady() then
		refogFrame = FrameNumber()
		render.CopyRenderTargetToTexture(CODES)
	end
end)

hook.Add("PostDrawTranslucentRenderables", "ms_depthslices_restore", function(bDepth, bSkybox, b3DSky)
	if bDepth or bSkybox or b3DSky then return end
	if dirtyFrame ~= FrameNumber() then return end

	fillAlpha(ALPHA1)
end)

hook.Add("PreDrawViewModels", "ms_depthslices_refog", function()
	if refogFrame ~= FrameNumber() or render.GetRenderTarget() then return end
	refogFrame = -1
	refog()
end)
