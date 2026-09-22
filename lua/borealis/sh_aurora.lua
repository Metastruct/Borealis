AddCSLuaFile()

local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

if SERVER then
	if not resource.AddShader then return end

	resource.AddShader("aurora_vs30")
	resource.AddShader("aurora_ps30")
	resource.AddShader("nightsky_ps30")
	resource.AddFile("materials/aurora/noise.vtf")

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
local SKY_MILKYWAY = 1 -- milky way brightness
local SKY_AIRGLOW = 1 -- horizon haze brightness
local SKY_POLE = Angle(-35, 60, 0):Forward()
local SKY_AXIS = Angle(-55, 0, 0):Forward()
local SKY_TURN_RATE = 0.25

local function start(PIXEL_SHADER, SKY_SHADER)
	local function shaderMaterial(name, pixelShader, constants)
		local kv = {
			["$pixshader"] = pixelShader,
			["$vertexshader"] = "aurora_vs30",
			["$basetexture"] = "",
			["$ignorez"] = 1,
			["$vertexcolor"] = 1,
			["$vertextransform"] = 1,
			["$additive"] = 1,
			["$alpha_blend"] = 0,
			["$linearwrite"] = 1,
			["<dx90"] = { ["$no_draw"] = 1 },
		}

		for k, v in pairs(constants) do
			kv[k] = v
		end

		return CreateMaterial(name .. "_" .. os.time(), "screenspace_general", kv)
	end

	local MAT = shaderMaterial("aurora_sky", PIXEL_SHADER, {
		["$basetexture"] = "aurora/noise",
		["$linearread_basetexture"] = 1,
		["$c0_x"] = 1, ["$c0_y"] = 0,
		["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 1,
		["$c1_z"] = 0, ["$c1_w"] = 1,
		["$c2_x"] = 1, ["$c2_y"] = SCALE,
		["$c2_z"] = 0, ["$c2_w"] = HUE,
		["$c3_x"] = HEIGHT, ["$c3_y"] = WIDTH,
		["$c3_z"] = SHARPNESS, ["$c3_w"] = 0,
	})

	local SKY_MAT = shaderMaterial("aurora_nightsky", SKY_SHADER, {
		["$c0_x"] = 1, ["$c0_y"] = 0,
		["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 1,
		["$c1_z"] = 0, ["$c1_w"] = 1,
		["$c2_x"] = 0, ["$c2_y"] = SKY_STARS,
		["$c2_z"] = SKY_MILKYWAY, ["$c2_w"] = 0,
		["$c3_x"] = SKY_POLE.x, ["$c3_y"] = SKY_POLE.y,
		["$c3_z"] = SKY_POLE.z, ["$c3_w"] = SKY_AIRGLOW,
	})

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

		return math.deg(math.asin(math.Clamp(-C.sun_angles:Forward().z, -1, 1)))
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
		local vs = render.GetViewSetup()
		local halfW = math.tan(math.rad(vs.fov) * 0.5)

		return night, ang:Forward(), ang:Right(), halfW, halfW / vs.aspect
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

		SKY_MAT:SetFloat("$c0_x", sFwd.x)
		SKY_MAT:SetFloat("$c0_y", sFwd.y)
		SKY_MAT:SetFloat("$c0_z", sFwd.z)
		SKY_MAT:SetFloat("$c0_w", CurTime() % TIME_PERIOD)
		SKY_MAT:SetFloat("$c1_x", sRight.x * halfW)
		SKY_MAT:SetFloat("$c1_y", sRight.y * halfW)
		SKY_MAT:SetFloat("$c1_z", sRight.z * halfW)
		SKY_MAT:SetFloat("$c1_w", halfH)
		SKY_MAT:SetFloat("$c2_x", sUp.x)
		SKY_MAT:SetFloat("$c2_y", SKY_STARS * gain * (t.stars or 1))
		SKY_MAT:SetFloat("$c2_z", SKY_MILKYWAY * gain)
		SKY_MAT:SetFloat("$c2_w", sUp.y)
		SKY_MAT:SetFloat("$c3_w", SKY_AIRGLOW * gain * (t.airglow or 1))
		render_SetMaterial(SKY_MAT)
		render_DrawScreenQuad(true)
	end

	local function curtainHeight()
		local eye = EyePos().z
		local lvl = skylevels and skylevels.Get()

		return math.max(HEIGHT - (eye - (lvl and lvl.floor or eye)) / AURORA_SCALE, AURORA_MIN)
	end

	local function drawAurora()
		local window = auroraWindow()
		if window <= 0.001 then return end
		local night, fwd, right, halfW, halfH = viewRays()
		if not night then return end

		-- the band along its x axis
		local turn = Angle(0, -HEADING, 0)
		fwd:Rotate(turn)
		right:Rotate(turn)

		local drift = CurTime()

		MAT:SetFloat("$c0_x", fwd.x)
		MAT:SetFloat("$c0_y", fwd.y)
		MAT:SetFloat("$c0_z", fwd.z)
		MAT:SetFloat("$c0_w", drift % TIME_PERIOD)
		MAT:SetFloat("$c1_x", right.x * halfW)
		MAT:SetFloat("$c1_y", right.y * halfW)
		MAT:SetFloat("$c1_z", right.z * halfW)
		MAT:SetFloat("$c1_w", halfH)
		MAT:SetFloat("$c2_x", night * window * INTENSITY)
		MAT:SetFloat("$c2_w", theme().auroraHue or HUE)
		MAT:SetFloat("$c2_z", (drift * SCROLL_X) % SCROLL_WRAP)
		MAT:SetFloat("$c3_x", curtainHeight())
		MAT:SetFloat("$c3_w", (drift * SCROLL_Y) % SCROLL_WRAP)

		render_SetMaterial(MAT)
		render_DrawScreenQuad(true)
	end

	hook.Remove("PostDraw2DSkyBox", "aurora_sky")
	if skyboxer then
		skyboxer.RemoveHook("b_aurora_nightsky")
		skyboxer.RemoveHook("d_aurora_curtains")
		skyboxer.AddHook("b_aurora_nightsky", drawNightSky)
		skyboxer.AddHook("d_aurora_curtains", function()
			if not AURORA_ENABLED:GetBool() then return end

			drawAurora()
		end)
	else
		hook.Add("PostDraw2DSkyBox", "aurora_sky", function()
			if not AURORA_ENABLED:GetBool() then return end
			drawNightSky()
			drawAurora()
		end)
	end
end

local function shadersAvailable()
	for _, name in ipairs({ "aurora_vs30", "aurora_ps30", "nightsky_ps30" }) do
		if not file.Exists("shaders/fxc/" .. name .. ".vcs", "GAME") then return false end
	end

	return true
end

local function tryStart()
	if not shadersAvailable() then return false end
	start("aurora_ps30", "nightsky_ps30")

	return true
end

hook.Remove("ShaderMounted", "aurora_sky")
if not tryStart() and HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
	hook.Add("ShaderMounted", "aurora_sky", function()
		hook.Remove("ShaderMounted", "aurora_sky")

		tryStart()
	end)
end