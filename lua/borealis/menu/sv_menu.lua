local TAG = "borealis_menu"

util.AddNetworkString(TAG)

shaderpack.AddResources({ "borealis_menu_ps30" })
resource.AddFile("resource/fonts/ninecircles.ttf")
resource.AddFile("resource/fonts/audiowide.ttf")
resource.AddFile("resource/fonts/vt323.ttf")
resource.AddFile("materials/shaderpack/menu/icon64.png")
resource.AddFile("materials/shaderpack/menu/metastruct.png")
resource.AddFile("materials/shaderpack/menu/facepunch.png")

local SEASONS = { [""] = true, summer = true, autumn = true, winter = true }

local ACTIONS = {
	time = function(arg, reason)
		local hour = tonumber(arg)
		if hour then
			if hour < 0 or hour > 24 then return end
		elseif arg ~= "realtime" and arg ~= "demo" then
			return
		end

		tod.SetTime(arg, reason)
	end,
	weather = function(arg, reason)
		tod.ForceWeather(arg, reason)
	end,
	season = function(arg)
		if SEASONS[arg] then tod.ForceSeason(arg) end
	end,
}

net.Receive(TAG, function(_, ply)
	if not IsValid(ply) or not ply:IsAdmin() or not tod then return end

	local action = ACTIONS[net.ReadString()]
	if not action then return end

	action(net.ReadString(), string.format("borealis menu by %s (%s)", ply:Nick(), ply:SteamID()))
end)
