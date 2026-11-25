local ice = shaderpack.ice or {}
shaderpack.ice = ice

local bspdata = bspdata

local CLASS = "borealis_ice"
local HEIGHT_OFFSET, THICKNESS = 2, 12
local BODY_CELL = 4096
local PHYSICS_RETRY = 1
local SKY_OFFSET, SKY_LENGTH = 4, 32768
local SKY_SAMPLE_INSETS = { 0.5, 0.9 }
local SKY_MIN_OPEN = 0.25
local WATER_SURFACEPROPS = { water = true, slime = true, wade = true }
local SURFACE = "borealis_ice"

physenv.AddSurfaceData([[
"borealis_ice"
{
	"base"	"glass"
	"density"	"917"
	"friction"	"0.1"
	"elasticity"	"0.1"
}
]])

function ice.Winter()
	if tod and tod.loaded_season then return tod.loaded_season == "winter" end
	if tod and tod.GetSeason then return tod.GetSeason() == "winter" end

	local month = tonumber(os.date("%m")) or 0

	return month >= 12 or month <= 2
end

function ice.Freezes(model, name)
	if model ~= 0 then return false end
	local prop = Material(name):GetString("$surfaceprop")

	return not prop or WATER_SURFACEPROPS[prop:lower()] == true
end

local skyTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = {}, filter = function() return false end }

local function reachesSky(x, y, z)
	skyTrace.start:SetUnpacked(x, y, z + SKY_OFFSET)
	skyTrace.endpos:SetUnpacked(x, y, z + SKY_LENGTH)
	local tr = util.TraceLine(skyTrace)
	if tr.StartSolid then return nil end

	return not tr.Hit or tr.HitSky
end

local function skySamples(poly)
	local x, y = 0, 0
	for _, v in ipairs(poly) do
		x, y = x + v.x / #poly, y + v.y / #poly
	end

	local z = poly[1].z
	local open, total = 0, 0
	local function sample(sx, sy)
		local result = reachesSky(sx, sy, z)
		if result ~= nil then
			total = total + 1
			if result then open = open + 1 end
		end
	end

	sample(x, y)
	for _, v in ipairs(poly) do
		for _, inset in ipairs(SKY_SAMPLE_INSETS) do
			sample(x + (v.x - x) * inset, y + (v.y - y) * inset)
		end
	end

	return open, total
end

local function connect(polys)
	local parent, owners = {}, {}
	local function find(i)
		while parent[i] ~= i do
			parent[i] = parent[parent[i]]
			i = parent[i]
		end

		return i
	end

	for i, poly in ipairs(polys) do
		parent[i] = i
		for _, v in ipairs(poly) do
			local key = math.floor(v.x + 0.5) .. "," .. math.floor(v.y + 0.5) .. "," .. math.floor(v.z + 0.5)
			if owners[key] then
				parent[find(i)] = find(owners[key])
			else
				owners[key] = i
			end
		end
	end

	return find
end

local function faceKey(poly)
	local v = poly[1]
	local x, y = 0, 0
	for _, p in ipairs(poly) do
		x, y = x + p.x, y + p.y
	end

	return string.format("%.1f,%.1f,%.1f", x, y, v.z)
end

local frozenFaces

local function findFrozenFaces()
	local polys = {}
	for _, face in ipairs(bspdata.WaterFaces()) do
		if ice.Freezes(face.model, face.name) then
			polys[#polys + 1] = face.poly
		end
	end

	local find = connect(polys)
	local opens, totals = {}, {}
	for i, poly in ipairs(polys) do
		local root = find(i)
		local open, total = skySamples(poly)
		opens[root], totals[root] = (opens[root] or 0) + open, (totals[root] or 0) + total
	end

	frozenFaces = {}
	for i, poly in ipairs(polys) do
		local root = find(i)
		frozenFaces[faceKey(poly)] = totals[root] > 0 and opens[root] / totals[root] >= SKY_MIN_OPEN
	end
end

function ice.FaceFreezes(face)
	if not ice.Freezes(face.model, face.name) then return false end
	if not frozenFaces then findFrozenFaces() end

	return frozenFaces[faceKey(face.poly)] == true
end

local bodies

function ice.Bodies()
	if bodies then return bodies end

	local polys = {}
	for _, face in ipairs(bspdata.WaterFaces()) do
		if ice.FaceFreezes(face) then
			polys[#polys + 1] = face.poly
		end
	end

	local find = connect(polys)
	bodies = {}
	local bodyOf = {}
	for i, poly in ipairs(polys) do
		local hull = {}
		local sumX, sumY = 0, 0
		for _, v in ipairs(poly) do
			hull[#hull + 1] = Vector(v.x, v.y, v.z + HEIGHT_OFFSET)
			hull[#hull + 1] = Vector(v.x, v.y, v.z - THICKNESS)
			sumX, sumY = sumX + v.x, sumY + v.y
		end

		local key = find(i) .. ":" .. math.floor(sumX / #poly / BODY_CELL) .. ":" .. math.floor(sumY / #poly / BODY_CELL)
		local body = bodyOf[key]
		if not body then
			body = {}
			bodyOf[key] = body
			bodies[#bodies + 1] = body
		end

		body[#body + 1] = hull
	end

	return bodies
end

local ENT = {
	Type = "anim",
	Base = "base_anim",
	PrintName = "Ice",
	Spawnable = false,
	DoNotDuplicate = true,
	RenderGroup = RENDERGROUP_OTHER,
}

function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "Body")
end

function ENT:Initialize()
	local hulls = ice.Bodies()[self:GetBody()]
	if not hulls then
		if SERVER then self:Remove() end

		return
	end

	self:PhysicsInitMultiConvex(hulls, util.GetSurfaceIndex(SURFACE) >= 0 and SURFACE or "ice")
	self:SetSolid(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_NONE)
	self:EnableCustomCollisions(true)
	self:DrawShadow(false)

	local phys = self:GetPhysicsObject()
	if IsValid(phys) then
		phys:EnableMotion(false)
	end
end

if CLIENT then
	function ENT:Think()
		if not IsValid(self:GetPhysicsObject()) then
			self:Initialize()
		end

		self:SetNextClientThink(CurTime() + PHYSICS_RETRY)

		return true
	end
end

function ENT:Draw() end

function ENT:UpdateTransmitState()
	return TRANSMIT_ALWAYS
end

scripted_ents.Register(ENT, CLASS)

local function isIce(e)
	return IsValid(e) and e:GetClass() == CLASS
end

hook.Add("PhysgunPickup", "borealis_ice", function(_, e)
	if isIce(e) then return false end
end)

hook.Add("GravGunPickupAllowed", "borealis_ice", function(_, e)
	if isIce(e) then return false end
end)

hook.Add("CanTool", "borealis_ice", function(_, tr)
	if isIce(tr.Entity) then return false end
end)

hook.Add("CanProperty", "borealis_ice", function(_, _, e)
	if isIce(e) then return false end
end)

if CLIENT then return end

local function spawn()
	for _, e in ipairs(ents.FindByClass(CLASS)) do
		e:Remove()
	end

	if not ice.Winter() then return end

	for i in ipairs(ice.Bodies()) do
		local e = ents.Create(CLASS)
		e:SetBody(i)
		e:SetPos(vector_origin)
		e:SetAngles(angle_zero)
		e:Spawn()
	end
end

ice.Spawn = spawn

hook.Add("InitPostEntity", "borealis_ice", spawn)
hook.Add("PostCleanupMap", "borealis_ice", spawn)
