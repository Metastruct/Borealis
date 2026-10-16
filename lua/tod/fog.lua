local PROBABILITY = 0.10

tod.AddFogConfig("fog", {
	["fog_start"] = 0,
	["fog_end"] = 5000,
	["fog_max_density"] = 0.6,
	["fog_color"] = Vector(190, 195, 200),
}, PROBABILITY)

if not CLIENT then return end

tod.fog = tod.fog or { amount = 0 }

hook.Add("Think", "tod_fog", function()
	tod.fog.amount = tod.GetWeather("fog")
end)
