local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

if SERVER then
	if not resource.AddShader then return end

	resource.AddShader("aurora_vs30")
	resource.AddShader("sunshafts_ps30")

	return
end

-- Screen-space sun shafts.  A sky mask is written into the frame's alpha
-- channel after the translucent pass: a near quad sets alpha 0 everywhere,
-- then a quad at the far plane, depth-tested against the world already in the
-- buffer, sets alpha 1 where nothing was drawn.  The frame is copied to a
-- half-res target and blurred twice toward the sun's screen position by
-- sunshafts_ps30, then composited additively in the sun's colour.
--
-- The mask relies on the frame having an alpha channel (HDR float mode).

local SHAFTS_ENABLED = CreateClientConVar("cl_draw_sunshafts", "1", true, false, "draw sun shafts")

local INTENSITY = 0.45
local RAY_LEN = 0.9 -- fraction of the way to the sun covered by one blur pass
local DECAY = 0.95 -- tap weight decay
local RADIUS = 0.25 -- source falloff around the sun, in screen heights
local SCALE = 0.5 -- blur resolution relative to the screen
local FAR_FRAC = 0.98 -- the mask quad sits at this fraction of zfar
local NEAR_DIST = 64 -- the alpha clearing quad sits here
local CLAMP = 4 + 8 -- TEXTUREFLAGS_CLAMPS + TEXTUREFLAGS_CLAMPT, not defined as globals on the client

--------------------------------------------------------------------------
-- render targets and materials, rebuilt when the resolution changes
--------------------------------------------------------------------------
local W, H, maskRT, blurA, blurB, BLUR1, BLUR2, COMPOSITE

local function blurMaterial(name, src, falloff)
	local mat = CreateMaterial(name .. "_" .. W .. "x" .. H, "screenspace_general", {
		["$pixshader"] = "sunshafts_ps30",
		["$vertexshader"] = "aurora_vs30",
		["$basetexture"] = "",
		["$ignorez"] = 1,
		["$vertexcolor"] = 1,
		["$vertextransform"] = 1,
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$linearwrite"] = 0,
		["$linearread_basetexture"] = 0,
		["<dx90"] = { ["$no_draw"] = 1 },
		["$c0_x"] = 0.5, ["$c0_y"] = 0.5, ["$c0_z"] = RAY_LEN, ["$c0_w"] = DECAY,
		["$c1_x"] = RADIUS, ["$c1_y"] = W / H, ["$c1_z"] = falloff, ["$c1_w"] = 1,
	})
	mat:SetTexture("$basetexture", src)

	return mat
end

local function build()
	W, H = ScrW(), ScrH()
	local bw, bh = math.floor(W * SCALE), math.floor(H * SCALE)
	maskRT = GetRenderTargetEx("ms_sunshafts_mask_" .. bw .. "x" .. bh, bw, bh, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, CLAMP, 0, IMAGE_FORMAT_RGBA8888)
	blurA = GetRenderTargetEx("ms_sunshafts_a_" .. bw .. "x" .. bh, bw, bh, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, CLAMP, 0, IMAGE_FORMAT_RGBA8888)
	blurB = GetRenderTargetEx("ms_sunshafts_b_" .. bw .. "x" .. bh, bw, bh, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, CLAMP, 0, IMAGE_FORMAT_RGBA8888)
	BLUR1 = blurMaterial("ms_sunshafts_blur1", maskRT, 1)
	BLUR2 = blurMaterial("ms_sunshafts_blur2", blurA, 0)
	COMPOSITE = CreateMaterial("ms_sunshafts_composite_" .. W .. "x" .. H, "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$additive"] = 1,
		["$vertexcolor"] = 1,
		["$vertexalpha"] = 1,
		["$ignorez"] = 1,
	})
	COMPOSITE:SetTexture("$basetexture", blurB)
end

--------------------------------------------------------------------------
-- sun
--------------------------------------------------------------------------
-- basis from EyeAngles (right inside a RenderView too), fan from the view setup
local function viewFan()
	local ang = EyeAngles()
	local vs = render.GetViewSetup()
	local halfW = math.tan(math.rad(vs.fov) * 0.5)

	return ang:Forward(), ang:Right(), ang:Up(), halfW, halfW / vs.aspect
end

local sunDir = Vector(0, 0, 1)
local sunUV = { 0.5, 0.5 }
local sunWeight = 0

-- screen position of the sun and a weight fading it out of view and below the horizon
local function updateSun()
	if procsky and procsky.GetLights then
		sunDir = procsky.GetLights()
	elseif tod and tod.CurrentParams and isangle(tod.CurrentParams.sun_angles) then
		sunDir = -tod.CurrentParams.sun_angles:Forward()
	end

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
	local elev = math.deg(math.asin(math.Clamp(sunDir.z, -1, 1)))
	local risen = math.Clamp((elev + 1) / 4, 0, 1)
	local low = 1 + 0.5 * (1 - math.Clamp(elev / 40, 0, 1)) -- stronger near the horizon
	sunWeight = inView * risen * low
end

--------------------------------------------------------------------------
-- mask
--------------------------------------------------------------------------
local ALPHA0, ALPHA1 = Color(0, 0, 0, 0), Color(255, 255, 255, 255)
local maskValid = false

local function drawMask(bDepth, bSkybox, b3DSky)
	maskValid = false
	if bDepth or bSkybox or b3DSky or render.GetRenderTarget() then return end
	if ScrW() ~= W or ScrH() ~= H then build() end

	updateSun()
	if sunWeight <= 0 then return end

	local fwd, right, up, halfW, halfH = viewFan()
	local far = (render.GetViewSetup().zfar or 30000) * FAR_FRAC
	local eye = EyePos()

	-- alpha writes only, blending forced to replace so alpha 0 lands.  The
	-- surface library ignores the override, so both steps are 3D quads, sized
	-- well past the screen (they sit on a plane at their distance either way)
	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	render.SetColorMaterial()

	-- OverrideDepthEnable(true, false) turns the depth test off entirely
	render.OverrideDepthEnable(true, false)
	render.DrawQuadEasy(eye + fwd * NEAR_DIST, -fwd, halfW * NEAR_DIST * 4, halfH * NEAR_DIST * 4, ALPHA0, 0)
	render.OverrideDepthEnable(true, true)
	render.DrawQuadEasy(eye + fwd * far, -fwd, halfW * far * 4, halfH * far * 4, ALPHA1, 0)
	render.OverrideDepthEnable(false, false)

	render.OverrideBlend(false)
	render.OverrideAlphaWriteEnable(false, false)
	render.OverrideColorWriteEnable(false, false)

	render.CopyRenderTargetToTexture(maskRT)
	maskValid = true
end

--------------------------------------------------------------------------
-- blur and composite
--------------------------------------------------------------------------
local function drawShafts()
	if not maskValid then return end
	maskValid = false

	BLUR1:SetFloat("$c0_x", sunUV[1])
	BLUR1:SetFloat("$c0_y", sunUV[2])
	BLUR2:SetFloat("$c0_x", sunUV[1])
	BLUR2:SetFloat("$c0_y", sunUV[2])

	render.PushRenderTarget(blurA)
	render.SetMaterial(BLUR1)
	render.DrawScreenQuad(true)
	render.PopRenderTarget()

	render.PushRenderTarget(blurB)
	render.SetMaterial(BLUR2)
	render.DrawScreenQuad(true)
	render.PopRenderTarget()

	-- sun colour through the atmosphere: warm at low sun
	local elev = math.deg(math.asin(math.Clamp(sunDir.z, -1, 1)))
	local warm = 1 - math.Clamp(elev / 30, 0, 1)
	local k = math.Clamp(INTENSITY * sunWeight, 0, 1) * 255
	surface.SetDrawColor(k, (0.92 - 0.35 * warm) * k, (0.8 - 0.6 * warm) * k, 255)
	surface.SetMaterial(COMPOSITE)
	surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
end

--------------------------------------------------------------------------
-- lifecycle
--------------------------------------------------------------------------
local function stop()
	hook.Remove("PostDrawTranslucentRenderables", "ms_sunshafts")
	hook.Remove("RenderScreenspaceEffects", "ms_sunshafts")
	maskValid = false
end

local function start()
	stop()
	build()
	hook.Add("PostDrawTranslucentRenderables", "ms_sunshafts", drawMask)
	hook.Add("RenderScreenspaceEffects", "ms_sunshafts", drawShafts)
end

local function shadersAvailable()
	return file.Exists("shaders/fxc/sunshafts_ps30.vcs", "GAME") and file.Exists("shaders/fxc/aurora_vs30.vcs", "GAME")
end

local function apply()
	if not SHAFTS_ENABLED:GetBool() then
		stop()
		return
	end

	if shadersAvailable() then
		start()
	elseif HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
		hook.Add("ShaderMounted", "ms_sunshafts", function()
			hook.Remove("ShaderMounted", "ms_sunshafts")
			if SHAFTS_ENABLED:GetBool() and shadersAvailable() then
				start()
			end
		end)
	end
end

cvars.RemoveChangeCallback("cl_draw_sunshafts", "ms_sunshafts")
cvars.AddChangeCallback("cl_draw_sunshafts", apply, "ms_sunshafts")
hook.Remove("ShaderMounted", "ms_sunshafts")
apply()
