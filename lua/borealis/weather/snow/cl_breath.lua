local snow = shaderpack.snow
local breath = snow.breath or {}
snow.breath = breath

local powder, wind = snow.powder, shaderpack.wind

local ENABLED = CreateClientConVar("borealis_breath", "1", true, false, "show players' breath outdoors in winter")

local MATERIAL = "particle/particle_smokegrenade"
local TICK = 0.05
local RANGE = 1500
local SKY_DISTANCE = 16384
local SKY_INTERVAL = 1
local OUTSIDE_RATE = 0.5
local EFFORT_RISE, EFFORT_FALL = 1, 0.15
local RUN_SPEED = 300
local PERIOD_REST, PERIOD_RUN = 4.5, 2
local PERIOD_JITTER = 0.15
local EXHALE = 0.35
local SPEECH_MIN = 0.05
local ALPHA = 40
local SHADE_R, SHADE_G, SHADE_B = 0.74, 0.78, 0.84
local SPEED_MIN, SPEED_MAX = 14, 26
local CARRY = 0.9
local DRAG = 90
local RISE = 6
local DRIFT = 30
local LIFE_MIN, LIFE_MAX = 1.1, 1.7
local SIZE_MIN, SIZE_MAX = 5, 8
local EYES_DROP = 3
local VIEW_AHEAD, VIEW_DROP = 6, 4

local emitter
local states = {}
local mouths = {}
local nextTick = 0
local skyRes = {}
local skyTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = skyRes }
local spawnPos, velocity, gravity = Vector(), Vector(), Vector()

local function mouthOf(ply)
	local model = ply:GetModel() or ""
	local m = mouths[model]
	if m == nil then
		local id = ply:LookupAttachment("mouth")
		if id and id > 0 then
			m = { id = id, drop = 0 }
		else
			id = ply:LookupAttachment("eyes")
			m = id and id > 0 and { id = id, drop = EYES_DROP } or false
		end
		mouths[model] = m
	end

	return m
end

local function skyOpen(pos)
	skyTrace.start:SetUnpacked(pos.x, pos.y, pos.z)
	skyTrace.endpos:SetUnpacked(pos.x, pos.y, pos.z + SKY_DISTANCE)
	util.TraceLine(skyTrace)

	return skyRes.HitSky and not skyRes.StartSolid
end

local function bodyVelocity(ply)
	local vehicle = ply:InVehicle() and ply:GetVehicle()

	return IsValid(vehicle) and vehicle:GetVelocity() or ply:GetVelocity()
end

local function canBreathe(ply, eye, me)
	if not ply:Alive() or ply:IsDormant() or ply:GetNoDraw() or ply:WaterLevel() >= 3 then return false end
	if ply == me then return true end

	return ply:GetPos():DistToSqr(eye) <= RANGE * RANGE
end

local function emit(pos, dir, carry, s, strength)
	local p = emitter:Add(MATERIAL, pos)
	if not p then return end

	local speed = math.Rand(SPEED_MIN, SPEED_MAX) * (0.8 + 0.4 * s.effort)
	velocity:SetUnpacked(
		dir.x * speed + carry.x * CARRY + math.Rand(-2, 2),
		dir.y * speed + carry.y * CARRY + math.Rand(-2, 2),
		dir.z * speed + carry.z * CARRY + math.Rand(-1, 2))
	p:SetVelocity(velocity)

	local drift = DRIFT * wind.Strength()
	gravity:SetUnpacked(wind.X * drift, wind.Y * drift, RISE)
	p:SetGravity(gravity)
	p:SetAirResistance(DRAG)
	p:SetDieTime(math.Rand(LIFE_MIN, LIFE_MAX))
	p:SetStartAlpha(math.floor(ALPHA * strength * s.outside + 0.5))
	p:SetEndAlpha(0)
	p:SetStartSize(1)
	p:SetEndSize(math.Rand(SIZE_MIN, SIZE_MAX) * (0.8 + 0.4 * s.effort))
	p:SetRoll(math.Rand(0, 360))
	p:SetRollDelta(math.Rand(-0.5, 0.5))
	p:SetColor(s.r, s.g, s.b)
	p:SetLighting(false)
end

local function breathe(ply, s, now, me)
	local firstPerson = ply == me and not ply:ShouldDrawLocalPlayer()
	local pos, dir
	if firstPerson then
		local ang = EyeAngles()
		dir = ang:Forward()
		local up = ang:Up()
		local eye = EyePos()
		spawnPos:SetUnpacked(eye.x + dir.x * VIEW_AHEAD - up.x * VIEW_DROP, eye.y + dir.y * VIEW_AHEAD - up.y * VIEW_DROP, eye.z + dir.z * VIEW_AHEAD - up.z * VIEW_DROP)
		pos = spawnPos
	else
		local m = mouthOf(ply)
		local a = m and ply:GetAttachment(m.id)
		if not a then return end

		dir = ply:EyeAngles():Forward()
		spawnPos:SetUnpacked(a.Pos.x + dir.x, a.Pos.y + dir.y, a.Pos.z + dir.z - m.drop)
		pos = spawnPos
	end

	if now >= s.nextSky then
		s.nextSky = now + SKY_INTERVAL
		s.open = skyOpen(pos)
	end

	if s.outside <= 0 then return end

	local strength = 0
	if now < s.exhaleEnd then
		strength = math.sin(math.pi * (1 - (s.exhaleEnd - now) / s.exhaleLength))
	end

	if ply:IsSpeaking() then
		local volume = ply:VoiceVolume()
		if volume > SPEECH_MIN then strength = math.max(strength, math.min(1, volume * 2)) end
	end

	if strength <= 0 then return end

	if not s.r then
		local r, g, b = powder.Color(pos)
		s.r, s.g, s.b = r * SHADE_R, g * SHADE_G, b * SHADE_B
	end
	emit(pos, dir, bodyVelocity(ply), s, strength)
end

local function update(ply, s, now, dt, me)
	local busy = ply:InVehicle() or ply:GetMoveType() == MOVETYPE_NOCLIP
	local target = busy and 0 or math.min(1, ply:GetVelocity():Length2D() / RUN_SPEED)
	local rate = target > s.effort and EFFORT_RISE or EFFORT_FALL
	s.effort = s.effort + math.Clamp(target - s.effort, -rate * dt, rate * dt)
	s.outside = math.Clamp(s.outside + (s.open and OUTSIDE_RATE or -OUTSIDE_RATE) * dt, 0, 1)

	if now >= s.nextBreath then
		local period = Lerp(s.effort, PERIOD_REST, PERIOD_RUN)
		s.exhaleLength = period * EXHALE
		s.exhaleEnd = now + s.exhaleLength
		s.nextBreath = now + period * math.Rand(1 - PERIOD_JITTER, 1 + PERIOD_JITTER)
		s.r = nil
	end

	breathe(ply, s, now, me)
end

local function think()
	local now = RealTime()
	if now < nextTick then return end
	local dt = math.min(now - nextTick + TICK, 1)
	nextTick = now + TICK

	local me = LocalPlayer()
	local eye = EyePos()
	emitter:SetPos(eye)

	for ply in pairs(states) do
		if not IsValid(ply) then states[ply] = nil end
	end

	for _, ply in player.Iterator() do
		if canBreathe(ply, eye, me) then
			local s = states[ply]
			if not s then
				s = {
					effort = 0, outside = 0, open = false,
					nextSky = now + math.Rand(0, SKY_INTERVAL),
					nextBreath = now + math.Rand(0, PERIOD_REST),
					exhaleEnd = 0, exhaleLength = 1,
				}
				states[ply] = s
			end
			update(ply, s, now, dt, me)
		else
			states[ply] = nil
		end
	end
end

local function stop()
	hook.Remove("Think", "borealis_breath")
	if emitter and emitter:IsValid() then emitter:Finish() end
	emitter, states = nil, {}
end

local function start()
	stop()
	if shaderpack.Season() ~= "winter" then return end

	emitter = ParticleEmitter(EyePos())
	hook.Add("Think", "borealis_breath", think)
end

function breath.Active()
	return emitter ~= nil
end

shaderpack.AfterWorld("borealis_breath", shaderpack.Toggle("borealis_breath", ENABLED, {}, start, stop))
