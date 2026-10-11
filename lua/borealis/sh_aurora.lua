AddCSLuaFile()

local SHADERS = { "aurora_vs30", "aurora_ps30", "aurora_map_ps30", "nightsky_ps30" }

if SERVER then
	shaderpack.AddResources(SHADERS, { "materials/aurora/noise.vtf", "materials/aurora/milkyway.vtf" })

	return
end

local AURORA_ENABLED = CreateClientConVar("cl_draw_auroras", 1, true, false, "should we draw auroras")
local INTENSITY = 0.35 -- brightness
local SCALE = 2 -- pattern scale
local HUE = 0.5 -- hue shift in radians
local HEIGHT = 1.235 -- height of the lowest curtain layer, seen from a level's floor
local AURORA_SCALE = 30000 -- world units per curtain unit
local AURORA_MIN = 0.15 -- the layers never collapse onto the eye
local SHARPNESS = 1 -- curtain streak sharpness
local WIDTH = 3 -- half-width of the band
local HEADING = 10 -- world yaw the band runs along IN DEGREES

local SKY_INTENSITY = 0.25 -- overall night sky brightness
local SKY_STARS = 2 -- star brightness
local SKY_MILKYWAY = 6 -- milky way brightness
local SKY_AIRGLOW = 1 -- horizon haze brightness
local SKY_POLE = Angle(-35, 60, 0):Forward()
local SKY_AXIS = Angle(-55, 0, 0):Forward()
local SKY_TURN_RATE = 0.25
local MAP_SIZE = 1024

local setConstant = shaderpack.SetConstant

local function start(PIXEL_SHADER, SKY_SHADER, MAP_SHADER)
	local function shaderMaterial(name, pixelShader, constants)
		local kv = {
			["$pixshader"] = pixelShader,
			["$vertexshader"] = "aurora_vs30",
			["$additive"] = 1,
			["$alpha_blend"] = 0,
		}

		for k, v in pairs(constants) do
			kv[k] = v
		end

		return CreateShaderMaterial(name .. "_" .. os.time(), kv)
	end

	local MAT = shaderMaterial("ms_aurora_sky", PIXEL_SHADER, {
		["$basetexture"] = "aurora/noise",
		["$linearread_texture1"] = 1,
		["$c0_x"] = 1, ["$c0_y"] = 0,
		["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 1,
		["$c1_z"] = 0, ["$c1_w"] = 1,
		["$c2_x"] = 1, ["$c2_y"] = SCALE,
		["$c2_z"] = 0, ["$c2_w"] = HUE,
		["$c3_x"] = HEIGHT, ["$c3_y"] = WIDTH,
		["$c3_z"] = SHARPNESS, ["$c3_w"] = 0,
	})

	local SKY_MAT = shaderMaterial("ms_aurora_nightsky", SKY_SHADER, {
		["$basetexture"] = "aurora/milkyway",
		["$c0_x"] = 1, ["$c0_y"] = 0,
		["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 1,
		["$c1_z"] = 0, ["$c1_w"] = 1,
		["$c2_x"] = 0, ["$c2_y"] = SKY_STARS,
		["$c2_z"] = SKY_MILKYWAY, ["$c2_w"] = 0,
		["$c3_x"] = SKY_POLE.x, ["$c3_y"] = SKY_POLE.y,
		["$c3_z"] = SKY_POLE.z, ["$c3_w"] = SKY_AIRGLOW,
	})

	local MAP_MAT = shaderMaterial("ms_aurora_map", MAP_SHADER, {
		["$basetexture"] = "aurora/noise",
		["$additive"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = SCALE,
		["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = WIDTH, ["$c1_y"] = MAP_SIZE,
	})

	local usableRT = shaderpack.UsableRT
	local curtainMap

	local function curtainTarget()
		if not usableRT(curtainMap, MAP_SIZE, MAP_SIZE) then
			curtainMap = GetRenderTargetEx("ms_aurora_curtains_" .. MAP_SIZE, MAP_SIZE, MAP_SIZE, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 12, 0, IMAGE_FORMAT_RGBA16161616F)
			if not usableRT(curtainMap, MAP_SIZE, MAP_SIZE) then return nil end
		end

		return curtainMap
	end

	local NOISE_SPEED = 0.06
	local TIME_PERIOD = 2 * math.pi / NOISE_SPEED

	local function dayFraction()
		if not tod then return nil end
		local mode = GetConVar("sv_tod") and GetConVar("sv_tod"):GetInt() or 0

		if mode == 1 and tod.GetRealTime then
			return tod.GetRealTime()
		end

		return tod.GetCycle and tod.GetCycle() or tod.current_cycle or 0
	end

	-- sun elevation in degrees from tod's sun, nil without tod
	local function sunElevation()
		local C = tod and tod.CurrentParams
		if not (C and isangle(C.sun_angles)) then return nil end

		return shaderpack.Elevation(-C.sun_angles:Forward())
	end

	local function nightFactor()
		local e = sunElevation()
		if e then
			-- stars from 3 degrees below the horizon, full at 9 (tod's twilight bottoms out at 12)
			local x = math.Clamp((-e - 3) / 6, 0, 1)

			return x * x * (3 - 2 * x)
		end

		local t = dayFraction()
		if not t then return 1 end
		-- full from 21:30 to 02:30, gone by 20:00 / 04:00
		local hours = math.min(t, 1 - t) * 24
		local x = math.Clamp((hours - 2.5) / 1.5, 0, 1)

		return 1 - x * x * (3 - 2 * x)
	end

	local function turned(v, axis, deg)
		local rad = math.rad(deg)
		local c, s = math.cos(rad), math.sin(rad)

		return v * c + axis:Cross(v) * s + axis * (axis:Dot(v) * (1 - c))
	end

	local WORLD_UP = Vector(0, 0, 1)

	-- deep night only, clock fallback from 22 to 02 without tod
	local function auroraWindow()
		local e = sunElevation()
		if e then
			local x = math.Clamp((-e - 8) / 3, 0, 1)

			return x * x * (3 - 2 * x)
		end

		local t = dayFraction()
		if not t then return 1 end
		local hours = math.min(t, 1 - t) * 24
		local x = math.Clamp((2.5 - hours) / 0.5, 0, 1)

		return x * x * (3 - 2 * x)
	end

	local SCROLL_X, SCROLL_Y, SCROLL_WRAP = 0.03, 0.008, 1024

	local NO_THEME = {}
	local function theme()
		return procsky and procsky.theme or NO_THEME
	end

	local render_DrawScreenQuad = render.DrawScreenQuad
	local render_SetMaterial = render.SetMaterial
	-- basis from EyeAngles, which is right inside a RenderView too; the fan
	-- from the view setup's fov (horizontal, aspect-adjusted)
	local function viewRays()
		local night = nightFactor() * render.GetToneMappingScaleLinear().x
		if night <= 0.001 then return end

		local ang = EyeAngles()
		local halfW, halfH = shaderpack.ViewTan()

		return night, ang:Forward(), ang:Right(), halfW, halfH
	end

	local function drawNightSky()
		local night, fwd, right, halfW, halfH = viewRays()
		if not night then return end

		-- go the opposite way
		local skyTurn = -(CurTime() * SKY_TURN_RATE) % 360
		local sFwd = turned(fwd, SKY_AXIS, skyTurn)
		local sRight = turned(right, SKY_AXIS, skyTurn)
		local sUp = turned(WORLD_UP, SKY_AXIS, skyTurn)
		local gain = night * SKY_INTENSITY
		local t = theme()

		setConstant(SKY_MAT, "$c0", sFwd.x, sFwd.y, sFwd.z, CurTime() % TIME_PERIOD)
		setConstant(SKY_MAT, "$c1", sRight.x * halfW, sRight.y * halfW, sRight.z * halfW, halfH)
		setConstant(SKY_MAT, "$c2", sUp.x, SKY_STARS * gain * (t.stars or 1), SKY_MILKYWAY * gain, sUp.y)
		SKY_MAT:SetFloat("$c3_w", SKY_AIRGLOW * gain * (t.airglow or 1))
		render_SetMaterial(SKY_MAT)
		render_DrawScreenQuad(true)
	end

	local function curtainHeight()
		local eye = EyePos().z
		local lvl = skylevels and skylevels.Get()

		return math.max(HEIGHT - (eye - (lvl and lvl.floor or eye)) / AURORA_SCALE, AURORA_MIN)
	end

	local function renderCurtainMap()
		if not AURORA_ENABLED:GetBool() or auroraWindow() <= 0.001 or nightFactor() <= 0.001 then return end
		local rt = curtainTarget()
		if not rt then return end

		local drift = CurTime()
		setConstant(MAP_MAT, "$c0", drift % TIME_PERIOD, nil, (drift * SCROLL_X) % SCROLL_WRAP, (drift * SCROLL_Y) % SCROLL_WRAP)

		render.PushRenderTarget(rt)
		render_SetMaterial(MAP_MAT)
		render_DrawScreenQuad(true)
		render.PopRenderTarget()
	end

	local function drawAurora()
		local window = auroraWindow()
		if window <= 0.001 then return end

		local rt = curtainTarget()
		if not rt then return end

		local night, fwd, right, halfW, halfH = viewRays()
		if not night then return end

		-- the band along its x axis
		local turn = Angle(0, -HEADING, 0)
		fwd:Rotate(turn)
		right:Rotate(turn)

		local drift = CurTime()

		setConstant(MAT, "$c0", fwd.x, fwd.y, fwd.z, drift % TIME_PERIOD)
		setConstant(MAT, "$c1", right.x * halfW, right.y * halfW, right.z * halfW, halfH)
		setConstant(MAT, "$c2", night * window * INTENSITY, nil, (drift * SCROLL_X) % SCROLL_WRAP, theme().auroraHue or HUE)
		setConstant(MAT, "$c3", curtainHeight(), nil, nil, (drift * SCROLL_Y) % SCROLL_WRAP)

		MAT:SetTexture("$texture1", rt)
		render_SetMaterial(MAT)
		render_DrawScreenQuad(true)
	end

	hook.Add("PreRender", "ms_aurora_curtains", renderCurtainMap)

	hook.Remove("PostDraw2DSkyBox", "ms_aurora_sky")
	if skyboxer then
		skyboxer.RemoveHook("b_aurora_nightsky")
		skyboxer.RemoveHook("d_aurora_curtains")
		skyboxer.AddHook("b_aurora_nightsky", drawNightSky)
		skyboxer.AddHook("d_aurora_curtains", function()
			if not AURORA_ENABLED:GetBool() then return end

			drawAurora()
		end)
	else
		hook.Add("PostDraw2DSkyBox", "ms_aurora_sky", function()
			if not AURORA_ENABLED:GetBool() then return end
			drawNightSky()
			drawAurora()
		end)
	end
end

shaderpack.WhenMounted("ms_aurora_sky", SHADERS, function()
	start("aurora_ps30", "nightsky_ps30", "aurora_map_ps30")
end)