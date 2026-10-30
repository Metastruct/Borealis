local SHADERS = { "borealis_sunshafts_ps30", "borealis_passthrough_vs30" }

if SERVER then
	shaderpack.AddResources(SHADERS)

	return
end

local SHAFTS_ENABLED = CreateClientConVar("cl_draw_sunshafts", "1", true, false, "draw sun shafts")

local INTENSITY = 0.45
local RAY_LEN = 0.9
local DECAY = 0.95
local RADIUS = 0.25
local SCALE = 0.5
local FAR_FRAC = 0.98
local NEAR_DIST = 64
local CLAMP = 4 + 8

local W, H, maskRT, blurA, blurB, BLUR1, BLUR2, COMPOSITE

local function blurMaterial(name, src, falloff)
	local mat = CreateShaderMaterial(name .. "_" .. W .. "x" .. H, {
		["$pixshader"] = "borealis_sunshafts_ps30",
		["$vertexshader"] = "borealis_passthrough_vs30",
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$linearwrite"] = 0,
		["$linearread_basetexture"] = 0,
		["$c0_x"] = 0.5, ["$c0_y"] = 0.5, ["$c0_z"] = RAY_LEN, ["$c0_w"] = DECAY,
		["$c1_x"] = RADIUS, ["$c1_y"] = W / H, ["$c1_z"] = falloff, ["$c1_w"] = 1,
	})
	mat:SetTexture("$basetexture", src)

	return mat
end

local usableRT = shaderpack.UsableRT

local function build()
	local w, h = ScrW(), ScrH()
	local bw, bh = math.floor(w * SCALE), math.floor(h * SCALE)
	local mask = GetRenderTargetEx("borealis_sunshafts_mask_" .. bw .. "x" .. bh, bw, bh, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, CLAMP, 0, IMAGE_FORMAT_RGBA8888)
	local a = GetRenderTargetEx("borealis_sunshafts_a_" .. bw .. "x" .. bh, bw, bh, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, CLAMP, 0, IMAGE_FORMAT_RGBA8888)
	local b = GetRenderTargetEx("borealis_sunshafts_b_" .. bw .. "x" .. bh, bw, bh, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, CLAMP, 0, IMAGE_FORMAT_RGBA8888)
	if not (usableRT(mask, bw, bh) and usableRT(a, bw, bh) and usableRT(b, bw, bh)) then return false end

	W, H = w, h
	maskRT, blurA, blurB = mask, a, b
	BLUR1 = blurMaterial("borealis_sunshafts_blur1", maskRT, 1)
	BLUR2 = blurMaterial("borealis_sunshafts_blur2", blurA, 0)
	COMPOSITE = CreateMaterial("borealis_sunshafts_composite_" .. W .. "x" .. H, "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$additive"] = 1,
		["$vertexcolor"] = 1,
		["$vertexalpha"] = 1,
		["$ignorez"] = 1,
	})

	return true
end

local function viewFan()
	local ang = EyeAngles()
	local halfW, halfH = shaderpack.ViewTan()

	return ang:Forward(), ang:Right(), ang:Up(), halfW, halfH
end

local sunDir = Vector(0, 0, 1)
local sunUV = { 0.5, 0.5 }
local sunWeight = 0

local function updateSun()
	sunDir = shaderpack.SunDir()

	local fwd, right, up, halfW, halfH = viewFan()
	local f = sunDir:Dot(fwd)
	if f <= 0.05 then
		sunWeight = 0
		return
	end

	local x = sunDir:Dot(right) / f / halfW
	local y = sunDir:Dot(up) / f / halfH
	sunUV[1], sunUV[2] = x * 0.5 + 0.5, 0.5 - y * 0.5

	local off = math.max(math.abs(x), math.abs(y))
	local inView = 1 - math.Clamp((off - 1) / 0.6, 0, 1)
	local elevation = shaderpack.Elevation(sunDir)
	local risen = math.Clamp((elevation + 1) / 4, 0, 1)
	local low = 1 + 0.5 * (1 - math.Clamp(elevation / 40, 0, 1))
	sunWeight = inView * risen * low * (1 - shaderpack.Overcast())
end

local ALPHA0, ALPHA1 = Color(0, 0, 0, 0), Color(255, 255, 255, 255)
local maskValid = false

local function drawMask(bDepth, bSkybox, b3DSky)
	maskValid = false
	if bDepth or bSkybox or b3DSky or render.GetRenderTarget() then return end
	if (ScrW() ~= W or ScrH() ~= H) and not build() then return end

	updateSun()
	if sunWeight <= 0 then return end

	if bit.band(util.PointContents(EyePos()), CONTENTS_WATER) ~= 0 then return end

	local fwd, _, _, halfW, halfH = viewFan()
	local vs = render.GetViewSetup()
	local far = (vs.zfar or 30000) * FAR_FRAC
	local near = math.max(NEAR_DIST, vs.znear * 1.5)
	local eye = EyePos()

	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	render.SetColorMaterial()

	render.OverrideDepthEnable(true, false)
	cam.IgnoreZ(true)
	render.DrawQuadEasy(eye + fwd * near, -fwd, halfW * near * 4, halfH * near * 4, ALPHA0, 0)
	cam.IgnoreZ(false)
	render.OverrideDepthEnable(true, true)
	render.DrawQuadEasy(eye + fwd * far, -fwd, halfW * far * 4, halfH * far * 4, ALPHA1, 0)
	render.CopyRenderTargetToTexture(maskRT)

	render.OverrideDepthEnable(true, false)
	cam.IgnoreZ(true)
	render.DrawQuadEasy(eye + fwd * near, -fwd, halfW * near * 4, halfH * near * 4, ALPHA1, 0)
	cam.IgnoreZ(false)
	render.OverrideDepthEnable(false, false)

	render.OverrideBlend(false)
	render.OverrideAlphaWriteEnable(false, false)
	render.OverrideColorWriteEnable(false, false)
	maskValid = true
end

local function drawShafts()
	if not maskValid then return end
	maskValid = false

	BLUR1:SetTexture("$basetexture", maskRT)
	BLUR2:SetTexture("$basetexture", blurA)
	COMPOSITE:SetTexture("$basetexture", blurB)
	shaderpack.SetConstant(BLUR1, "$c0", sunUV[1], sunUV[2])
	shaderpack.SetConstant(BLUR2, "$c0", sunUV[1], sunUV[2])

	render.PushRenderTarget(blurA)
	render.SetMaterial(BLUR1)
	render.DrawScreenQuad(true)
	render.PopRenderTarget()

	render.PushRenderTarget(blurB)
	render.SetMaterial(BLUR2)
	render.DrawScreenQuad(true)
	render.PopRenderTarget()

	local elevation = shaderpack.Elevation(sunDir)
	local warm = 1 - math.Clamp(elevation / 30, 0, 1)
	local k = math.Clamp(INTENSITY * sunWeight, 0, 1) * 255
	surface.SetDrawColor(k, (0.92 - 0.35 * warm) * k, (0.8 - 0.6 * warm) * k, 255)
	surface.SetMaterial(COMPOSITE)
	surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
end

local function stop()
	hook.Remove("PostDrawTranslucentRenderables", "borealis_sunshafts")
	hook.Remove("RenderScreenspaceEffects", "borealis_sunshafts")
	maskValid = false
end

local function start()
	stop()
	W, H = nil, nil
	hook.Add("PostDrawTranslucentRenderables", "borealis_sunshafts", drawMask)
	hook.Add("RenderScreenspaceEffects", "borealis_sunshafts", drawShafts)
end

shaderpack.Toggle("borealis_sunshafts", SHAFTS_ENABLED, SHADERS, start, stop)()
