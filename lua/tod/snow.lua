local config =
{
	["fog_start"] = 0,
	["fog_end"] = 7000,
	["fog_max_density"] = 0.7,
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
	local DEFAULT_TINT = Vector(0.31, 0.35, 0.46)
	local snowPaths = {}
	local snowTint = DEFAULT_TINT

	tod.snow = tod.snow or { amount = 0 }

	function tod.snow.SetTint(tint)
		snowTint = tint or DEFAULT_TINT
		for _, path in ipairs(snowPaths) do
			tod.SetTextureColor(path, snowTint)
		end
	end

	hook.Add("Think", "tod_snow", function()
		time = RealTime()
		tod.snow.amount = tod.GetWeather("snow")

		-- procsky"s grey sky follows the override as it fades in and out
		local snow = tod.override_configs.snow
		local overcast = snow and snow.lerp or 0
		local procsky = shaderpack and shaderpack.procsky
		if procsky and procsky.SetTheme and overcast ~= lastOvercast then
			lastOvercast = overcast
			procsky.SetTheme(overcast > 0 and { overcast = overcast } or nil)
		end
	end)

	local function isGround(path)
		return
			(
				path:find("grass") or
				path:find("mud") or
				path:find("sand")
			) and not
			(
				path:find("water") or
				path:find("gm_flatgrass")
			)
	end

	hook.Add("TOD_ReplaceGrassTexture", "tod_snow", function(path)
		path = path:lower()
		if isGround(path) then
			local mat = tod.ReplaceTexture(path, "nature/snowfloor002a")
			local second = mat and mat:GetTexture("$basetexture2")
			if second and not second:IsError() and isGround(second:GetName():lower()) then
				tod.ReplaceTexture(path, "nature/snowfloor002a", "$basetexture2")
			end

			snowPaths[#snowPaths + 1] = path
			tod.SetTextureColor(path, snowTint)
			tod.SetDetailBlend(path, 0)
		end
	end)

	hook.Add("PlayerFootstep", "snow", function(ply, pos, foot, sound, volume, rf)
		sound = sound:lower()
		if sound:find("grass", nil, true) or sound:find("dirt", nil, true) then
			ply:EmitSound(("player/footsteps/snow%s.wav"):format(math.random(6)), 60, math.random(95,105))
			return true
		end
	end)
end