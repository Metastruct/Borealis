if SERVER then
	shaderpack.AddResources({ "clouds_ps30" }, { "materials/clouds/noise.vtf" })

	return
end

require("skyboxer")

local Tag = "ms_cheap_clouds"
local ENABLED = CreateClientConVar("cl_draw_clouds", "1", true, false, "Draw cheap clouds in the skybox", 0, 1)

local function level()
	if procsky and procsky.theme and procsky.theme.clouds == false then return end
	if not ENABLED:GetBool() then return end

	return skylevels and skylevels.Get()
end

local COVERAGE = 0.5
local INTENSITY = 1
local WIND = { 0.012, 0.004 } -- noise units per second
local NOISE_SCALE = 20000 -- world units per noise unit, S_LO in clouds_ps30
local EYE_K = 1 / NOISE_SCALE -- parallax while moving, the same at any deck height
local NOISE_PERIOD = 64
local DECK_CLEAR = 4800 -- least a deck stands over its level's floor, past FADE_H in clouds_ps30
local SKY_DECK_Z = 14000 -- the overcast deck, and the deck outside every level

local function deckHeight(lvl, overcast)
	local z = math.max(lvl.ceiling, lvl.floor + DECK_CLEAR)

	return Lerp(overcast, z, math.max(z, SKY_DECK_Z))
end

local packColor, setConstant = shaderpack.PackColor, shaderpack.SetConstant

local function lightInfo()
	if procsky and procsky.IsActive() then
		return procsky.GetCloudLighting()
	end

	local params = tod and tod.CurrentParams
	local sun = params and isangle(params.sun_angles) and params.sun_angles
	local moon = params and isangle(params.moon_angles) and params.moon_angles
	local sunDir = sun and -sun:Forward() or Vector(0, 0, 1)

	if sunDir.z > -0.12 then
		local t = math.Clamp((sunDir.z + 0.08) / 0.35, 0, 1)
		local light = { 1, Lerp(t, 0.42, 0.96), Lerp(t, 0.18, 0.9) }
		local amb = { Lerp(t, 0.30, 0.60), Lerp(t, 0.26, 0.68), Lerp(t, 0.38, 0.84) }
		local fade = math.Clamp((sunDir.z + 0.12) / 0.1, 0, 1) -- dim everything
		for i = 1, 3 do
			light[i] = light[i] * fade
			amb[i] = Lerp(fade, 0.035, amb[i])
		end

		return sunDir, light, amb
	end

	local moonDir = moon and -moon:Forward() or Vector(0, 0, 1)
	if moonDir.z < 0.05 then moonDir = Vector(0, 0, 1) end

	return moonDir, { 0.10, 0.12, 0.17 }, { 0.03, 0.035, 0.06 }
end

local function startShader(PIXEL_SHADER)
	local MAT = CreateShaderMaterial("buildclouds_" .. os.time(), {
		["$pixshader"] = PIXEL_SHADER,
		["$vertexshader"] = "aurora_vs30",
		["$basetexture"] = "clouds/noise",
		["$additive"] = 0,
		["$c0_x"] = 1, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 1,
		["$c1_x"] = 0, ["$c1_y"] = 1, ["$c1_z"] = 0, ["$c1_w"] = 1,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 1, ["$c2_w"] = COVERAGE,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})

	-- basis from EyeAngles, which is right inside a RenderView too; the fan
	-- from the view setup's fov (horizontal, aspect-adjusted)
	local function viewRays()
		local ang = EyeAngles()
		local halfW, halfH = shaderpack.ViewTan()

		return ang:Forward(), ang:Right(), halfW, halfH
	end

	local deckLight, deckAmb = { 0, 0, 0 }, { 0, 0, 0 }

	-- the build area's clouds, or a deck over the whole sky when procsky is overcast
	local function drawClouds()
		-- the volumetric clouds replace this deck, overcast included, while on
		if vclouds and vclouds.IsActive() then return end
		local overcast = shaderpack.Overcast()
		local lvl = level()
		if not lvl and overcast < 0.01 then return end
		-- the shader lerps its threshold by coverage, so past 1 the deck closes up
		-- and past 2 it has no thin spots for the sun to show through
		local coverage = math.max(lvl and COVERAGE or 0, overcast * 2.2)

		local fwd, right, halfW, halfH = viewRays()
		local lightDir, light, amb = lightInfo()
		if overcast > 0 then
			-- a bright flat deck: the sun's colour drains so the noise barely
			-- shades it, the ambient goes to a light grey well above the sky's own
			local lum = 0.2126 * amb[1] + 0.7152 * amb[2] + 0.0722 * amb[3]
			local bright = procsky.theme.overcastBrightness or 1
			for i = 1, 3 do
				deckLight[i] = light[i] * (1 - 0.8 * overcast) * bright
				deckAmb[i] = amb[i] + (lum * 3 * bright - amb[i]) * overcast
			end

			light, amb = deckLight, deckAmb
		end

		local ep = EyePos()
		local t = CurTime()
		local deckZ = lvl and deckHeight(lvl, overcast) or SKY_DECK_Z

		setConstant(MAT, "$c0", fwd.x, fwd.y, fwd.z, INTENSITY * render.GetToneMappingScaleLinear().x)
		setConstant(MAT, "$c1", right.x * halfW, right.y * halfW, right.z * halfW, halfH)
		setConstant(MAT, "$c2", lightDir.x, lightDir.y, deckZ - ep.z, coverage)
		setConstant(MAT, "$c3", (WIND[1] * t + ep.x * EYE_K) % NOISE_PERIOD, (WIND[2] * t + ep.y * EYE_K) % NOISE_PERIOD, packColor(light[1], light[2], light[3]), packColor(amb[1], amb[2], amb[3]))

		render.SetMaterial(MAT)
		render.DrawScreenQuad(true)
	end

	skyboxer.RemoveHook("d_" .. Tag)
	skyboxer.RemoveHook("e_buildclouds")
	skyboxer.AddHook("e_buildclouds", drawClouds)
end

-- fallback
local function startMesh()
	local sz = 8192 * 8 * 4
	local q = sz * (1 / (8192 * 2 * 4))
	local mesh = Mesh()

	mesh:BuildFromTriangles({
		{ pos = sz * Vector(0.5, 0.5, 0), u = q, v = q, normal = Vector(0, 0, 1) },
		{ pos = sz * Vector(0.5, -0.5, 0), u = q, v = 0, normal = Vector(0, 0, 1) },
		{ pos = sz * Vector(-0.5, -0.5, 0), u = 0, v = 0, normal = Vector(0, 0, 1) },
		{ pos = sz * Vector(-0.5, -0.5, 0), u = -q, v = -q, normal = Vector(0, 0, 1) },
		{ pos = sz * Vector(-0.5, 0.5, 0), u = -q, v = 0, normal = Vector(0, 0, 1) },
		{ pos = sz * Vector(0.5, 0.5, 0), u = 0, v = 0, normal = Vector(0, 0, 1) },
	})

	local function cloudMaterial(name, rate)
		return CreateMaterial(name, "VertexLitGeneric", {
			["$basetexture"] = "shadertest/cloud",
			["$translucent"] = 1,
			["$alpha"] = 0.2,
			Proxies = {
				TextureScroll = {
					texturescrollvar = "$baseTextureTransform",
					texturescrollrate = rate,
					texturescrollangle = 0,
				},
			},
		})
	end

	local mat1 = cloudMaterial(Tag, 0.01)
	local mat2 = cloudMaterial(Tag .. "2", 0.03)

	local t = {
		model = "models/props_junk/sawblade001a.mdl",
		angle = Angle(0, 0, 0),
		pos = Vector(0, 0, -4000)
	}

	local clm
	local off = Vector(0, 0, -1048)
	local rotate_1 = Angle(0, 45, 0)
	local rotate_2 = Angle(180, 0, 0)
	local vector_origin = Vector(0, 0, 0)
	local translate_1 = Vector(2111, 1400, 475)
	local translate_2 = Vector(-1123, -1223, 900)
	local translate_3 = Vector(3123, 4123, 600)
	local off2 = Vector(0, 0, 2000)
	local off3 = Vector(0, 0, 4024)
	local mat = Matrix()
	local off_off2 = off + off2

	local function drawMesh()
		if not level() then return end

		local trans = EyePos()
		trans:Mul(-1)
		trans:Add(off)
		trans:Add(off3)
		mat:Identity()
		mat:SetTranslation(trans)
		mat:Rotate(rotate_2)
		clm = clm and clm:IsValid() and clm or ClientsideModel(t.model, RENDERGROUP_OTHER)
		clm:SetPos(off_off2)
		render.SetBlend(0)
		render.Model(t, clm)
		render.SetBlend(1)
		render.SetMaterial(mat1)

		-- enjoy black magic
		cam.Start3D(vector_origin, EyeAngles(), nil, nil, nil, nil, nil, 256, 8192 * 2 * 2 * 2 * 2)
		cam.PushModelMatrix(mat)
		mesh:Draw()
		cam.PopModelMatrix()
		mat:Translate(translate_1)
		cam.PushModelMatrix(mat)
		mesh:Draw()
		cam.PopModelMatrix()
		mat:Rotate(rotate_1)
		render.SetMaterial(mat2)

		mat:Translate(translate_2)
		cam.PushModelMatrix(mat)
		mesh:Draw()
		cam.PopModelMatrix()
		mat:Translate(translate_3)
		cam.PushModelMatrix(mat)
		mesh:Draw()
		cam.PopModelMatrix()
		cam.End3D()
		render.ClearDepth()
	end

	-- moon draws before this
	skyboxer.RemoveHook("d_" .. Tag)
	skyboxer.AddHook("d_" .. Tag, drawMesh)
end

if not shaderpack.WhenMounted(Tag, { "clouds_ps30", "aurora_vs30" }, function() startShader("clouds_ps30") end) then
	startMesh()
end
