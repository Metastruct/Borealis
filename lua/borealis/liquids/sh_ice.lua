local ice = shaderpack.ice or {}
shaderpack.ice = ice

local bspdata = shaderpack.bspdata

local CLASS = "borealis_ice"
local LIFT, THICKNESS = 2, 12
local WATER_SURFACEPROPS = { water = true, slime = true, wade = true }

function ice.Winter()
	if tod and tod.GetSeason then return tod.GetSeason() == "winter" end

	local month = tonumber(os.date("%m")) or 0

	return month >= 12 or month <= 2
end

function ice.Freezes(model, name)
	if model ~= 0 then return false end
	local prop = Material(name):GetString("$surfaceprop")

	return not prop or WATER_SURFACEPROPS[prop:lower()] == true
end

local function convexes()
	local list = {}
	for _, face in ipairs(bspdata.WaterFaces()) do
		if ice.Freezes(face.model, face.name) then
			local hull = {}
			for _, v in ipairs(face.poly) do
				hull[#hull + 1] = Vector(v.x, v.y, v.z + LIFT)
				hull[#hull + 1] = Vector(v.x, v.y, v.z - THICKNESS)
			end
			list[#list + 1] = hull
		end
	end

	return list
end

local ENT = {
	Type = "anim",
	Base = "base_anim",
	PrintName = "Ice",
	Spawnable = false,
	RenderGroup = RENDERGROUP_OTHER,
}

function ENT:Initialize()
	local hulls = convexes()
	if #hulls == 0 then
		if SERVER then self:Remove() end

		return
	end

	self:PhysicsInitMultiConvex(hulls)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_NONE)
	self:EnableCustomCollisions(true)
	self:DrawShadow(false)

	local phys = self:GetPhysicsObject()
	if IsValid(phys) then
		phys:EnableMotion(false)
		phys:SetMaterial("ice")
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

	local e = ents.Create(CLASS)
	e:SetPos(vector_origin)
	e:SetAngles(angle_zero)
	e:Spawn()
end

ice.Spawn = spawn

hook.Add("InitPostEntity", "borealis_ice", spawn)
hook.Add("PostCleanupMap", "borealis_ice", spawn)
