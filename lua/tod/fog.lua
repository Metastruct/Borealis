-- Fog weather, year round, on tod's weather schedule.  It registers no
-- override config: tod holds one override slot and the weather loop clears it
-- whenever any weather ends, so a second config would fight rain's.  The
-- client only tracks the amount, the volumetric fog (sh_fog) reads it.
local PROBABILITY = 0.15

if not CLIENT then return end

tod.fog = tod.fog or { amount = 0 }

hook.Add("Think", "tod_fog", function()
	tod.fog.amount = tod.GetWeather("fog", PROBABILITY)
end)
