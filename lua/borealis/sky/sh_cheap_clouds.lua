local SHAPE, DETAIL = "shaderpack/procsky/cloudshape", "shaderpack/procsky/clouddetail"

if SERVER then
	shaderpack.AddResources({ "cloudbake_ps30", "cloudlut_ps30" }, { SHAPE, DETAIL })

	return
end

require("skyboxer")

local procsky, cover, vclouds = shaderpack.procsky, shaderpack.cover, shaderpack.vclouds
local Tag = "ms_cheap_clouds"
local ENABLED = CreateClientConVar("cl_draw_clouds", "1", true, false, "Draw cheap clouds in the skybox", 0, 1)

local function level()
	if procsky and procsky.theme and procsky.theme.clouds == false then return end
	if not ENABLED:GetBool() then return end

	return cover and cover.SkyLevel()
end

local function wanted()
	return level() or shaderpack.Overcast() >= 0.01
end

local LUT_W, LUT_H = 1024, 512
local BANDS = 16
local BAKE_EVERY = 4
local CLOUD_SCALE = 3
local SLAB_MID = 3000 * CLOUD_SCALE
local HISTORY = 0.7
local CLEAR_COVERAGE = 0.6
local DECK_CLEAR = 4800
local SKY_DECK_Z = 14000

local function deckHeight(lvl, overcast)
	if not lvl then return SKY_DECK_Z end
	local z = math.max(lvl.ceiling, lvl.floor + DECK_CLEAR)

	return Lerp(overcast, z, math.max(z, SKY_DECK_Z))
end

local setConstant = shaderpack.SetConstant

local function startShader()
	local luts

	local function allocLuts()
		local list = {}
		for i, name in ipairs({ "a", "b", "c" }) do
			local rt = GetRenderTargetEx("ms_cloudlut_" .. name .. "_" .. LUT_W .. "x" .. LUT_H, LUT_W, LUT_H, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 8, 0, IMAGE_FORMAT_RGBA16161616F)
			if not rt or rt:IsError() or rt:Width() ~= LUT_W then return false end
			render.PushRenderTarget(rt)
			render.Clear(0, 0, 0, 0)
			render.PopRenderTarget()
			list[i] = { rt = rt, origin = Vector(), mid = 0, side = 1 }
		end

		luts = list
		return true
	end

	local BAKE = CreateShaderMaterial("ms_cloudbake_" .. os.time(), {
		["$pixshader"] = "cloudbake_ps30",
		["$vertexshader"] = "aurora_vs30",
		["$texture2"] = SHAPE,
		["$texture3"] = DETAIL,
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
		["$alpha_blend"] = 0,
		["$additive"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = LUT_W, ["$c1_y"] = LUT_H, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 1, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})

	local READ = CreateShaderMaterial("ms_cloudlut_" .. os.time(), {
		["$pixshader"] = "cloudlut_ps30",
		["$vertexshader"] = "aurora_vs30",
		["$linearread_texture1"] = 1,
		["$linearwrite"] = 0,
		["$additive"] = 0,
		["$c0_x"] = 1, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 1, ["$c1_z"] = 0, ["$c1_w"] = 1,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 1,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 1,
	})

	local bakeExtra = Matrix()
	local prev, cur, back = 1, 1, 2
	local ready, band, cycle = false, 0, 0
	local rows = LUT_H / BANDS
	local fogHue, fogPacked, fogScale = 0, 0, 0
	local eye, eyeFrame = Vector(), -1
	local anchor, anchorLevel = Vector(), nil

	local function cacheFog(depth, skybox)
		if depth or skybox then return end
		fogHue, fogPacked, fogScale = vclouds.Fog(render.GetToneMappingScaleLinear().x)
	end

	local function bakeBand()
		local lut = luts[back]
		if band == 0 then
			local o = lut.origin
			o:Set(anchor)
			local sun, lightHue, lightScale, ambHue, ambScale, _, coverage = vclouds.Layer(render.GetToneMappingScaleLinear().x)
			local overcast = shaderpack.Overcast()
			local base = deckHeight(anchorLevel, overcast)
			coverage = coverage * Lerp(overcast, CLEAR_COVERAGE, 1)
			lut.mid = base + SLAB_MID
			lut.side = o.z > lut.mid and -1 or 1

			local hist = luts[cur]
			local ho = hist.origin
			cycle = cycle + 1

			local k = 1 / CLOUD_SCALE
			setConstant(BAKE, "$c0", o.x * k, o.y * k, o.z * k, lightHue)
			setConstant(BAKE, "$c1", nil, nil, (cycle * 0.618034) % 1, CurTime() % 3600)
			setConstant(BAKE, "$c2", sun.x, sun.y, sun.z, ambHue)
			setConstant(BAKE, "$c3", base * k, fogHue, coverage, fogPacked)
			bakeExtra:SetUnpacked(
				ambScale, lightScale, fogScale, lut.side,
				o.x - ho.x, o.y - ho.y, o.z - ho.z, hist.mid - o.z,
				ready and HISTORY or 0, 0, 0, 0,
				0, 0, 0, 0
			)
			BAKE:SetMatrix("$viewprojmat", bakeExtra)
			BAKE:SetTexture("$basetexture", hist.rt)
		end

		local top = math.max(band * rows - 1, 0)
		local bottom = math.min((band + 1) * rows + 1, LUT_H)
		render.PushRenderTarget(lut.rt, 0, top, LUT_W, bottom - top)
		render.OverrideAlphaWriteEnable(true, true)
		render.SetMaterial(BAKE)
		render.DrawScreenQuad()
		render.OverrideAlphaWriteEnable(false)
		render.PopRenderTarget()

		band = band + 1
		if band < BANDS then return false end

		band = 0
		if ready then
			prev, cur = cur, back
		else
			prev, cur = back, back
		end
		back = prev == cur and (cur % 3) + 1 or 6 - prev - cur
		READ:SetTexture("$basetexture", luts[cur].rt)
		READ:SetTexture("$texture1", luts[prev].rt)
		ready = true

		return true
	end

	local function bake()
		if vclouds.IsActive() or not wanted() then
			ready, band = false, 0
			return
		end

		if not luts and not allocLuts() then
			hook.Remove("PreDrawTranslucentRenderables", Tag)
			hook.Remove("PreRender", Tag)
			skyboxer.RemoveHook("e_buildclouds")
			return
		end

		local lvl = level()
		if not ready or lvl ~= anchorLevel then
			if eyeFrame < 0 then eye:Set(EyePos()) end
			anchor:Set(eye)
			if lvl then anchor.z = lvl.floor end
			anchorLevel = lvl
			ready, band = false, 0
		end

		if ready then
			if FrameNumber() % BAKE_EVERY == 0 then bakeBand() end
			return
		end

		for _ = 1, BANDS do
			if bakeBand() then break end
		end
	end

	local function viewRays()
		local ang = EyeAngles()
		local halfW, halfH = shaderpack.ViewTan()

		return ang:Forward(), ang:Right(), halfW, halfH
	end

	local function drawClouds()
		local ep = render.GetViewSetup().origin
		local frame = FrameNumber()
		if frame ~= eyeFrame then
			eyeFrame = frame
			eye:Set(ep)
		end

		if not ready or vclouds.IsActive() then return end

		local c, p = luts[cur], luts[prev]
		local fwd, right, halfW, halfH = viewRays()
		local co, po = c.origin, p.origin
		setConstant(READ, "$c0", fwd.x, fwd.y, fwd.z, band / (BANDS - 1))
		setConstant(READ, "$c1", right.x * halfW, right.y * halfW, right.z * halfW, halfH)
		setConstant(READ, "$c2", ep.x - co.x, ep.y - co.y, ep.z - co.z, c.mid - ep.z)
		setConstant(READ, "$c3", ep.x - po.x, ep.y - po.y, ep.z - po.z, p.mid - ep.z)

		render.SetMaterial(READ)
		render.DrawScreenQuad(true)
	end

	hook.Add("PreDrawTranslucentRenderables", Tag, cacheFog)
	hook.Add("PreRender", Tag, bake)
	skyboxer.RemoveHook("e_buildclouds")
	skyboxer.AddHook("e_buildclouds", drawClouds)
end

local function start()
	shaderpack.WhenMounted(Tag, { "cloudbake_ps30", "cloudlut_ps30", "aurora_vs30" }, startShader, { SHAPE, DETAIL })
end

local function stop()
	hook.Remove("PreDrawTranslucentRenderables", Tag)
	hook.Remove("PreRender", Tag)
	skyboxer.RemoveHook("e_buildclouds")
end

shaderpack.Toggle(Tag, nil, {}, start, stop)()
