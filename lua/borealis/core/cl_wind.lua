local wind = shaderpack.wind or {}
shaderpack.wind = wind

local HEADING = math.rad(20)
local BREEZE_BASE, BREEZE_SWING = 0.3, 0.15
local BREEZE_PERIOD_A, BREEZE_PERIOD_B = 340, 530
local RAIN_STRENGTH = 1.5
local SNOW_STRENGTH = 0.5
local FOG_CALM = 0.7
local EASE = 0.2
local TAU = math.pi * 2

wind.HEADING = HEADING
wind.X, wind.Y = math.cos(HEADING), math.sin(HEADING)

local function amount(name)
	local w = tod and tod[name]

	return w and w.amount or 0
end

local function target()
	local t = os.time()
	local s = BREEZE_BASE + BREEZE_SWING * (math.sin(t / BREEZE_PERIOD_A * TAU) + math.sin(t / BREEZE_PERIOD_B * TAU)) * 0.5
	s = Lerp(amount("rain"), s, RAIN_STRENGTH)
	s = Lerp(amount("snow"), s, SNOW_STRENGTH)

	return s * (1 - FOG_CALM * amount("fog"))
end

local strength, updatedFrame = nil, -1

function wind.Strength()
	local frame = FrameNumber()
	if frame ~= updatedFrame then
		updatedFrame = frame
		local goal = target()
		strength = strength and strength + (goal - strength) * math.min(1, RealFrameTime() * EASE) or goal
	end

	return strength
end
