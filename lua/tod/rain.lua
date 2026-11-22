-- Rain, March to November, on tod's weather schedule: the override config
-- carries the fog and the engine sky, procsky's theme carries the overcast,
-- the darker fog and a flat cast, and tod.rain.Flash lights the sky for
-- borealis' thunder.
local PROBABILITY = 0.20
local CURVE = 0.35 -- the sky greys over well before the rain is heavy
local config = {
	["fog_start"] = 0,
	["fog_end"] = 6000,
	["fog_max_density"] = 0.7,
	["fog_color"] = Vector(150, 155, 160),
	["star_intensity"] = 0,
	["sky_topcolor"] = Vector(1, 1, 1) * 0.35,
	["sky_bottomcolor"] = Vector(1, 1, 1) * 0.45,
	["sky_sunsize"] = 0,
	["sky_starfade"] = 0,
	["sky_duskintensity"] = 0,
	["light_scale"] = 0.55, -- the world light at full rain, applied by tod after the sun is placed
}

tod.AddOverrideConfig("rain", config, PROBABILITY, CURVE)

if not CLIENT then return end

local DECK_BRIGHTNESS = 0.6 -- the deck sits darker than snow's stratus
local FOG_SCALE = 0.75
local FLASH_TIME = 0.12
local FLASH = {
	["$pp_colour_addr"] = 0.35,
	["$pp_colour_addg"] = 0.35,
	["$pp_colour_addb"] = 0.4,
	["$pp_colour_brightness"] = 0,
	["$pp_colour_contrast"] = 1,
	["$pp_colour_colour"] = 1,
	["$pp_colour_mulr"] = 0,
	["$pp_colour_mulg"] = 0,
	["$pp_colour_mulb"] = 0,
}

tod.rain = tod.rain or {
	amount = 0, -- read by sh_precipitations for the streaks
	covered = false
}

local amount = 0 -- last amount pushed into the theme
local saved -- the season's own fogScale and tint while rain overrides them
local flashUntil = 0

-- rain's keys on top of whatever theme the season set (halloween in October)
local function applyTheme(a, flash)
	local procsky = shaderpack and shaderpack.procsky
	if not (procsky and procsky.SetTheme) then return end
	local t = table.Copy(procsky.theme)
	if a > 0 then
		-- the deck greys over on the same curve tod puts the sky through, or
		-- the engine sky is overcast while procsky's clouds are still thin
		a = a ^ CURVE
		saved = saved or {
			fogScale = t.fogScale,
			tint = t.tint
		}

		t.overcast = a
		t.overcastBrightness = DECK_BRIGHTNESS
		t.fogScale = (saved.fogScale or 1) * (1 - (1 - FOG_SCALE) * a)
		t.tint = flash and FLASH or {
			["$pp_colour_addr"] = 0,
			["$pp_colour_addg"] = 0,
			["$pp_colour_addb"] = 0,
			["$pp_colour_brightness"] = -0.03 * a,
			["$pp_colour_contrast"] = 1,
			["$pp_colour_colour"] = 1 - 0.2 * a,
			["$pp_colour_mulr"] = 0,
			["$pp_colour_mulg"] = 0,
			["$pp_colour_mulb"] = 0,
		}
	else
		t.overcast, t.overcastBrightness = nil, nil
		if saved then
			t.fogScale, t.tint = saved.fogScale, saved.tint
			saved = nil
		end
	end

	procsky.SetTheme(next(t) and t or nil)
end

function tod.rain.Flash()
	if amount <= 0 then return end

	flashUntil = RealTime() + FLASH_TIME
	applyTheme(amount, true)
end

hook.Add("Think", "tod_rain", function()
	local a = tod.GetWeather("rain")
	local now = RealTime()
	if a ~= amount then
		amount = a
		applyTheme(a, now < flashUntil)
	elseif flashUntil > 0 and now >= flashUntil then
		flashUntil = 0
		applyTheme(a, false)
	end

	tod.rain.amount = a
end)
