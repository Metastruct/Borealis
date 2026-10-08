local config =
{
	["fog_start"] = 0,
	["fog_end"] = 7000,
	["fog_max_density"] = 0.25,
	["fog_color"] = Vector(255,255,255) * 0.8,
	["star_intensity"] = 0,
	["sky_topcolor"] = Vector(1,1,1) * 0.5,
	["sky_bottomcolor"] = Vector(1,1,1) * 0.5,
	["sky_starfade"] = 0,
	["sky_duskintensity"] = 0,
	["light_scale"] = 0.8,
}

tod.AddOverrideConfig("snow", config, 0.2)

if CLIENT then
	local lastOvercast

	tod.snow = tod.snow or { amount = 0 }

	hook.Add("Think", "tod_snow", function()
		time = RealTime()
		tod.snow.amount = tod.GetWeather("snow")

		-- procsky"s grey sky follows the override as it fades in and out
		local snow = tod.override_configs.snow
		local overcast = snow and snow.lerp or 0
		if procsky and procsky.SetTheme and overcast ~= lastOvercast then
			lastOvercast = overcast
			procsky.SetTheme(overcast > 0 and { overcast = overcast } or nil)
		end
	end)

	hook.Add("TOD_ReplaceGrassTexture", "tod_snow", function(path)
		path = path:lower()
		if
			(
				path:find("grass") or
				path:find("mud") or
				path:find("sand")
			) and not
			(
				path:find("water") or
				path:find("gm_flatgrass")
			)
			then
			tod.ReplaceTexture(path, "nature/snowfloor002a")
			tod.SetTextureColor(path, Vector(1,1,1) * 0.2)
		end
	end)

	hook.Add("PlayerFootstep", "snow", function(ply, pos, foot, sound, volume, rf)
		sound = sound:lower()
		if sound:find("grass", nil, true) or sound:find("dirt", nil, true) then
			ply:EmitSound(("player/footsteps/snow%s.wav"):format(math.random(6)), 60, math.random(95,105))
			return true
		end
	end)

	local function removeIt()
		hook.Remove("PlayerFootstep","snow")
		hook.Remove("TOD_ReplaceGrassTexture","tod_snow") -- is this even needed?
		hook.Remove("Think","tod_snow")
		tod.snow = nil
		tod.RestoreAllTextures() -- maybe just replace the ones that were changed?
		tod.RemoveOverrideConfig("snow")
		tod.SetOverrideConfig()
		tod.SetConfigCycle(unpack(tod.config_cycle)) -- drops the cached lerps that still hold the override
		if procsky and procsky.SetTheme then procsky.SetTheme() end
		hook.Run("TOD_WinterRemoved") -- the grass drops its winter palette
		concommand.Remove("tod_removesnow") -- this really only needs to get ran once so we"ll remove the command
	end


	concommand.Add("tod_removesnow",removeIt,nil,"Removes the winter modifications from the server, just in case you don't like them.")
end