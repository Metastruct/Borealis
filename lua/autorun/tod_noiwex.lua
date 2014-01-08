do return end
--local gm = istable(GM) and GM or GAMEMODE
--print(gm.FolderName)

AddCSLuaFile()
module("tod", package.seeall)

CreateConVar("sv_tod", -1, bit.bor(FCVAR_REPLICATED, FCVAR_NOTIFY), "Sets fixed time of day")

DayLength = 24 * 60 -- in real seconds
Sunrise = 6/24
Sunset = 22/24

local offset = DayLength / 2 -- therefore, the gameday starts at 12:00

function GameTime()
	return GetConVarNumber("sv_tod") >= 0 and (GetConVarNumber("sv_tod")%24)/24 or  ((offset + CurTime())%DayLength)/DayLength
end

function HumanTime()
	return math.floor(GameTime()*1440/60%24), math.floor(GameTime()*1440%60)
end

function IsDay()
	return GameTime() >= Sunrise and GameTime() < Sunset
end

function IsNight()
	return not IsDay()
end

local last = IsDay()
hook.Add("Think", "DayNightHooks", function()
	if last != IsDay() then
		hook.Call("DayCycle", nil, IsDay())
		hook.Call(IsDay() and "Day" or "Night",nil)
		last = IsDay()
	end
end)

WEATHER_SUNNY = 1

local config = {
	[WEATHER_SUNNY] = { -- sky color grabbed from gta: san andreas (timecyc.dat)
		[0] = {
			TopColor = Vector(5/255, 12/255, 15/255),
			BottomColor = Vector(12/255, 14/255, 13/255),
			FadeBias = 0.5,
			HDRScale = 0.66,
			SunNormal = Vector(0, 0, 0),
			SunColor = color_white,
			SunSize = 0.1,
			DuskColor = Vector(0, 0, 0),
			DuskScale = 0,
			DuskIntensity = 0,

			EnvLight = 0,
		},

		[5] = {
			TopColor = Vector(0/255, 0/255, 7/255),
			BottomColor = Vector(19/255, 39/255, 37/255),
			FadeBias = 0.2,
			HDRScale = 0.66,
			SunNormal = Vector(0, 0, 0),
			SunColor = color_white,
			SunSize = 0.1,
			DuskColor = Vector(0, 0, 0),
			DuskScale = 0,
			DuskIntensity = 0,

			EnvLight = 0,
		},

		[6] = {
			TopColor = Vector(90/255, 205/255, 255/255),
			BottomColor = Vector(200/255, 144/255, 85/255),
			FadeBias = 0.66,
			HDRScale = 0.66,
			SunNormal = Vector(0, 0, 0),
			SunColor = color_white,
			SunSize = 0.1,
			DuskColor = Vector(0, 0, 0),
			DuskScale = 0,
			DuskIntensity = 0,

			EnvLight = 0.4
		},

		[7] = {
			TopColor = Vector(90/255, 205/255, 255/255),
			BottomColor = Vector(90/255, 205/255, 255/255),
			FadeBias = 0.66,
			HDRScale = 0.66,
			SunNormal = Vector(0, 0, 0),
			SunColor = color_white,
			SunSize = 0.1,
			DuskColor = Vector(0, 0, 0),
			DuskScale = 0,
			DuskIntensity = 0,

			EnvLight = 0.45,
		},

		[12] = {
			TopColor = Vector(68/255, 112/255, 210/255),
			BottomColor = Vector(36/255, 117/255, 199/255),
			FadeBias = 0.5,
			HDRScale = 0.66,
			SunNormal = Vector(0, 0, 0),
			SunColor = color_white,
			SunSize = 0.1,
			DuskColor = Vector(0, 0, 0),
			DuskScale = 0,
			DuskIntensity = 0,

			EnvLight = 0.5,
		},

		[19] = {
			TopColor = Vector(68/255, 112/255, 210/255),
			BottomColor = Vector(36/255, 117/255, 194/255),
			FadeBias = 0.5,
			HDRScale = 0.66,
			SunNormal = Vector(0, 0, 0),
			SunColor = color_white,
			SunSize = 0.1,
			DuskColor = Vector(0, 0, 0),
			DuskScale = 0,
			DuskIntensity = 0,

			EnvLight = 0.45,
		},

		[20] = {
			TopColor = Vector(181/255, 150/255, 84/255),
			BottomColor = Vector(167/255, 108/255, 65/255),
			FadeBias = 0.5,
			HDRScale = 0.66,
			SunNormal = Vector(0, 0, 0),
			SunColor = color_white,
			SunSize = 0.1,
			DuskColor = Vector(0, 0, 0),
			DuskScale = 0,
			DuskIntensity = 0,

			EnvLight = 0.3
		},

		[22] = {
			TopColor = Vector(137/255, 100/255, 84/255),
			BottomColor = Vector(60/255, 50/255, 52/255),
			FadeBias = 0.5,
			HDRScale = 0.66,
			SunNormal = Vector(0, 0, 0),
			SunColor = color_white,
			SunSize = 0.1,
			DuskColor = Vector(0, 0, 0),
			DuskScale = 0,
			DuskIntensity = 0,

			EnvLight = 0.2,
		},


	}
}

local function NextHour(tab, cur) -- returns next available hour data in table after current one
	local h = 0

	if cur >= table.maxn(tab) then
		cur = 0
	end
	
	for k, v in SortedPairs(tab) do
		if cur <= k then
			return k
		end
	end
end

local function PreviousHour(tab, cur) -- returns previous available hour data in table before current one
	local h = 0

	for k, v in SortedPairs(tab) do
		if cur >= k then
			h = k
		end
	end

	return h
end

local function ReverseLerp(val, from, to)
	if (to-from) == 0 then return 0 end

	--if from > to then return 1-(24-val)/(24-from) end
	if from > to then return 1-(24-to-val)/(24-to-from) end

	return math.abs((val-from)/(to-from))
end

if CLIENT then

	/*
		Sky render
	*/
	timer.Simple(.1, function()

	matproxy.Add {
		name = "SkyPaint",

		init = function( self, mat, values )
		end,

		bind = function( self, mat, ent )

			local hour = GameTime()*1440/60%24
			local Past = PreviousHour(config[WEATHER_SUNNY], hour)
			local Next = NextHour(config[WEATHER_SUNNY], hour)

			for k, v in pairs( config[WEATHER_SUNNY][Past] ) do
				
				if isvector(v) then
					mat:SetVector("$" .. k:upper(), LerpVector( ReverseLerp(hour, Past, Next), v, config[WEATHER_SUNNY][Next][k]))
				elseif isnumber(v) then
					mat:SetFloat("$" .. k:upper(), Lerp( ReverseLerp(hour, Past, Next), v, config[WEATHER_SUNNY][Next][k]))
				end

			end

			mat:SetInt("$STARLAYERS", 2)
			if Lerp(ReverseLerp(hour, Past, Next), config[WEATHER_SUNNY][Past]["EnvLight"], config[WEATHER_SUNNY][Next]["EnvLight"]) > 0.1 then
				mat:SetTexture( "$STARTEXTURE", "skybox/clouds")
				mat:SetFloat("$STARSCALE", 1)
				mat:SetFloat( "$STARFADE", 1)
				mat:SetFloat( "$STARPOS", CurTime() * .02 )
			else
				mat:SetTexture( "$STARTEXTURE", "skybox/starfield")
				mat:SetFloat("$STARSCALE", 2)
				mat:SetFloat( "$STARFADE", 1)
				mat:SetFloat( "$STARPOS", CurTime() * .01 )
			end

		end,

	}

	end)

	if game.GetMap():find("^rp_downtown_evilmelon_nx") then
		RunConsoleCommand("mat_bloomscale", 0)
	end

else

	hidden_ents = {}

	hook.Add("EntityKeyValue", "tod", function(ent, k, v)
		local class = ent:GetClass():lower()
		if class == "light_environment" then
			ent:SetKeyValue("targetname", class)
			hidden_ents[class] = ent
		end
	end)

	RunConsoleCommand("sv_skyname", "painted")

	local last_n
	function SetEnvLight(n)
		local n = math.Round(math.Clamp(97 + n * 30, 97, 127))
		local ent = ents.FindByClass"light_environment"[1]

		if IsValid(ent) then
			ent:Fire("FadeToPattern", string.char(n))
		elseif hidden_ents.light_environment then
			engine.LightStyle(0, string.char(math.max(98, n)))
			--hidden_ents.light_environment:Fire("SetPattern", string.char(n))

			if last_n ~= n then
				BroadcastLua("render.RedownloadAllLightmaps()")
				last_n = n
			end
		end
	end

	timer.Create("UpdateLight", .1, 0, function()
		local hour = GameTime()*1440/60%24
		local Past = PreviousHour(config[WEATHER_SUNNY], hour)
		local Next = NextHour(config[WEATHER_SUNNY], hour)

		SetEnvLight(Lerp(ReverseLerp(hour, Past, Next), config[WEATHER_SUNNY][Past]["EnvLight"], config[WEATHER_SUNNY][Next]["EnvLight"]))
	end)

end