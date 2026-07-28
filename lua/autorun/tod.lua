if string.find(game.GetMap(), "gm_construct_m") then
    local async = require("async") or _G.async
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
                P["sky_" .. name] = function(val)
                    if mult_by_world_light then
                        val = val * C.world_light_multiplier
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
        return math.Clamp(math.Round(min + (mult * min)), min, 127)
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
        P.bloom_darken = 0
        P.bloom_multiply = 0
        P.bloom_width = 1
        P.bloom_height = 1
        P.bloom_passes = 1
        P.bloom_saturation = 1
        P.bloom_color = Vector(1, 1, 1)
        P.color_add = Vector(0, 0, 0)
        P.color_multiply = Vector(0, 0, 0)
        P.color_brightness = 0
        P.color_contrast = 1
        P.color_saturation = 1
        P.sharpen_contrast = 0
        P.sharpen_distance = 0
        P.star_intensity = 0
        P.moon_size = 1
        P.moon_angles = Angle(0, 0, 0)
        P.fog_color = Vector(1, 1, 1)
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
                engine.LightStyle(tod.MultToLightEnv(val), 0)
            end
        end
    end

    if CLIENT then
        -- texture replacer
        do
            tod.replaced_textures = {}

            function tod.ReplaceTexture(path, to)
                path = path:lower()
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

                    tod.replaced_textures[path] = tod.replaced_textures[path] or {}
                    tod.replaced_textures[path].OldTexture = tod.replaced_textures[path].OldTexture or mat:GetTexture("$basetexture")
                    tod.replaced_textures[path].NewTexture = tex
                    mat:SetTexture("$basetexture", tex)

                    return mat
                end

                return false
            end

            function tod.SetTextureColor(path, color)
                path = path:lower()
                local mat = Material(path)

                if not mat:IsError() then
                    tod.replaced_textures[path] = tod.replaced_textures[path] or {}
                    tod.replaced_textures[path].OldColor = tod.replaced_textures[path].OldColor or mat:GetVector("$color")
                    tod.replaced_textures[path].NewColor = color
                    mat:SetVector("$color", color)

                    return true
                end

                return false
            end

            function tod.RestoreAllTextures()
                for name, tbl in pairs(tod.replaced_textures) do
                    if not pcall(function()
                        if tbl.OldTexture then
                            tod.ReplaceTexture(name, tbl.OldTexture)
                        end

                        if tbl.OldColor then
                            tod.SetTextureColor(name, tbl.OldColor)
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
                local byte = tod.MultToLightEnv(tod.GetCycle())

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
                local atmosphere_outter = Material("models/debug/debugwhite")
                local render = render

                local SetMaterialOverride = function(m)
                    render.MaterialOverride(m == 0 and nil or m)
                end

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
                    local angles = vector_origin

                    hook.Add("RenderScene", "tod_moon", function(pos, ang)
                        origin = pos
                        angles = ang
                    end)

                    local render_DrawSprite = render.DrawSprite
                    local render_SetMaterial = render.SetMaterial
                    local cam_Start3D = cam.Start3D
                    local cam_End3D = cam.End3D

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

        local enable = CreateClientConVar("tod_pp", "0")
        local DrawColorModify = DrawColorModify

        hook.Add("RenderScreenspaceEffects", "tod_pp", function()
            if not enable:GetBool() then return end
            -- hack
            -- DrawColorModify may exist after this script is ran
            DrawColorModify = DrawColorModify or _G.DrawColorModify

            if C.sharpen_contrast ~= 0 or C.sharpen_distance ~= 0 then
                DrawSharpen(C.sharpen_contrast, C.sharpen_distance)
            end

            if C.color_add ~= vector_origin or C.color_multiply ~= vector_origin or C.color_brightness ~= 0 or C.color_contrast ~= 1 or C.color_saturation ~= 1 then
                local params = {}
                params["$pp_colour_addr"] = C.color_multiply.r
                params["$pp_colour_addg"] = C.color_multiply.g
                params["$pp_colour_addb"] = C.color_multiply.b
                params["$pp_colour_brightness"] = C.color_brightness
                params["$pp_colour_contrast"] = C.color_contrast
                params["$pp_colour_colour"] = C.color_saturation
                params["$pp_colour_mulr"] = C.color_add.r
                params["$pp_colour_mulg"] = C.color_add.g
                params["$pp_colour_mulb"] = C.color_add.b
                DrawColorModify(params)
            end

            if C.bloom_darken ~= 1 or C.bloom_multiply ~= 0 then
                DrawBloom(C.bloom_darken, C.bloom_multiply, C.bloom_width, C.bloom_height, C.bloom_passes, C.bloom_saturation, C.bloom_color.r, C.bloom_color.g, C.bloom_color.b)
            end
        end)

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

        -- sectors (to use with snow and such)
        do
            -- help
            local trace = {}
            local util = util

            local function QuickTrace(origin, dir, filter)
                trace.start = origin
                trace.endpos = origin + dir
                trace.filter = filter

                return util.TraceLine(trace)
            end

            -- initialize points
            local data = {}
            local max = 32000
            local grid_size = 768
            local range = max / grid_size
            local pos
            local CONTENTS_EMPTY = CONTENTS_EMPTY
            local CONTENTS_TESTFOGVOLUME = CONTENTS_TESTFOGVOLUME
            local sectorthink

            local function thread()
                local v = Vector(0, 0, 0)
                local trash_up = Vector(0, 0, 1)

                local function vec(a, b, c)
                    v[1] = a
                    v[2] = b
                    v[3] = c

                    return v
                end

                for x = -range, range do
                    x = x * grid_size
                    async.waitTick():await()

                    for y = -range, range do
                        y = y * grid_size

                        for z = -range, range do
                            z = z * grid_size
                            pos = vec(x, y, z)
                            local conents = util.PointContents(pos)

                            if conents == CONTENTS_EMPTY or conents == CONTENTS_TESTFOGVOLUME then
                                trash_up[3] = max * 2
                                local up = QuickTrace(pos, trash_up)
                                up.HitTexture = up.HitTexture:lower()

                                if up.HitTexture == "tools/toolsskybox" or up.HitTexture == "**empty**" then
                                    table.insert(data, Vector(pos[1], pos[2], pos[3]))
                                end
                            end
                        end
                    end
                end

                local datal = #data
                -- show or hide points
                --local function fastlen(point)
                --	return point.x * point.x + point.y * point.y + point.z * point.z
                --end
                local draw_these = {}
                local iterations = math.min(math.ceil(datal / (1 / 0.1)), datal)
                Msg"[TOD] Processed data points: "
                print(datal, "visiters:", iterations)
                local lastkey = 1
                local lastpos = nil
                local len = 3000 ^ 2
                local movelen = 100 ^ 2
                local eyepos = Vector()
                local localplayer

                hook.Add("RenderScene", "tod_eyepos", function(pos, ang)
                    localplayer = localplayer or LocalPlayer()
                    eyepos:Set(pos)
                    eyepos:Add(localplayer:GetVelocity())
                end)

                local function sector_think()
                    if lastpos == nil or lastpos:DistToSqr(eyepos) > movelen then
                        local c = #data
                        local r = math.min(iterations, c)
                        local completed = false

                        for i = 1, r do
                            local key = lastkey + 1

                            if key > c then
                                completed = true
                                lastkey = 1
                                break
                            end

                            local point = data[key]
                            local dc = point:DistToSqr(eyepos) < len

                            if dc and draw_these[key] == nil then
                                draw_these[key] = point
                            elseif not dc and draw_these[key] ~= nil then
                                draw_these[key] = nil
                            end

                            lastkey = key
                        end

                        if completed then
                            --Msg"."
                            lastpos = eyepos
                        end
                    end
                end

                function tod.GetOutsideSectors()
                    return draw_these
                end

                local last

                function tod.EnableSectorThink(b)
                    if last ~= b then
                        if b then
                            timer.Create("tod_sector_think", 0.25, 0, sector_think)
                        else
                            timer.Remove("tod_sector_think")
                        end

                        last = b
                    end
                end

                if sectorthink ~= nil then
                    tod.EnableSectorThink(sectorthink)
                    sectorthink = nil
                end
            end

            -- thread
            local processing

            local function startproc()
                if processing then return end
                processing = true
                async.runTask(thread)
            end

            -- wrappers
            function tod.EnableSectorThink(b)
                startproc()
                sectorthink = b
            end

            function tod.GetOutsideSectors()
                startproc()

                return {}
            end
        end
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

    function tod.GetWeatherChance(probability)
        if tod.force_weather ~= nil then return tod.force_weather end
        probability = probability or 0.5
        math.randomseed(math.floor(CurTime() / 100))
        local b = math.random() < probability
        math.randomseed(RealTime())

        return b
    end

    function tod.SetParameter(key, val)
        if type(tod.Params[key]) == "function" then
            tod.Params[key](val)
        end

        tod.CurrentParams[key] = val
    end

    function tod.GetParameter(key)
        return tod.CurrentParams[key]
    end

    function tod.SetConfig(data)
        for key, val in pairs(data) do
            tod.SetParameter(key, val)
        end
    end

    function tod.GetMode()
        return tod.mode
    end

    function tod.GetCycle()
        if tod.mode == 2 then return (CurTime() / (20)) % 1 end -- demo mode

        return tod.current_cycle or 0
    end

    if CLIENT then
        net.Receive("tod_setcycle", function()
            tod.current_cycle = net.ReadFloat() / 1000
        end)

        net.Receive("tod_setmode", function()
            tod.mode = net.ReadInt(4)
        end)
    end

    if SERVER then
        util.AddNetworkString("tod_setcycle")

        function tod.SetCycle(time)
            tod.current_cycle = time and (time % 1) or -1
            net.Start("tod_setcycle")
            net.WriteFloat(tod.current_cycle * 1000)
            net.Send(player.GetAll())
        end

        util.AddNetworkString("tod_setmode")

        function tod.SetMode(mode, filter)
            tod.mode = mode
            net.Start("tod_setmode")
            net.WriteInt(tod.mode, 4)
            net.Send(filter or player.GetAll())
        end
    end

    tod.cvar = CreateConVar("sv_tod", "1", bit.bor(FCVAR_REPLICATED, FCVAR_NOTIFY), "0 = off\n1 = realtime\n2 = demo")

    if SERVER then
        local function cmd(val)
            local time24 = val and tonumber(val) or 1

            if time24 then
                RunConsoleCommand("sv_tod", "0")
                tod.SetCycle((time24 / 24) % 1)
            elseif val == "demo" then
                RunConsoleCommand("sv_tod", "2")
            elseif val == "realtime" or time24 < 0 then
                RunConsoleCommand("sv_tod", "1")
            end

            timer.Simple(0.1, function()
                tod.SetMode(tod.cvar:GetInt())

                timer.Simple(0.5, function()
                    BroadcastLua[[render.RedownloadAllLightmaps()]]
                end)
            end)
        end

        if aowl then
            aowl.AddCommand({"settod", "tod"}, "set time of day", function(player, line, val)
                if not player:IsAdmin() and not player.Unrestricted and player.__lastTimeTOD and CurTime() - player.__lastTimeTOD < 60 then return false, "do not abuse the TOD command" end
                cmd(val)
                player.__lastTimeTOD = CurTime()
            end, "developers")
        else
            concommand.Add("settod", function(ply, _, args)
                if ply and ply:IsValid() and not ply:IsAdmin() then return end
                cmd(args[1])
            end)
        end

        hook.Add("PlayerInitialSpawn", "tod_mode", function(ply)
            if not ply or not ply:IsValid() then return end
            tod.SetMode(tod.cvar:GetInt(), ply)
        end)
    end

    local cache = {}

    function tod.SetConfigCycle(...)
        cache = {}

        tod.config_cycle = {...}
    end

    function tod.SetOverrideConfig(config, lerp)
        tod.override_config = config
        tod.override_lerp = lerp
    end

    tod.override_configs = {}

    function tod.AddOverrideConfig(name, config, probability)
        tod.override_configs[name] = {
            config = config,
            probability = probability,
            lerp = 0
        }
    end

    function tod.RemoveOverrideConfig(name)
        tod.override_configs[name] = nil
    end

    local last_time
    local last_lerp

    hook.Add("Think", "tod", function()
        hook.Add("Think", "tod", function()
            -- initialize tod
            if SERVER and not tod.mode then
                tod.SetMode(tod.cvar:GetInt())
            end

            local time

            -- manual
            if not tod.mode or tod.mode == 0 or tod.mode == 2 then
                time = tod.GetCycle()
            elseif tod.mode == 1 then
                -- realtime
                local H, M, S = os.date("%H"), os.date("%M"), os.date("%S")
                local fraction = (H * 3600 + M * 60 + S) / 86400
                time = fraction % 1
            end

            for name, data in pairs(tod.override_configs) do
                if tod.GetWeatherChance(data.probability) then
                    data.lerp = math.min(data.lerp + FrameTime(), 1)

                    if data.last_lerp ~= data.lerp then
                        tod.SetOverrideConfig(data.config, data.lerp)
                        data.last_lerp = data.lerp
                        cache = {}
                    end
                else
                    data.lerp = math.max(data.lerp - FrameTime(), 0)

                    if data.last_lerp ~= data.lerp then
                        if data.lerp == -1 then
                            tod.SetOverrideConfig()
                        else
                            tod.SetOverrideConfig(data.config, data.lerp)
                        end

                        cache = {}
                        data.last_lerp = data.lerp
                    end
                end
            end

            -- cache lerp results
            -- good for realtime
            time = math.Round(time, 3)
            local cfg

            if cache[time] then
                cfg = cache[time]
            else
                cfg = tod.LerpConfigs(time, unpack(tod.config_cycle))

                -- for snow and such
                if tod.override_config then
                    cfg = tod.LerpConfigs(tod.override_lerp, cfg, tod.override_config)
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

    -- weather
    do
        local month = tonumber(os.date("%m")) or -1

        if month >= 12 or month <= 2 then
            include("tod/snow.lua")

            if SERVER then
                AddCSLuaFile("tod/snow.lua")
            end
        end
    end
else
    print("Not a metastruct map, disabling TOD!")
end