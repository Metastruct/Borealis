tod = {}
local tod = tod
include("tod/bsp.lua")

tod.Params = {}
tod.CurrentParams = {}
tod.light_environment_named = false

if CLIENT then
	for i = 1, 4096 do
		local v = util.NetworkIDToString(i)
		if v == nil then break end

		if v == "tod_le" then
			tod.light_environment_named = true
			break
		end
	end
end

local P = tod.Params
local C = tod.CurrentParams

-- sky paint
local function GetSky()
	local ent = ents.FindByClass("env_skypaint")[1] or NULL

	if not ent:IsValid() then
		ent = ents.Create("env_skypaint")
		ent:Spawn()
		ent:Activate()
		ent:SetKeyValue("sunposmethod", "0")
		ent:SetKeyValue("drawstars", "1")
		ent:SetKeyValue("startexture", "skybox/starfield")
		RunConsoleCommand("sv_skyname", "painted")
	end

	return ent
end

local function ADD_SKY_KEYVALUE(name, default, mult_by_world_light)
	if CLIENT then
		P["sky_" .. name] = default
	end

	if SERVER then
		local type = type(default)

		if type == "Vector" then
			P["sky_" .. name] = function(val, cfg)
				if mult_by_world_light then
					val = val * (cfg.world_light_multiplier or 1)
				end

				GetSky():SetKeyValue(name, val.x .. " " .. val.y .. " " .. val.z)
			end
		elseif type == "number" then
			P["sky_" .. name] = function(val)
				GetSky():SetKeyValue(name, val)
			end
		end
	end
end

local min = 98

function tod.MultToLightEnv(mult)
	return math.Clamp(math.Round(min + (127 - min) * mult), min, 127)
end

ADD_SKY_KEYVALUE("topcolor", Vector(0.2, 0.5, 1), true)
ADD_SKY_KEYVALUE("bottomcolor", Vector(0.8, 1, 1), true)
ADD_SKY_KEYVALUE("fadebias", 1)
ADD_SKY_KEYVALUE("sunsize", 2)
ADD_SKY_KEYVALUE("suncolor", Vector(0.2, 0.1, 0))
ADD_SKY_KEYVALUE("duskscale", 1)
ADD_SKY_KEYVALUE("duskintensity", 1)
ADD_SKY_KEYVALUE("duskcolor", Vector(1, 0.2, 0))
ADD_SKY_KEYVALUE("starscale", 0.2)
ADD_SKY_KEYVALUE("starfade", 1)
ADD_SKY_KEYVALUE("starspeed", 0.01)
ADD_SKY_KEYVALUE("hdrscale", 0.66)
RunConsoleCommand("sv_skyname", "painted")

if SERVER then
	hook.Add("InitPostEntity", "tod", function()
		GetSky()
	end)
end

if CLIENT then
	P.grade_exposure = 0
	P.grade_contrast = 1
	P.grade_saturation = 1
	P.grade_white = Vector(1, 1, 1)
	P.grade_shadows = Vector(1, 1, 1)
	P.grade_highlights = Vector(1, 1, 1)
	P.star_intensity = 0
	P.moon_size = 1
	P.moon_angles = Angle(0, 0, 0)
	P.fog_color = Vector(255, 255, 255)
	P.fog_start = 0
	P.fog_end = 32000
	P.fog_max_density = 1
	P.sun_angles = Angle(0, 0, 0)
	P.shadow_color = Vector(0, 0, 0)
	P.shadow_angles = Angle(0, 0, 0)
	P.world_light_multiplier = 0.5
end

if SERVER then
	P.sun_angles = function(val)
		local ent = ents.FindByClass("env_sun")[1] or NULL
		local n = -val:Forward()
		GetSky():SetKeyValue("sunnormal", n.x .. " " .. n.y .. " " .. n.z)

		do
			local ent = ents.FindByClass("shadow_control")[1] or NULL

			if ent:IsValid() then
				local p = val.p
				p = math.Clamp(p, 50, 130)
				ent:Fire("SetAngles", math.Round(p) .. " " .. math.Round(val.y) .. " " .. math.Round(val.r))
				local fade = (val.p / 180)
				ent:Fire("SetDistance", fade * 70)

				if fade > 0 then
					ent:Fire("SetShadowsDisabled", "0")
				else
					ent:Fire("SetShadowsDisabled", "1")
				end
			end
		end

		if ent:IsValid() then
			timer.Create("tod_sun_angles_hack", 0, 2, function()
				ent:SetAngles(val)
				ent:Fire("addoutput", "pitch " .. -val.p)
				ent:Activate()
				-- we KILL 🔪 the sun when its below horizon so it doesnt leak through skyboxes and whatnot
				ent:Fire(n.z > 0 and "TurnOn" or "TurnOff")
			end)
		end
	end

	P.shadow_color = function(val)
		local ent = ents.FindByClass("shadow_control")[1] or NULL

		if ent:IsValid() then
			ent:Fire("color", math.Round(val.x) .. " " .. math.Round(val.y) .. " " .. math.Round(val.z))
		end
	end

	P.world_light_multiplier = function(val)
		local ent = ents.FindByClass("light_environment")[1] or NULL

		if ent:IsValid() then
			ent:Fire("SetPattern", string.char(tod.MultToLightEnv(val)))
		else
			engine.LightStyle(0, string.char(tod.MultToLightEnv(val)))
		end
	end
end

if CLIENT then
	-- texture replacer
	do
		tod.replaced_textures = {}

		function tod.ReplaceTexture(path, to, key)
			path = path:lower()
			key = key or "$basetexture"
			local mat = Material(path)

			if mat and not mat:IsError() then
				local typ = type(to)
				local tex

				if typ == "string" then
					tex = Material(to):GetTexture("$basetexture")
				elseif typ == "ITexture" then
					tex = to
				elseif typ == "Material" then
					tex = to:GetTexture("$basetexture")
				else
					return false
				end

				local tbl = tod.replaced_textures[path] or { OldTextures = {} }
				tod.replaced_textures[path] = tbl
				tbl.OldTextures = tbl.OldTextures or {}
				tbl.OldTextures[key] = tbl.OldTextures[key] or mat:GetTexture(key)
				mat:SetTexture(key, tex)

				return mat
			end

			return false
		end

		function tod.SetTextureColor(path, color)
			path = path:lower()
			local mat = Material(path)

			if not mat:IsError() then
				tod.replaced_textures[path] = tod.replaced_textures[path] or {}
				tod.replaced_textures[path].OldColor = tod.replaced_textures[path].OldColor or mat:GetVector("$color2")
				tod.replaced_textures[path].NewColor = color
				mat:SetVector("$color2", color)

				return true
			end

			return false
		end

		function tod.SetDetailBlend(path, factor)
			path = path:lower()
			local mat = Material(path)

			if not mat:IsError() and mat:GetTexture("$detail") then
				tod.replaced_textures[path] = tod.replaced_textures[path] or {}
				tod.replaced_textures[path].OldDetailBlend = tod.replaced_textures[path].OldDetailBlend or mat:GetFloat("$detailblendfactor") or 1
				mat:SetFloat("$detailblendfactor", factor)

				return true
			end

			return false
		end

		function tod.RestoreAllTextures()
			for name, tbl in pairs(tod.replaced_textures) do
				if not pcall(function()
					for key, tex in pairs(tbl.OldTextures or {}) do
						tod.ReplaceTexture(name, tex, key)
					end

					if tbl.OldColor then
						tod.SetTextureColor(name, tbl.OldColor)
					end

					if tbl.OldDetailBlend then
						tod.SetDetailBlend(name, tbl.OldDetailBlend)
					end
				end) then
					print("Failed to restore: " .. tostring(name))
				end
			end
		end

		hook.Add("ShutDown", "tod_texture_restore", tod.RestoreAllTextures)
	end

	-- texture collector
	do
		local map_data = tod.OpenBSP()
		local found = map_data:ReadLumpTextDataStringData()

		for k, v in pairs(found) do
			if v:find("water/") then
				found[k] = nil
			end
		end

		function tod.GetMapTextures()
			return found
		end

		hook.Add("Think", "tod_replacetextures", function()
			if not LocalPlayer():IsValid() then return end

			for _, tex in pairs(tod.GetMapTextures()) do
				hook.Run("TOD_ReplaceGrassTexture", tex)
			end

			hook.Remove("Think", "tod_replacetextures")
		end)
	end

	local last_byte

	hook.Add("RenderScene", "todhack", function()
		hook.Remove("RenderScene", "todhack")

		timer.Create("tod_update_lightmap", 0.5, 0, function()
			local byte = tod.MultToLightEnv(C.world_light_multiplier)

			if last_byte ~= byte then
				-- this function is very slow
				if not tod.light_environment_named then
					render.RedownloadAllLightmaps()
				end

				last_byte = byte
			end
		end)
	end)

	-- stars	and moon
	do
		tod.moon_ent = NULL

		do
			local earth = Material("models/props_wasteland/rockcliff02c")
			local atmosphere = Material("models/props/de_tides/clouds")
			--local atmosphere_outter = Material("models/debug/debugwhite")
			local render = render

			local render_SetColorModulation = render.SetColorModulation
			local render_SetBlend = render.SetBlend
			local render_MaterialOverride = render.MaterialOverride
			local math_Rand = math.Rand

			function tod.MoonRender(self)
				local normal_scale = C.moon_size * 40
				local fraction = 1
				local ply = LocalPlayer()

				if ply:GetAimVector():DotProduct((self:GetPos() - ply:EyePos()):GetNormalized()) > 0.999 then
					fraction = ply:GetFOV() / 5
					fraction = fraction ^ 20
				end

				--render.SuppressEngineLighting( true )
				--render.SetAmbientLight( 1, 1, 1)
				local rand = math_Rand(1, 100)
				render_SetColorModulation(rand, rand, rand)
				render_SetBlend(1)
				render_MaterialOverride(0)
				self:SetModelScale(normal_scale, 0)
				self:DrawModel()
				render_SetColorModulation(0.7, 0.8, 0.9)
				render_SetBlend(fraction)
				render_MaterialOverride(earth)
				self:SetModelScale(normal_scale, 0)
				self:DrawModel()
				render_SetColorModulation(1, 1, 1)
				render_SetBlend(0.5)
				render_MaterialOverride(atmosphere)
				self:SetModelScale(normal_scale, 0)
				self:DrawModel()
				render_SetColorModulation(3.5, 3.6, 3.9)
				render_SetBlend(fraction)
				render_MaterialOverride(atmosphere)
				self:SetModelScale(normal_scale * 1.1, 0)
				self:DrawModel()
				render_SetColorModulation(1, 1, 1)
				render_SetBlend(1)
				render_MaterialOverride(0)

				--render.SetAmbientLight( 1, 1, 1)
				--render.SuppressEngineLighting( false )
				if fraction < 0.2 then
					LocalPlayer():SetDSP(23)

					for i = 1, 4 do
						LocalPlayer():EmitSound("weapons/explode" .. math.random(3, 5) .. ".wav", 0, math.random(4))
					end

					timer.Create("tod_moon_sound", 0.25, 1, function()
						hook.Run("tod_moon_effect_end")
						LocalPlayer():SetDSP(0)
						LocalPlayer():ConCommand("stopsound")
					end)
				end
			end

			local gmancol = Color(170, 190, 255, 255)

			function tod.InitializeSky()
				local origin = vector_origin

				hook.Add("RenderScene", "tod_moon", function(pos, ang)
					origin = pos
					angles = ang
				end)

				local function PostDraw2DSkyBox()
					if tod.moon_ent:IsValid() then
						local pos = origin + C.moon_angles:Forward() * -8000
						tod.moon_ent:SetLocalPos(pos)
						tod.moon_ent:SetAngles((pos - origin):Angle() + Angle(-90, 0, 180))
						tod.MoonRender(tod.moon_ent)
					else
						timer.Simple(0.1, function()
							local ent = ents.CreateClientProp()
							if not ent:IsValid() then return end
							ent:SetModel("models/dav0r/hoverball.mdl")
							ent:SetMaterial("models/gman/gman_face_map3")
							ent:SetPos(origin)
							ent:SetColor(gmancol)
							ent:SetNoDraw(true)
							tod.moon_ent = ent
						end)
					end

					render.ClearDepth()
				end

				pcall(require, 'skyboxer')

				if skyboxer then
					-- moon is FAR, but skybox could even be farther
					skyboxer.AddHook("c_moon", PostDraw2DSkyBox)
				else
					hook.Add("PostDraw2DSkyBox", "tod_moon", PostDraw2DSkyBox)
				end
			end

			if LocalPlayer():IsValid() then
				tod.InitializeSky()
			end

			hook.Add("InitPostEntity", "tod_moon", function()
				tod.InitializeSky()
				hook.Remove("InitPostEntity", "tod_moon")
			end)
		end
	end

	local function SetupFog(scale)
		if C.STOP_STEALING_FOG_CONTROLS then return end
		scale = scale or 1
		render.FogMode(1)
		render.FogStart(C.fog_start * scale)
		render.FogEnd(C.fog_end * scale)
		render.FogColor(C.fog_color.r * C.world_light_multiplier, C.fog_color.g * C.world_light_multiplier, C.fog_color.b * C.world_light_multiplier)
		render.FogMaxDensity(C.fog_max_density)

		return true
	end

	hook.Add("SetupWorldFog", "tod", SetupFog)
	hook.Add("SetupSkyboxFog", "tod", SetupFog)

	-- do
	-- todo!
	-- have an inside and outside config
	--[[
local smooth_outside = 0

function tod.IsOutside()
	return smooth_outside > 0.5
end
local cache = {}
timer.Create("tod_outside", 0.2, 0, function()
	local outside = 0
	local ply = LocalPlayer()
	local a = ply:EyePos()
	a.x = math.Round(a.x/32)*32
	a.y = math.Round(a.y/32)*32
	a.z = math.Round(a.z/32)*32

	if cache[a.x..a.y..a.z] then
		outside = 1
	else
		local b = a + VectorRand() * 32000

		if util.TraceLine(
			{
				start = a,
				endpos = b,
				mask = MASK_OPAQUE,
			}
		).HitSky then
			outside = 4
			cache[a.x..a.y..a.z] = true
		end
	end

	smooth_outside = smooth_outside + ((outside - smooth_outside) * FrameTime() * 10)

	epoe.Print(tod.IsOutside())
end)
]]
end

-- keep hidden entities
-- light_environment won't update properly if the map didn't compile with it properly.
-- the light refreshes on full update (reconnecting for instance)
-- or when you spawn a light somewhere on the map it will update that sector of the map
-- so if you're using a realtime tod it shouldn't be that noticable
if SERVER then
	tod.hidden_entities = {}
	tod.is_hidden_entity = {}

	hook.Add("EntityKeyValue", "hidden_entities", function(ent, key, val)
		local T = ent:GetClass():lower()

		if T == "shadow_control" or T == "light_environment" or T == "sky_camera" or T == "env_sun" or T == "env_fog_controller" then
			if key == "targetname" then
				tod.is_hidden_entity[T] = false
			elseif tod.is_hidden_entity[T] == nil then
				tod.is_hidden_entity[T] = true
			end

			ent:SetKeyValue("targetname", T) -- UUHHH
			tod.hidden_entities[T] = ent
		end
	end)

	hook.Add("InitPostEntity", "tod_hack", function()
		if not tod.is_hidden_entity.light_environment then
			util.AddNetworkString("tod_le")
			tod.light_environment_named = true
		end
	end)
end

for key, val in pairs(tod.Params) do
	if type(val) ~= "function" then
		tod.CurrentParams[key] = val
	end
end

-- lerping
do
	function tod.Lerp(mult, a, b)
		local params = {}

		for key, val in pairs(a) do
			if type(val) == "number" then
				params[key] = Lerp(mult, val, b[key] or val)
			elseif type(val) == "Vector" then
				params[key] = LerpVector(mult, val, b[key] or val)
			elseif type(val) == "Angle" then
				params[key] = LerpAngle(mult, val, b[key] or val)
			end
		end

		return params
	end

	local function lerp(mult, tbl)
		local out = {}

		for i = 1, #tbl - 1 do
			out[i] = tod.Lerp(mult, tbl[i], tbl[i + 1])
		end

		if #out > 1 then
			return lerp(mult, out)
		else
			return out[1]
		end
	end

	function tod.LerpConfigs(mult, ...)
		return lerp(mult, {...})
	end
end

do
	local function tangent(h0, h1, h2, y0, y1, y2)
		local dl, dr = (y1 - y0) / (h1 - h0), (y2 - y1) / (h2 - h1)
		if dl * dr <= 0 then return 0 end
		local w1, w2 = 2 * (h2 - h1) + (h1 - h0), (h2 - h1) + 2 * (h1 - h0)

		return (w1 + w2) / (w1 / dl + w2 / dr)
	end

	local function cubic(s, h, y0, y1, y2, y3)
		local m1 = tangent(h[1], h[2], h[3], y0, y1, y2)
		local m2 = tangent(h[2], h[3], h[4], y1, y2, y3)
		local span = h[3] - h[2]
		local s2, s3 = s * s, s * s * s

		return (2 * s3 - 3 * s2 + 1) * y1 + (s3 - 2 * s2 + s) * span * m1 + (3 * s2 - 2 * s3) * y2 + (s3 - s2) * span * m2
	end

	local function key(keys, i)
		local n = #keys
		local wrap = math.floor((i - 1) / n)
		local k = keys[i - wrap * n]

		return k.hour + wrap * 24, k.config
	end

	function tod.SampleCycle(time, keys)
		keys = keys or tod.config_cycle
		local hour = (time % 1) * 24
		local at = 0

		for i, k in ipairs(keys) do
			if k.hour <= hour then at = i end
		end

		local h, c = {}, {}
		for i = 1, 4 do
			h[i], c[i] = key(keys, at + i - 2)
		end

		local s = (hour - h[2]) / (h[3] - h[2])
		local params = {}

		for name, val in pairs(c[2]) do
			local a, b, d = c[1][name] or val, c[3][name] or val, c[4][name] or val

			if type(val) == "number" then
				params[name] = cubic(s, h, a, val, b, d)
			elseif type(val) == "Vector" then
				params[name] = Vector(
					cubic(s, h, a.x, val.x, b.x, d.x),
					cubic(s, h, a.y, val.y, b.y, d.y),
					cubic(s, h, a.z, val.z, b.z, d.z)
				)
			elseif type(val) == "Angle" then
				params[name] = LerpAngle(s, val, b)
			end
		end

		return params
	end
end

-- The sun is put where the light level says it is, so the sky, shadows and env_sun agree:
-- elevation follows asin above SUN_LIGHT_HORIZON, and runs down to
-- -SUN_TWILIGHT degrees as the light goes to zero.
tod.SUN_LIGHT_HORIZON = 0.15
tod.SUN_TWILIGHT = 12

function tod.AlignSunToLight(cfg, time)
	local w = cfg.world_light_multiplier
	local first = tod.config_cycle and tod.config_cycle[1] and tod.config_cycle[1].config
	local yaw = first and isangle(first.sun_angles) and first.sun_angles.y or 45
	if not isnumber(w) then return cfg end

	local noon, brightest = 0.5, -math.huge
	for _, k in ipairs(tod.config_cycle or {}) do
		local m = k.config.world_light_multiplier
		if isnumber(m) and m > brightest then
			noon, brightest = k.hour / 24, m
		end
	end

	local h = tod.SUN_LIGHT_HORIZON
	local elev
	if w >= h then
		elev = math.deg(math.asin(math.min(1, (w - h) / (1 - h))))
	else
		elev = (w - h) / h * tod.SUN_TWILIGHT
	end

	-- rises at yaw + 180, over the zenith, sets at yaw (pitch 0 .. 180)
	cfg.sun_angles = Angle(time < noon and elev or 180 - elev, yaw, 0)
	-- the moon sits at the sun's antipode (negating the angle would mirror the yaw instead)
	cfg.moon_angles = Angle(-cfg.sun_angles.p, yaw + 180, 0)

	cfg.shadow_angles = cfg.sun_angles

	return cfg
end

tod.WEATHER_SLOT = 3600
tod.WEATHER_RAMP = 10 * 60

tod.weathers = tod.weathers or {}

function tod.AddWeather(name, probability)
	tod.weathers[name] = probability
end

local function slotRoll(slot)
	local x = bit.tobit(slot * 374761393 + 1)
	x = bit.bxor(x, bit.lshift(x, 13))
	x = bit.bxor(x, bit.rshift(x, 17))
	x = bit.bxor(x, bit.lshift(x, 5))

	return (x % 4294967296) / 4294967296
end

local function slotWeather(slot)
	local names = table.GetKeys(tod.weathers)
	table.sort(names)

	local roll, sum = slotRoll(slot), 0
	for _, name in ipairs(names) do
		sum = sum + tod.weathers[name]
		if roll < sum then return name end
	end
end

function tod.GetSlotWeather(slot)
	return slotWeather(slot) or "clear"
end

-- amount of a weather right now, 0..1
function tod.GetWeather(name)
	local force = tod.force_weather
	if force ~= nil then
		return force == name and 1 or 0
	end

	local now = os.time()
	local slot = math.floor(now / tod.WEATHER_SLOT)
	local on = slotWeather(slot) == name and 1 or 0
	local into = now - slot * tod.WEATHER_SLOT
	if into >= tod.WEATHER_RAMP then return on end

	local before = slotWeather(slot - 1) == name and 1 or 0

	-- in steps, so the config lerp is not recomputed every frame of the ramp
	return math.Round(before + (on - before) * into / tod.WEATHER_RAMP, 2)
end

function tod.GetCurrentWeather()
	local force = tod.force_weather
	if force ~= nil then
		return force or "clear"
	end

	return slotWeather(math.floor(os.time() / tod.WEATHER_SLOT)) or "clear"
end

function tod.SetParameter(key, val, cfg)
	if type(tod.Params[key]) == "function" then
		tod.Params[key](val, cfg or tod.CurrentParams)
	end

	tod.CurrentParams[key] = val
end

function tod.GetParameter(key)
	return tod.CurrentParams[key]
end

function tod.SetConfig(data)
	for key, val in pairs(data) do
		tod.SetParameter(key, val, data)
	end
end

function tod.GetMode()
	return tod.mode
end

function tod.GetCycle()
	if tod.mode == 2 then return (CurTime() / 20) % 1 end -- demo mode

	return tod.current_cycle or 0
end

-- Realtime runs on the server's clock.  os.date is local to each machine,
-- so clients in another timezone put the sun hours away from the engine's
-- (env_sun and the skypaint are set by the server).  The server's offset
-- from UTC travels with tod_setmode and os.time() is UTC everywhere.
tod.utc_offset = tod.utc_offset or 0

if SERVER then
	local checked = -math.huge

	-- rechecked every minute so a DST switch reaches the clients
	function tod.GetUTCOffset()
		local now = os.time()
		if now - checked < 60 then return tod.utc_offset end
		checked = now

		local utc = os.date("!*t", now)
		utc.isdst = os.date("*t", now).isdst
		local offset = os.difftime(now, os.time(utc))
		if offset ~= tod.utc_offset then
			tod.utc_offset = offset
			if tod.mode then
				tod.SetMode(tod.mode)
			end
		end

		return offset
	end
else
	function tod.GetUTCOffset()
		return tod.utc_offset
	end
end

-- fraction of the day on the server's clock
function tod.GetRealTime()
	return ((os.time() + tod.GetUTCOffset()) % 86400) / 86400
end

if CLIENT then
	net.Receive("tod_setcycle", function()
		tod.current_cycle = net.ReadFloat() / 1000
	end)

	net.Receive("tod_setmode", function()
		tod.mode = net.ReadInt(4)
		tod.utc_offset = net.ReadInt(32)
	end)
end

if SERVER then
	local MODE_NAMES = {[0] = "manual", [1] = "realtime", [2] = "demo"}

	local function formatCycle(cycle)
		if not cycle or cycle < 0 then return tostring(cycle) end
		local minutes = math.floor(cycle * 1440 + 0.5) % 1440

		return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
	end

	local function logChange(what, old, new, reason)
		if not reason then
			local info = debug.getinfo(3, "Sl")
			reason = info and info.short_src .. ":" .. info.currentline or "unknown caller"
		end

		local line = string.format("%s %s -> %s: %s", what, old, new, reason)
		if metalog then
			metalog.info("TOD", nil, line)
		else
			Msg("[TOD] ")
			print(line)
		end
	end

	util.AddNetworkString("tod_setcycle")

	function tod.SetCycle(time, reason)
		local old = tod.current_cycle
		tod.current_cycle = time and (time % 1) or -1

		if tod.current_cycle ~= old then
			logChange("cycle", formatCycle(old), formatCycle(tod.current_cycle), reason)
		end

		net.Start("tod_setcycle")
		net.WriteFloat(tod.current_cycle * 1000)
		net.Send(player.GetAll())
	end

	util.AddNetworkString("tod_setmode")

	function tod.SetMode(mode, filter, reason)
		local offset = tod.GetUTCOffset()
		if mode ~= tod.mode then
			logChange("mode", MODE_NAMES[tod.mode] or tostring(tod.mode), MODE_NAMES[mode] or tostring(mode), reason)
		end

		tod.mode = mode
		net.Start("tod_setmode")
		net.WriteInt(tod.mode, 4)
		net.WriteInt(offset, 32)
		net.Send(filter or player.GetAll())
	end
end

tod.cvar = CreateConVar("sv_tod", "1", bit.bor(FCVAR_REPLICATED, FCVAR_NOTIFY), "0 = off\n1 = realtime\n2 = demo")

if SERVER then
	local function who(ply)
		return IsValid(ply) and ply:Nick() .. " (" .. ply:SteamID() .. ")" or "console"
	end

	local function cmd(val, reason)
		local time24 = tonumber(val)

		if val == "demo" then
			RunConsoleCommand("sv_tod", "2")
		elseif time24 and time24 >= 0 then
			RunConsoleCommand("sv_tod", "0")
			tod.SetCycle((time24 / 24) % 1, reason)
		else
			-- "realtime", a negative hour or no argument
			RunConsoleCommand("sv_tod", "1")
		end

		timer.Simple(0.1, function()
			tod.SetMode(tod.cvar:GetInt(), nil, reason)

			timer.Simple(0.5, function()
				BroadcastLua[[render.RedownloadAllLightmaps()]]
			end)
		end)
	end

	if aowl then
		aowl.AddCommand({"settod", "tod"}, "set time of day", function(ply, line, val)
			if not ply:IsAdmin() and not ply.Unrestricted and ply.__lastTimeTOD and CurTime() - ply.__lastTimeTOD < 60 then return false, "do not abuse the TOD command" end
			cmd(val, string.format("!tod %q by %s", val or "", who(ply)))
			ply.__lastTimeTOD = CurTime()
		end, "developers")

		aowl.AddCommand("weather", "shows the current and next weather", function(ply)
			local current = tod.GetCurrentWeather()
			local now = os.time()
			local slot = math.floor(now / tod.WEATHER_SLOT)

			for next_slot = slot + 1, slot + 24 * 7 do
				local name = tod.GetSlotWeather(next_slot)
				if name ~= current then
					ply:ChatPrint(string.format("Weather: %s | Next: %s in %s", current, name, string.NiceTime(next_slot * tod.WEATHER_SLOT - now)))
					return
				end
			end

			ply:ChatPrint("Weather: " .. current .. " | Next: " .. current .. " for at least a week")
		end, "players")
	else
		concommand.Add("settod", function(ply, _, args)
			if ply and ply:IsValid() and not ply:IsAdmin() then return end
			cmd(args[1], string.format("settod %q by %s", args[1] or "", who(ply)))
		end)
	end

	hook.Add("PlayerInitialSpawn", "tod_mode", function(ply)
		if not ply or not ply:IsValid() then return end
		tod.SetMode(tod.cvar:GetInt(), ply, "sync for joining " .. who(ply))

		-- manual mode: the joiner's cycle is otherwise nil (midnight) until the next .tod
		if tod.current_cycle then
			net.Start("tod_setcycle")
			net.WriteFloat(tod.current_cycle * 1000)
			net.Send(ply)
		end
	end)
end

local cache = {}

function tod.SetConfigCycle(...)
	cache = {}

	tod.config_cycle = {...}
	table.SortByMember(tod.config_cycle, "hour", true)
end

function tod.SetOverrideConfig(config, lerp)
	tod.override_config = config
	tod.override_lerp = lerp
end

tod.override_configs = {}

-- curve shapes how fast the config reaches full as the weather's amount
-- rises, amount ^ curve.  Overcast is nearly binary outside: a light
-- rain still falls out of a flat grey sky, so rain wants a curve well
-- under 1, or half rain leaves half a blue sky behind the streaks.
function tod.AddOverrideConfig(name, config, probability, curve)
	tod.override_configs[name] = {
		config = config,
		curve = curve or 1,
		amount = 0,
		lerp = 0
	}

	tod.AddWeather(name, probability)
end

function tod.RemoveOverrideConfig(name)
	tod.override_configs[name] = nil
end

tod.fog_configs = {}

function tod.AddFogConfig(name, config, probability)
	tod.fog_configs[name] = {
		config = config,
		amount = 0
	}

	tod.AddWeather(name, probability)
end

local last_time
local last_lerp

function tod.SetVolumetricFog(weathers)
	tod.volumetric_fog = weathers
	cache = {}
	last_time = nil
end

local function volumetric(name)
	local weathers = tod.volumetric_fog
	return weathers ~= nil and weathers[name] == true
end

local function volumetricOverride()
	for name, data in pairs(tod.override_configs) do
		if data.config == tod.override_config then
			return volumetric(name)
		end
	end

	return false
end

hook.Add("Think", "tod", function()
	hook.Add("Think", "tod", function()
		-- initialize tod
		if SERVER and not tod.mode then
			tod.SetMode(tod.cvar:GetInt(), nil, "init")
		end

		local time

		-- manual
		if not tod.mode or tod.mode == 0 or tod.mode == 2 then
			time = tod.GetCycle()
		elseif tod.mode == 1 then
			time = tod.GetRealTime()
		end

		-- the override follows its weather's amount, off costs no lerp
		for name, data in pairs(tod.override_configs) do
			local amount = tod.GetWeather(name)
			if data.amount ~= amount then
				data.amount = amount
				data.lerp = amount > 0 and amount ^ data.curve or 0
				if amount > 0 then
					tod.SetOverrideConfig(data.config, data.lerp)
				else
					tod.SetOverrideConfig()
				end

				cache = {}
			end
		end

		for name, data in pairs(tod.fog_configs) do
			local amount = tod.GetWeather(name)
			if data.amount ~= amount then
				data.amount = amount
				cache = {}
			end
		end

		-- cache lerp results
		-- good for realtime
		time = math.Round(time, 3)
		local cfg

		if cache[time] then
			cfg = cache[time]
		else
			cfg = tod.SampleCycle(time)

			-- for snow and such
			if tod.override_config then
				local clear_fog = {
					fog_max_density = cfg.fog_max_density,
					fog_color = cfg.fog_color,
					fog_start = cfg.fog_start,
					fog_end = cfg.fog_end,
				}

				cfg = tod.LerpConfigs(tod.override_lerp, cfg, tod.override_config)

				-- A weather's fog is written against a clear sky, so it
				-- only stands where it is thicker than the hour's own:
				-- fading to it instead thinned the air wherever the hour
				-- was the foggier of the two, and rain cleared both dusk
				-- and halloween's black fog rather than closing them in.
				-- The hour keeps its colour and range along with its
				-- density, or a weather that adds no fog would still
				-- repaint it.
				if isnumber(clear_fog.fog_max_density) and isnumber(cfg.fog_max_density)
					and (clear_fog.fog_max_density >= cfg.fog_max_density or volumetricOverride()) then
					for key, val in pairs(clear_fog) do
						cfg[key] = val
					end
				end
			end

			for name, data in pairs(tod.fog_configs) do
				local fog = data.config
				if data.amount > 0 and not volumetric(name) and isnumber(cfg.fog_max_density) and fog.fog_max_density > cfg.fog_max_density then
					local hour = {}
					for key in pairs(fog) do
						hour[key] = cfg[key]
					end

					for key, val in pairs(tod.Lerp(data.amount, hour, fog)) do
						cfg[key] = val
					end
				end
			end

			tod.AlignSunToLight(cfg, time)

			-- an override's light_scale dims the world after the sun is
			-- placed, so rain darkens the day without moving it
			local o = tod.override_config
			if o and isnumber(o.light_scale) and isnumber(cfg.world_light_multiplier) then
				cfg.world_light_multiplier = cfg.world_light_multiplier * Lerp(tod.override_lerp or 0, 1, o.light_scale)
			end

			cache[time] = cfg
		end

		if last_time ~= time or last_lerp ~= tod.override_lerp then
			tod.SetConfig(cfg)
			last_time = time
			last_lerp = tod.override_lerp
		end
	end)
end)

include("tod/default_cycle.lua")

if SERVER then
	AddCSLuaFile("tod/default_cycle.lua")
end

tod.season_cvar = CreateConVar("sv_tod_season", "", bit.bor(FCVAR_REPLICATED, FCVAR_ARCHIVE), "forces the season on the next map load: winter, autumn or summer, empty for current season")

local SEASONS = {winter = true, autumn = true, summer = true}

function tod.GetSeason()
	local forced = tod.season_cvar:GetString():lower()
	if SEASONS[forced] then return forced end

	local month = tonumber(os.date("%m")) or -1
	if month >= 12 or month <= 2 then return "winter" end
	if month == 10 or month == 11 then return "autumn" end

	return "summer"
end

if SERVER then
	function tod.ForceSeason(season)
		season = season and season:lower() or ""
		if season ~= "" and not SEASONS[season] then return false end

		RunConsoleCommand("sv_tod_season", season)

		return true
	end
end
-- weather
do
	include("tod/fog.lua")

	if SERVER then
		AddCSLuaFile("tod/fog.lua")
		AddCSLuaFile("tod/snow.lua")
		AddCSLuaFile("tod/rain.lua")
		AddCSLuaFile("tod/autumn.lua")
	end

	local season = tod.GetSeason()
	if season == "winter" then
		include("tod/snow.lua")
	else
		include("tod/rain.lua")
	end

	if season == "autumn" and CLIENT then
		include("tod/autumn.lua")
	end
end