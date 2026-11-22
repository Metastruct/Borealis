local snow = shaderpack.snow
local impacts = snow.impacts or {}
snow.impacts = impacts

local DEPTH = snow.DEPTH
local MIN_NZ = 0.5
local MIN_DESCENT = 0.05
local GROOVE_RADIUS, GROOVE_DEPTH, GROOVE_STEP, GROOVE_MAX = 2.5, 0.8, 2, 40
local CRATER_SCALE, CRATER_MIN, CRATER_MAX = 0.3, 24, 128
local UP = Vector(0, 0, 1)

local groundRes = {}
local groundTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = groundRes }
local sprayPos, burstDir = Vector(), Vector()

function impacts.Bullet(hit, dir)
	if not snow.Running() or -dir.z < MIN_DESCENT or not snow.footsteps.OnSnow(hit) then return end

	local length = math.min(DEPTH / -dir.z, GROOVE_MAX)
	local ex, ey = hit.x - dir.x * length, hit.y - dir.y * length
	local span = math.sqrt((hit.x - ex) ^ 2 + (hit.y - ey) ^ 2)
	local steps = math.max(math.ceil(span / GROOVE_STEP), 1)
	for k = 0, steps do
		local f = k / steps
		snow.trails.Stamp(ex + (hit.x - ex) * f, ey + (hit.y - ey) * f, GROOVE_RADIUS, GROOVE_DEPTH * (0.4 + 0.6 * f))
	end

	if snow.powder.Active() then
		sprayPos:SetUnpacked(ex, ey, hit.z + DEPTH)
		burstDir:SetUnpacked(-dir.x * 0.4, -dir.y * 0.4, 1)
		snow.powder.Spray(sprayPos, burstDir, math.random(4, 6), 45, 7, 0.9, 140)
	end
end

function impacts.Blast(pos, radius)
	if not snow.Running() then return end

	groundTrace.start:SetUnpacked(pos.x, pos.y, pos.z + 8)
	groundTrace.endpos:SetUnpacked(pos.x, pos.y, pos.z - math.max(radius * 0.5, 32))
	util.TraceLine(groundTrace)
	if not groundRes.Hit or groundRes.StartSolid or groundRes.HitNormal.z < MIN_NZ then return end

	local ground = groundRes.HitPos
	if not snow.footsteps.OnSnow(ground) then return end

	local height = math.Clamp((pos.z - ground.z) / math.max(radius, 1), 0, 1)
	local r = math.Clamp(radius * CRATER_SCALE, CRATER_MIN, CRATER_MAX) * (1 - height)
	if r < GROOVE_RADIUS then return end

	snow.trails.Stamp(ground.x, ground.y, r, 1)

	if snow.powder.Active() then
		sprayPos:SetUnpacked(ground.x, ground.y, ground.z + DEPTH)
		snow.powder.Spray(sprayPos, UP, math.Clamp(math.floor(r * 0.5), 12, 48), 220, r * 0.6, 2.2, 170)
	end
end

net.Receive(snow.IMPACT_NET, function()
	if net.ReadBool() then
		impacts.Blast(net.ReadVector(), net.ReadUInt(10))
	else
		impacts.Bullet(net.ReadVector(), net.ReadNormal())
	end
end)

hook.Add("PostEntityFireBullets", "borealis_snow_impacts", function(ent, data)
	if ent ~= LocalPlayer() or not IsFirstTimePredicted() then return end

	local tr = data.Trace
	if not tr or not tr.HitWorld or tr.HitSky or tr.HitNormal.z < MIN_NZ then return end

	impacts.Bullet(tr.HitPos, tr.Normal)
end)
