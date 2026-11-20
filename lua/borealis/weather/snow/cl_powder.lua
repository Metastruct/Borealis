local snow = shaderpack.snow
local powder = snow.powder or {}
snow.powder = powder

local ENABLED = CreateClientConVar("borealis_snow_powder", "1", true, false, "kick up snow powder under vehicles and impacts")

local MATERIAL = "particle/particle_smokegrenade"
local DUST_MATERIAL = "particle/particle_noisesphere"
local CLUMP_MATERIAL = "particle/snow"
local CLUMP_GRAVITY, CLUMP_DRAG = 600, 20
local DEPTH = snow.DEPTH
local ALBEDO = 0.25
local FILL = 0.5
local GAMMA = 1 / 2.2
local VEHICLE_MIN_SPEED, VEHICLE_FULL_SPEED = 150, 900
local VEHICLE_INTERVAL = 0.08
local VEHICLE_RANGE = 3000
local VEHICLE_CARRY_FRONT, VEHICLE_CARRY_REAR = 0.85, 0.7
local VEHICLE_DRAG = 150
local DUST_FALL = 220
local SPRAY_FALL = 120
local SPRAY_CLUMPS, SPRAY_CLUMP_SIZE, SPRAY_CLUMP_SPEED = 1.5, 0.12, 1.6
local WHEELS = { "wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr" }
local WHEEL_REACH = 64
local UP = Vector(0, 0, 1)

local emitter
local samplePos, spawnPos, velocity, gravity = Vector(), Vector(), Vector(), Vector()

local function getEmitter(pos)
	if not emitter or not emitter:IsValid() then
		emitter = ParticleEmitter(pos)
	else
		emitter:SetPos(pos)
	end

	return emitter
end

function powder.Active()
	return ENABLED:GetBool() and snow.Running and snow.Running()
end

function powder.Color(pos)
	samplePos:SetUnpacked(pos.x, pos.y, pos.z + 8)
	local l = render.ComputeLighting(samplePos, UP)
	local amb = render.GetAmbientLightColor()
	local foliage = shaderpack.foliage
	local scale = foliage and foliage.WorldLightScale and foliage.WorldLightScale() or 1
	local k = ALBEDO * render.GetToneMappingScaleLinear().x

	local function channel(light, fill)
		return math.floor(math.Clamp((math.min(light, 2) * scale + fill * FILL) * k, 0, 1) ^ GAMMA * 255 + 0.5)
	end

	return channel(l.x, amb.x), channel(l.y, amb.y), channel(l.z, amb.z)
end

function powder.Puff(pos, vel, size, life, alpha, fall, r, g, b, material)
	local em = getEmitter(pos)
	if not em then return end

	local p = em:Add(material or MATERIAL, pos)
	if not p then return end

	p:SetVelocity(vel)
	p:SetDieTime(life)
	p:SetStartAlpha(alpha)
	p:SetEndAlpha(0)
	p:SetStartSize(size * 0.35)
	p:SetEndSize(size)
	p:SetRoll(math.Rand(0, 360))
	p:SetRollDelta(math.Rand(-0.6, 0.6))
	p:SetAirResistance(60)
	gravity:SetUnpacked(0, 0, -fall)
	p:SetGravity(gravity)
	p:SetColor(r, g, b)
	p:SetLighting(false)
	p:SetCollide(true)
	p:SetBounce(0.05)

	return p
end

local function landed(p)
	p:SetLifeTime(p:GetDieTime())
end

function powder.Clump(pos, vel, size, life, r, g, b)
	local em = getEmitter(pos)
	if not em then return end

	local p = em:Add(CLUMP_MATERIAL, pos)
	if not p then return end

	p:SetVelocity(vel)
	p:SetDieTime(life)
	p:SetStartAlpha(255)
	p:SetEndAlpha(160)
	p:SetStartSize(size)
	p:SetEndSize(size * 0.6)
	p:SetRoll(math.Rand(0, 360))
	p:SetRollDelta(math.Rand(-4, 4))
	p:SetAirResistance(CLUMP_DRAG)
	gravity:SetUnpacked(0, 0, -CLUMP_GRAVITY)
	p:SetGravity(gravity)
	p:SetColor(r, g, b)
	p:SetLighting(false)
	p:SetCollide(true)
	p:SetCollideCallback(landed)

	return p
end

function powder.Spray(pos, dir, count, speed, size, life, alpha)
	local r, g, b = powder.Color(pos)
	for _ = 1, count do
		velocity:SetUnpacked(dir.x * speed + math.Rand(-0.5, 0.5) * speed, dir.y * speed + math.Rand(-0.5, 0.5) * speed, dir.z * speed * math.Rand(0.5, 1.2))
		spawnPos:SetUnpacked(pos.x + math.Rand(-2, 2), pos.y + math.Rand(-2, 2), pos.z)
		local s = size * math.Rand(0.7, 1.3)
		local p = powder.Puff(spawnPos, velocity, s, life * math.Rand(0.7, 1.3), alpha, SPRAY_FALL, r, g, b, DUST_MATERIAL)
		if p then p:SetStartSize(s * 0.6) end
	end

	local clumpSize = math.Clamp(size * SPRAY_CLUMP_SIZE, 1, 4)
	local clumpSpeed = speed * SPRAY_CLUMP_SPEED
	for _ = 1, math.ceil(count * SPRAY_CLUMPS) do
		velocity:SetUnpacked(
			dir.x * clumpSpeed + math.Rand(-0.6, 0.6) * clumpSpeed,
			dir.y * clumpSpeed + math.Rand(-0.6, 0.6) * clumpSpeed,
			dir.z * clumpSpeed * math.Rand(0.6, 1.3))
		spawnPos:SetUnpacked(pos.x + math.Rand(-2, 2), pos.y + math.Rand(-2, 2), pos.z)
		powder.Clump(spawnPos, velocity, clumpSize * math.Rand(0.6, 1.2), math.Rand(0.8, 1.6), r, g, b)
	end
end

local vehicles = {}
local nextVehicles = 0

local function track(e)
	if IsValid(e) and e:IsVehicle() then vehicles[e] = true end
end

hook.Add("OnEntityCreated", "borealis_snow_powder", function(e)
	timer.Simple(0, function()
		track(e)
	end)
end)

hook.Add("EntityRemoved", "borealis_snow_powder", function(e)
	vehicles[e] = nil
end)

for _, e in ipairs(ents.GetAll()) do
	track(e)
end

local groundRes = {}
local groundTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = groundRes }

local function extentAlong(axisA, extentA, axisB, extentB, x, y)
	return math.abs(axisA.x * x + axisA.y * y) * extentA + math.abs(axisB.x * x + axisB.y * y) * extentB
end

local function ground(x, y, top, bottom)
	groundTrace.start:SetUnpacked(x, y, top)
	groundTrace.endpos:SetUnpacked(x, y, bottom)
	util.TraceLine(groundTrace)
	if not groundRes.Hit or groundRes.StartSolid then return end

	return groundRes.HitPos
end

local wheelIds = {}

local function wheelAttachments(e)
	local model = e:GetModel() or ""
	local ids = wheelIds[model]
	if ids == nil then
		ids = {}
		for _, name in ipairs(WHEELS) do
			local id = e:LookupAttachment(name)
			if id and id > 0 then ids[#ids + 1] = id end
		end
		if #ids == 0 then ids = false end
		wheelIds[model] = ids
	end

	return ids
end

local function wheelPoints(e, bx, by)
	local points = {}
	local ids = wheelAttachments(e)
	if ids then
		for _, id in ipairs(ids) do
			local a = e:GetAttachment(id)
			if a then points[#points + 1] = { a.Pos.x, a.Pos.y, a.Pos.z, a.Pos.z - WHEEL_REACH } end
		end
		if #points > 0 then return points end
	end

	local mins, maxs = e:OBBMins(), e:OBBMaxs()
	local center = e:LocalToWorld((mins + maxs) * 0.5)
	local ax, ay = e:GetForward(), e:GetRight()
	local ex, ey, ez = (maxs.x - mins.x) * 0.5, (maxs.y - mins.y) * 0.5, (maxs.z - mins.z) * 0.5
	local halfLength = extentAlong(ax, ex, ay, ey, bx, by) * 0.75
	local halfWidth = extentAlong(ax, ex, ay, ey, -by, bx) * 0.8
	for _, along in ipairs({ -1, 1 }) do
		for _, across in ipairs({ -1, 1 }) do
			points[#points + 1] = {
				center.x + bx * halfLength * along - by * halfWidth * across,
				center.y + by * halfLength * along + bx * halfWidth * across,
				center.z, center.z - ez - DEPTH * 2,
			}
		end
	end

	return points
end

local function vehicleSpray(e, eye)
	if e:IsDormant() or e:GetPos():DistToSqr(eye) > VEHICLE_RANGE * VEHICLE_RANGE then return end

	local vel = e:GetVelocity()
	local speed = vel:Length2D()
	if speed < VEHICLE_MIN_SPEED then return end

	local f = math.Clamp((speed - VEHICLE_MIN_SPEED) / (VEHICLE_FULL_SPEED - VEHICLE_MIN_SPEED), 0.15, 1)
	local bx, by = vel.x / speed, vel.y / speed
	local center = e:WorldSpaceCenter()
	for _, point in ipairs(wheelPoints(e, bx, by)) do
		local x, y = point[1], point[2]
		local dx, dy = x - center.x, y - center.y
		local front = dx * bx + dy * by > 0
		local across = (bx * dy - by * dx) > 0 and 1 or -1
		local contact = ground(x, y, point[3], point[4])
		if contact and snow.footsteps.OnSnow(contact) then
			local r, g, b = powder.Color(contact)
			local carry = front and VEHICLE_CARRY_FRONT or VEHICLE_CARRY_REAR
			for _ = 1, math.ceil((front and 2 or 3) * f) do
				local out = front and math.Rand(60, 120) * f * across or math.Rand(-30, 30)
				velocity:SetUnpacked(vel.x * carry - by * out, vel.y * carry + bx * out, math.Rand(40, front and 90 or 120) * f)
				spawnPos:SetUnpacked(contact.x + math.Rand(-4, 4), contact.y + math.Rand(-4, 4), contact.z + DEPTH + 2)
				local size = (front and math.Rand(16, 28) or math.Rand(22, 38)) * (0.5 + 0.5 * f)
				local p = powder.Puff(spawnPos, velocity, size, math.Rand(0.8, 1.4), math.floor(110 + 110 * f), DUST_FALL, r, g, b, DUST_MATERIAL)
				if p then
					p:SetAirResistance(VEHICLE_DRAG)
					p:SetStartSize(size * 0.6)
				end
			end

			for _ = 1, math.ceil((front and 3 or 6) * f) do
				local out = front and math.Rand(80, 200) * f * across or math.Rand(-60, 60)
				velocity:SetUnpacked(vel.x * carry - by * out, vel.y * carry + bx * out, math.Rand(120, 260) * f)
				spawnPos:SetUnpacked(contact.x + math.Rand(-4, 4), contact.y + math.Rand(-4, 4), contact.z + DEPTH)
				powder.Clump(spawnPos, velocity, math.Rand(1.5, 3.5), math.Rand(0.8, 1.4), r, g, b)
			end
		end
	end
end

hook.Add("Think", "borealis_snow_powder", function()
	local now = RealTime()
	if now < nextVehicles or next(vehicles) == nil then return end
	nextVehicles = now + VEHICLE_INTERVAL
	if not powder.Active() then return end

	local eye = EyePos()
	for e in pairs(vehicles) do
		if IsValid(e) then
			vehicleSpray(e, eye)
		else
			vehicles[e] = nil
		end
	end
end)
