local snow = shaderpack.snow

local NET = snow.IMPACT_NET
local MAX_BULLETS_PER_TICK = 24
local MIN_NZ = 0.5
local MAX_RADIUS = 1023
local GRENADE_SOUNDS = { ["basegrenade.explode"] = true, ["hegrenade.explode"] = true }
local DEFAULT_RADIUS = 250
local DUPLICATE_TIME, DUPLICATE_DISTANCE = 0.1, 64

util.AddNetworkString(NET)

local tick, sent = -1, 0
local lastPos, lastTime = Vector(), -math.huge

local function winter()
	return shaderpack.Season() == "winter"
end

local function blast(pos, radius)
	if not isvector(pos) or not isnumber(radius) or radius <= 0 or not winter() then return end

	local now = CurTime()
	if now - lastTime < DUPLICATE_TIME and pos:DistToSqr(lastPos) < DUPLICATE_DISTANCE * DUPLICATE_DISTANCE then return end
	lastTime = now
	lastPos:Set(pos)

	net.Start(NET)
	net.WriteBool(true)
	net.WriteVector(pos)
	net.WriteUInt(math.Clamp(math.floor(radius), 0, MAX_RADIUS), 10)
	net.SendPVS(pos)
end

hook.Add("PostEntityFireBullets", "borealis_snow_impacts", function(ent, data)
	local tr = data.Trace
	if not tr or not tr.HitWorld or tr.HitSky or tr.HitNormal.z < MIN_NZ or not winter() then return end

	local now = engine.TickCount()
	if now ~= tick then tick, sent = now, 0 end
	if sent >= MAX_BULLETS_PER_TICK then return end

	local filter = RecipientFilter()
	filter:AddPVS(tr.HitPos)
	if IsValid(ent) and ent:IsPlayer() then filter:RemovePlayer(ent) end
	if filter:GetCount() == 0 then return end

	sent = sent + 1
	net.Start(NET, true)
	net.WriteBool(false)
	net.WriteVector(tr.HitPos)
	net.WriteNormal(tr.Normal)
	net.Send(filter)
end)

hook.Add("AcceptInput", "borealis_snow_impacts", function(ent, input)
	if not isstring(input) or input:lower() ~= "explode" or ent:GetClass() ~= "env_explosion" then return end

	local radius = ent:GetInternalVariable("m_iRadiusOverride")
	if not isnumber(radius) or radius <= 0 then
		radius = (tonumber(ent:GetInternalVariable("m_iMagnitude")) or 100) * 2.5
	end

	blast(ent:GetPos(), radius)
end)

hook.Add("EntityEmitSound", "borealis_snow_impacts", function(data)
	local name = data.OriginalSoundName
	if not isstring(name) or not GRENADE_SOUNDS[name:lower()] then return end

	local ent = data.Entity
	if not IsValid(ent) or ent:IsWorld() then return end

	local radius = tonumber(ent.m_DmgRadius) or tonumber(ent:GetInternalVariable("m_DmgRadius")) or DEFAULT_RADIUS
	blast(ent:GetPos(), radius)
end)

local original = snow.blastDamage or { util.BlastDamage, util.BlastDamageInfo }
snow.blastDamage = original

function util.BlastDamage(inflictor, attacker, pos, radius, damage)
	blast(pos, radius)

	return original[1](inflictor, attacker, pos, radius, damage)
end

function util.BlastDamageInfo(info, pos, radius)
	blast(pos, radius)

	return original[2](info, pos, radius)
end
