-- Rain, March to November, on tod's weather schedule: the override config
-- carries the fog and the engine sky, procsky's theme carries the overcast,
-- the darker fog and a flat cast, and the client plays the rumble outside,
-- drips under cover and thunder with a flash when the rain is heavy.
local PROBABILITY = 0.25
local CURVE = 0.35 -- the sky greys over well before the rain is heavy

local config = {
	["fog_start"] = 0,
	["fog_end"] = 6000,
	["fog_max_density"] = 0.35,
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
local RUMBLE = "ambient/weather/rumble_rain.wav"
local COVER_VOLUME = 0.3 -- rumble share heard under a roof
local DRIP_INTERVAL = { 0.6, 1.8 }
local THUNDER_AMOUNT = 0.8 -- heavy rain only
local THUNDER_INTERVAL = { 25, 70 }
local FLASH_TIME = 0.12
local FLASH = {
	["$pp_colour_addr"] = 0.35, ["$pp_colour_addg"] = 0.35, ["$pp_colour_addb"] = 0.4,
	["$pp_colour_brightness"] = 0, ["$pp_colour_contrast"] = 1, ["$pp_colour_colour"] = 1,
	["$pp_colour_mulr"] = 0, ["$pp_colour_mulg"] = 0, ["$pp_colour_mulb"] = 0,
}

tod.rain = tod.rain or { amount = 0, covered = false } -- read by sh_rain for the streaks

local amount = 0 -- last amount pushed into the theme
local saved -- the season's own fogScale and tint while rain overrides them
local flashUntil = 0
local covered = false
local nextCover, nextDrip, nextThunder = 0, 0, 0

-- a reload must not leave the old rumble playing
if tod.rain_rumble then
	tod.rain_rumble:Stop()
	tod.rain_rumble = nil
end

-- rain's keys on top of whatever theme the season set (halloween in October)
local function applyTheme(a, flash)
	if not (procsky and procsky.SetTheme) then return end
	local t = table.Copy(procsky.theme)

	if a > 0 then
		-- the deck greys over on the same curve tod puts the sky through, or
		-- the engine sky is overcast while procsky's clouds are still thin
		a = a ^ CURVE
		saved = saved or { fogScale = t.fogScale, tint = t.tint }
		t.overcast = a
		t.overcastBrightness = DECK_BRIGHTNESS
		t.fogScale = (saved.fogScale or 1) * (1 - (1 - FOG_SCALE) * a)
		t.tint = flash and FLASH or {
			["$pp_colour_addr"] = 0, ["$pp_colour_addg"] = 0, ["$pp_colour_addb"] = 0,
			["$pp_colour_brightness"] = -0.03 * a, ["$pp_colour_contrast"] = 1, ["$pp_colour_colour"] = 1 - 0.2 * a,
			["$pp_colour_mulr"] = 0, ["$pp_colour_mulg"] = 0, ["$pp_colour_mulb"] = 0,
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

local coverTrace = { mask = bit.bor(CONTENTS_SOLID, CONTENTS_MOVEABLE, CONTENTS_WINDOW, CONTENTS_GRATE) } -- props count as cover, players do not

local function underCover()
	local eye = EyePos()
	coverTrace.start = eye
	coverTrace.endpos = eye + Vector(0, 0, 8192)
	local tr = util.TraceLine(coverTrace)

	return tr.Hit and not tr.HitSky
end

local function stopRumble()
	if not tod.rain_rumble then return end
	tod.rain_rumble:FadeOut(2)
	tod.rain_rumble = nil
end

hook.Add("Think", "tod_rain", function()
	local a = tod.GetWeather("rain", PROBABILITY)
	local now = RealTime()

	if a ~= amount then
		if amount == 0 then
			nextThunder = now + math.Rand(THUNDER_INTERVAL[1], THUNDER_INTERVAL[2])
		end

		amount = a
		applyTheme(a, now < flashUntil)
	elseif flashUntil > 0 and now >= flashUntil then
		flashUntil = 0
		applyTheme(a, false)
	end

	tod.rain.amount = a
	if a <= 0 then
		stopRumble()
		return
	end

	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	if now >= nextCover then
		nextCover = now + 0.25
		covered = underCover()
		tod.rain.covered = covered
	end

	if not tod.rain_rumble then
		tod.rain_rumble = CreateSound(ply, RUMBLE)
		tod.rain_rumble:PlayEx(0, 100)
	end

	tod.rain_rumble:ChangeVolume(a * (covered and COVER_VOLUME or 1), 0.5)

	if covered and now >= nextDrip then
		nextDrip = now + math.Rand(DRIP_INTERVAL[1], DRIP_INTERVAL[2]) / a
		sound.Play("ambient/weather/rain_drip" .. math.random(5) .. ".wav", ply:GetPos() + VectorRand() * 200, 65, math.random(90, 110), 0.6)
	end

	if a >= THUNDER_AMOUNT and now >= nextThunder then
		nextThunder = now + math.Rand(THUNDER_INTERVAL[1], THUNDER_INTERVAL[2])
		flashUntil = now + FLASH_TIME
		applyTheme(a, true)
		timer.Simple(math.Rand(0.8, 3), function()
			if amount > 0 and IsValid(ply) then
				ply:EmitSound("ambient/weather/thunder" .. math.random(6) .. ".wav", 0, math.random(90, 110), 0.7, CHAN_STATIC)
			end
		end)
	end
end)

local function removeIt()
	hook.Remove("Think", "tod_rain")
	stopRumble()
	tod.RemoveOverrideConfig("rain")
	tod.SetOverrideConfig()
	tod.SetConfigCycle(unpack(tod.config_cycle)) -- drops the cached lerps that still hold the override
	if amount > 0 then
		amount = 0
		applyTheme(0)
	end

	concommand.Remove("tod_removerain")
end

concommand.Add("tod_removerain", removeIt, nil, "Removes the rain, in case you don't like it.")
