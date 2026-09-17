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

	return
end

local AURORA_ENABLED = CreateClientConVar("cl_draw_auroras", 1, true, false, "should we draw auroras")
local INTENSITY = 0.35 -- brightness
local SCALE = 2 -- pattern scale
local HUE = 0.5 -- hue shift in radians
local HEIGHT = 0.8 -- height of the lowest curtain layer
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

		if mode == 1 then
			local h, m, s = tonumber(os.date("%H")), tonumber(os.date("%M")), tonumber(os.date("%S"))

			return (h * 3600 + m * 60 + s) / 86400
		end

		return tod.GetCycle and tod.GetCycle() or tod.current_cycle or 0
	end

	local function nightFactor()
		local t = dayFraction()
		if not t then return 1 end
		local d = math.min(t, 1 - t) -- distance from midnight
		local x = math.Clamp((d - 0.17) / 0.08, 0, 1)

		return 1 - x * x * (3 - 2 * x)
	end

	local function turned(v, axis, deg)
		local rad = math.rad(deg)
		local c, s = math.cos(rad), math.sin(rad)

		return v * c + axis:Cross(v) * s + axis * (axis:Dot(v) * (1 - c))
	end

	local WORLD_UP = Vector(0, 0, 1)

	-- from 22 to 02 full brightness
	local function auroraWindow()
		local t = dayFraction()
		if not t then return 1 end
		local hours = math.min(t, 1 - t) * 24
		local x = math.Clamp((2.5 - hours) / 0.5, 0, 1)

		return x * x * (3 - 2 * x)
	end

	local SCROLL_X, SCROLL_Y, SCROLL_WRAP = 0.03, 0.008, 1024

	local render_DrawScreenQuad = render.DrawScreenQuad
	local render_SetMaterial = render.SetMaterial
	local math_max = math.max
	local function viewRays()
		local night = nightFactor() * render.GetToneMappingScaleLinear().x
		if night <= 0.001 then return end

		local ang = EyeAngles()
		local origin = EyePos()
		local fwd, right, up = ang:Forward(), ang:Right(), ang:Up()

		-- ray model against the real projection
		local probeR = (origin + (fwd + right) * 512):ToScreen()
		local probeU = (origin + (fwd + up) * 512):ToScreen()
		local ndcR = (probeR.x / ScrW()) * 2 - 1
		local ndcU = 1 - (probeU.y / ScrH()) * 2

		return night, fwd, right, 1 / math_max(0.05, ndcR), 1 / math_max(0.05, ndcU)
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

		SKY_MAT:SetFloat("$c0_x", sFwd.x)
		SKY_MAT:SetFloat("$c0_y", sFwd.y)
		SKY_MAT:SetFloat("$c0_z", sFwd.z)
		SKY_MAT:SetFloat("$c0_w", CurTime() % TIME_PERIOD)
		SKY_MAT:SetFloat("$c1_x", sRight.x * halfW)
		SKY_MAT:SetFloat("$c1_y", sRight.y * halfW)
		SKY_MAT:SetFloat("$c1_z", sRight.z * halfW)
		SKY_MAT:SetFloat("$c1_w", halfH)
		SKY_MAT:SetFloat("$c2_x", sUp.x)
		SKY_MAT:SetFloat("$c2_y", SKY_STARS * gain)
		SKY_MAT:SetFloat("$c2_z", SKY_MILKYWAY * gain)
		SKY_MAT:SetFloat("$c2_w", sUp.y)
		SKY_MAT:SetFloat("$c3_w", SKY_AIRGLOW * gain)
		render_SetMaterial(SKY_MAT)
		render_DrawScreenQuad(true)
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
		MAT:SetFloat("$c2_z", (drift * SCROLL_X) % SCROLL_WRAP)
		MAT:SetFloat("$c3_w", (drift * SCROLL_Y) % SCROLL_WRAP)

		render_SetMaterial(MAT)
		render_DrawScreenQuad(true)
	end

	hook.Remove("PostDraw2DSkyBox", "aurora_sky")
	if skyboxer then
		skyboxer.RemoveHook("b_aurora_nightsky")
		skyboxer.RemoveHook("d_aurora_curtains")
		skyboxer.AddHook("b_aurora_nightsky", drawNightSky)
		skyboxer.AddHook("d_aurora_curtains", drawAurora)
	else
		hook.Add("PostDraw2DSkyBox", "aurora_sky", function()
			if not AURORA_ENABLED:GetEnabled() then return end
			drawNightSky()
			drawAurora()
		end)
	end
end

local function tryStart()
	local aurora, nightsky = "aurora_ps30", "nightsky_ps30"
	if not file.Exists("shaders/fxc/aurora_vs30.vcs", "GAME") then return false end
	start(aurora, nightsky)

	return true
end

hook.Remove("ShaderMounted", "aurora_sky")
if not tryStart() and HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
	hook.Add("ShaderMounted", "aurora_sky", function()
		hook.Remove("ShaderMounted", "aurora_sky")

		tryStart()
	end)
end