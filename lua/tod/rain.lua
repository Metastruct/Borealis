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
if SERVER then resource.AddFile("sound/tod/rain_loop.wav") end

if not CLIENT then return end

local DECK_BRIGHTNESS = 0.6 -- the deck sits darker than snow's stratus
local FOG_SCALE = 0.75

-- ambient/weather/rumble_rain.wav is 2.43 seconds long and comes round often
-- enough to recognise; this one is ten and joins to itself. The stock file
-- stands in if the bake has not reached the client.
local RUMBLE = file.Exists("sound/tod/rain_loop.wav", "GAME") and "tod/rain_loop.wav" or "ambient/weather/rumble_rain.wav"
local COVER_VOLUME = 0.3 -- rumble share heard under a roof
local SKY_RANGE = 8192 -- the look straight up for open sky
local WAY_OUT = 1400 -- how far to either side to look for a way out from under a roof
local WAY_NEAR = 300 -- a way out this close is as loud as standing in it
local WAY_STEPS = {
	0.45, -- how far along a clear probe to look up from, nearest first
	0.95
}

local WAY_FAN = 8 -- probes per look, spun a little each time so a doorway is not missed forever
local WAY_SPIN = math.rad(17)
local WAY_WINDOW = 12 -- looks kept, the best of them being what is heard
local DRIP_INTERVAL = {0.6, 1.8}
local THUNDER_AMOUNT = 0.8 -- heavy rain only
local THUNDER_INTERVAL = {25, 70}
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

local VOLUME = CreateClientConVar("cl_rain_volume", "0.4", true, false, "rain volume: the rumble, the drips under cover and the thunder, 0 to 1")
local MUTE_LOSEFOCUS = CreateClientConVar("cl_rain_mute_losefocus", "1", true, false, "mute the rain while the game is unfocused")
tod.rain = tod.rain or {
	amount = 0, -- read by sh_precipitations for the streaks
	covered = false
}

local amount = 0 -- last amount pushed into the theme
local rumbleOwner -- the entity the patch was made on, replaced on a map change
local saved -- the season's own fogScale and tint while rain overrides them
local flashUntil = 0
local covered = false
local exposure = 0 -- how much of the rain is in earshot, 0 under enough rock
local nextCover, nextDrip, nextThunder = 0, 0, 0
local UP = Vector(0, 0, 1)
local wayPhase = 0
local wayLog, wayAt = {}, 1
for i = 1, WAY_WINDOW do
	wayLog[i] = 0
end

-- a reload must not leave the old rumble playing
if tod.rain_rumble then
	tod.rain_rumble:Stop()
	tod.rain_rumble = nil
end

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

local coverTrace = {
	mask = bit.bor(CONTENTS_SOLID, CONTENTS_MOVEABLE, CONTENTS_WINDOW, CONTENTS_GRATE) -- props count as cover, players do not
}

-- How near the rain is, and whether anything stands over the head.  A slanted
-- ray is no use here: a roof a hundred units up stops every one of them within
-- a hundred more, whatever is past it.  So the probes run flat, out to where
-- each one is stopped, and look up from along the way: a porch or a doorway
-- finds sky a few hundred units out and keeps its rumble, while a sealed room
-- or anywhere far underground finds none and falls silent.
local function skyReach()
	local eye = EyePos()
	coverTrace.start = eye
	coverTrace.endpos = eye + UP * SKY_RANGE

	local up = util.TraceLine(coverTrace)
	if not up.Hit or up.HitSky then return 1, true end

	local near = WAY_OUT
	wayPhase = wayPhase + WAY_SPIN
	for i = 0, WAY_FAN - 1 do
		local a = wayPhase + i * math.pi * 2 / WAY_FAN
		local dir = Vector(math.cos(a), math.sin(a), 0)
		coverTrace.start = eye
		coverTrace.endpos = eye + dir * WAY_OUT
		local out = util.TraceLine(coverTrace)
		local clear = out.Fraction * WAY_OUT - 8 -- short of whatever stopped it
		for _, k in ipairs(WAY_STEPS) do
			local d = clear * k
			if d <= 0 or d >= near then break end
			coverTrace.start = eye + dir * d
			coverTrace.endpos = coverTrace.start + UP * SKY_RANGE
			local u = util.TraceLine(coverTrace)
			if not u.Hit or u.HitSky then
				near = d
				break
			end
		end
	end
	return 1 - math.Clamp((near - WAY_NEAR) / (WAY_OUT - WAY_NEAR), 0, 1), false
end

local function stopRumble(fade)
	if not tod.rain_rumble then return end
	if fade then
		tod.rain_rumble:FadeOut(fade)
	else
		tod.rain_rumble:Stop()
	end

	tod.rain_rumble = nil
end

-- the engine drops the patch on its own, on a focus loss, a soundscape or a
-- stopsound, and hands the dead one back, so the loop is picked up from
-- IsPlaying rather than from the reference still being there
local function updateRumble(ply, volume)
	local s = tod.rain_rumble
	if s and (rumbleOwner ~= ply or not s:IsPlaying()) then
		s:Stop()
		s, tod.rain_rumble = nil, nil
	end

	if not s then
		rumbleOwner = ply
		s = CreateSound(ply, RUMBLE)
		tod.rain_rumble = s
		s:PlayEx(0, 100)
	end

	s:ChangeVolume(volume, 0.5)
end

hook.Add("Think", "tod_rain", function()
	local a = tod.GetWeather("rain")
	local now = RealTime()
	if a ~= amount then
		if amount == 0 then nextThunder = now + math.Rand(THUNDER_INTERVAL[1], THUNDER_INTERVAL[2]) end
		amount = a
		applyTheme(a, now < flashUntil)
	elseif flashUntil > 0 and now >= flashUntil then
		flashUntil = 0
		applyTheme(a, false)
	end

	tod.rain.amount = a
	if a <= 0 then
		stopRumble(2)
		return
	end

	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	if ply.IsDreaming and ply:IsDreaming() then
		stopRumble()
		return
	end

	if now >= nextCover then
		nextCover = now + 0.25
		local target, sky = skyReach()
		covered = not sky
		tod.rain.covered = covered
		-- a narrow way out slips between the probes for a second or two at a time
		-- even while standing still, so the best of the last few looks is what
		-- holds: reading each one on its own pumps the volume up and down
		wayLog[wayAt] = target
		wayAt = wayAt % WAY_WINDOW + 1
		exposure = 0
		for i = 1, WAY_WINDOW do
			exposure = math.max(exposure, wayLog[i])
		end
	end

	-- nothing is heard while another window has the focus, unless asked otherwise
	local vol = math.Clamp(VOLUME:GetFloat(), 0, 1)
	if vol <= 0 or (MUTE_LOSEFOCUS:GetBool() and not system.HasFocus()) then
		stopRumble()
		return
	end

	-- none of it is within earshot: no rumble to fade, no drips, no thunder
	if exposure <= 0 then
		stopRumble(1.5)
		return
	end

	updateRumble(ply, a * vol * (covered and COVER_VOLUME or 1) * exposure)
	if covered and now >= nextDrip then
		nextDrip = now + math.Rand(DRIP_INTERVAL[1], DRIP_INTERVAL[2]) / a
		sound.Play("ambient/weather/rain_drip" .. math.random(5) .. ".wav", ply:GetPos() + VectorRand() * 200, 65, math.random(90, 110), 0.6 * vol)
	end

	if a >= THUNDER_AMOUNT and now >= nextThunder then
		nextThunder = now + math.Rand(THUNDER_INTERVAL[1], THUNDER_INTERVAL[2])
		flashUntil = now + FLASH_TIME
		applyTheme(a, true)
		timer.Simple(math.Rand(0.8, 3), function()
			-- read again: the volume can have moved in the seconds since the flash
			local v = math.Clamp(VOLUME:GetFloat(), 0, 1)
			if amount > 0 and v > 0 and IsValid(ply) and (not MUTE_LOSEFOCUS:GetBool() or system.HasFocus()) then ply:EmitSound("ambient/weather/thunder" .. math.random(6) .. ".wav", 0, math.random(90, 110), 0.7 * v * exposure, CHAN_STATIC) end
		end)
	end
end)

local function removeIt()
	hook.Remove("Think", "tod_rain")
	stopRumble(2)
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