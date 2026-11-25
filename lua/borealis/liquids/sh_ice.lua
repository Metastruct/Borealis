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
local SURFACE, GRIP_SURFACE = "borealis_ice", "borealis_ice_grip"
local SLIPPERY = CreateConVar("sv_borealis_ice_slippery", "1", bit.bor(FCVAR_REPLICATED, FCVAR_ARCHIVE, FCVAR_NOTIFY), "0 makes frozen water as grippy as normal ground")

physenv.AddSurfaceData([[
"borealis_ice"
{
	"base"	"glass"
	"density"	"917"
	"friction"	"0.1"
	"elasticity"	"0.1"
}
"borealis_ice_grip"
{
	"base"	"glass"
	"density"	"917"
	"friction"	"0.8"
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

	local surface = SLIPPERY:GetBool() and SURFACE or GRIP_SURFACE
	self:PhysicsInitMultiConvex(hulls, util.GetSurfaceIndex(surface) >= 0 and surface or "ice")
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

	local LIGHT_CELL, LIGHT_LIFT, MAX_VERTS = 256, 4, 65535
	local LIGHT_INWARD = { 0, 0.1, 0.25, 0.5, 1 }
	local UP = Vector(0, 0, 1)
	local lightPos = Vector()

	local function tessellationCount(verts, cell)
		local count = 0
		for i = 1, #verts, 3 do
			local a, b, c = verts[i], verts[i + 1], verts[i + 2]
			local n = math.max(1, math.ceil(math.max(a:Distance(b), b:Distance(c), c:Distance(a)) / cell))
			count = count + n * n * 3
		end

		return count
	end

	local function bakedLight(v, centre, lightCache)
		local key = math.Round(v.x) .. "," .. math.Round(v.y)
		local light = lightCache[key]
		if light then return light end

		for _, f in ipairs(LIGHT_INWARD) do
			lightPos:SetUnpacked(v.x + (centre.x - v.x) * f, v.y + (centre.y - v.y) * f, v.z + LIGHT_LIFT)
			if bit.band(util.PointContents(lightPos), CONTENTS_SOLID) == 0 then break end
		end

		local l, d = render.ComputeLighting(lightPos, UP), render.ComputeDynamicLighting(lightPos, UP)
		light = {
			math.Clamp(math.floor((l.x - d.x) * 127.5), 0, 255),
			math.Clamp(math.floor((l.y - d.y) * 127.5), 0, 255),
			math.Clamp(math.floor((l.z - d.z) * 127.5), 0, 255),
		}
		lightCache[key] = light

		return light
	end

	function ice.Bake(verts)
		local cell = LIGHT_CELL
		local count = tessellationCount(verts, cell)
		while count > math.max(MAX_VERTS, #verts) do
			cell = cell * math.sqrt(count / MAX_VERTS) * 1.05
			count = tessellationCount(verts, cell)
		end

		local out, lights, lightCache = {}, {}, {}
		for i = 1, #verts, 3 do
			local a, b, c = verts[i], verts[i + 1], verts[i + 2]
			local n = math.max(1, math.ceil(math.max(a:Distance(b), b:Distance(c), c:Distance(a)) / cell))
			local ab, ac = (b - a) / n, (c - a) / n
			local centre = (a + b + c) / 3
			local function addVertex(u, w)
				local v = a + ab * u + ac * w
				out[#out + 1] = v
				lights[#lights + 1] = bakedLight(v, centre, lightCache)
			end

			for u = 0, n - 1 do
				for w = 0, n - 1 - u do
					addVertex(u, w)
					addVertex(u + 1, w)
					addVertex(u, w + 1)
					if u + w < n - 1 then
						addVertex(u + 1, w)
						addVertex(u + 1, w + 1)
						addVertex(u, w + 1)
					end
				end
			end
		end

		return out, lights
	end

	local CHEAP_AMBIENT = 0.45
	local CHEAP_MAT = CreateMaterial("borealis_ice_cheap", "VertexLitGeneric", {
		["$basetexture"] = "glass/glasswindowbreak070a",
		["$color2"] = "[0.78 0.8 0.83]",
		["$envmap"] = "env_cubemap",
		["$envmapmask"] = "glass/glasswindowbreak070a_mask",
		["$envmaptint"] = "[0.08 0.08 0.08]",
		["$translucent"] = 1,
		["$nocull"] = 1,
		["$vertexcolor"] = 1,
	})
	local cheapMeshes, cheapLight

	local function buildCheapMeshes()
		local polys = {}
		for _, face in ipairs(bspdata.WaterFaces()) do
			if ice.FaceFreezes(face) then
				polys[#polys + 1] = face.poly
			end
		end

		cheapMeshes = {}
		if #polys == 0 then return end

		local find = connect(polys)
		local groups = {}
		for i, poly in ipairs(polys) do
			local root = find(i)
			local g = groups[root]
			if not g then
				g = { verts = {}, minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge }
				groups[root] = g
			end

			for n = 2, #poly - 1 do
				g.verts[#g.verts + 1] = poly[1]
				g.verts[#g.verts + 1] = poly[n]
				g.verts[#g.verts + 1] = poly[n + 1]
			end

			for _, v in ipairs(poly) do
				g.minX, g.minY = math.min(g.minX, v.x), math.min(g.minY, v.y)
				g.maxX, g.maxY = math.max(g.maxX, v.x), math.max(g.maxY, v.y)
			end
		end

		local brightest = { 1, 1, 1 }
		for _, g in pairs(groups) do
			g.verts, g.lights = ice.Bake(g.verts)
			for _, light in ipairs(g.lights) do
				if light[1] + light[2] + light[3] > brightest[1] + brightest[2] + brightest[3] then
					brightest = light
				end
			end
		end

		local peak = math.max(brightest[1], brightest[2], brightest[3])
		cheapLight = Vector(brightest[1], brightest[2], brightest[3]) / 127.5
		local scale = (1 - CHEAP_AMBIENT) * 255 / peak
		local ambient = CHEAP_AMBIENT * 255
		for _, g in pairs(groups) do
			local size = math.max(g.maxX - g.minX, g.maxY - g.minY, 1)
			local m = Mesh(CHEAP_MAT)
			mesh.Begin(m, MATERIAL_TRIANGLES, #g.verts / 3)
			for i, v in ipairs(g.verts) do
				local light = g.lights[i]
				local shade = ambient + math.max(light[1], light[2], light[3]) * scale
				mesh.Position(Vector(v.x, v.y, v.z + HEIGHT_OFFSET))
				mesh.Normal(UP)
				mesh.TexCoord(0, (v.y - g.minY) / size, (v.x - g.minX) / size)
				mesh.Color(shade, shade, shade, 255)
				mesh.AdvanceVertex()
			end
			mesh.End()
			cheapMeshes[#cheapMeshes + 1] = m
		end
	end

	hook.Add("PostDrawTranslucentRenderables", "borealis_ice_cheap", function(depth, skybox, skybox3d)
		if depth or skybox or skybox3d then return end

		local rt = render.GetRenderTarget()
		if rt and rt:GetName():lower():find("_rt_water", 1, true) then return end

		local water = shaderpack.surfacewater
		if water and water.active or not ice.Winter() then return end

		if not cheapMeshes then buildCheapMeshes() end
		if #cheapMeshes == 0 then return end

		local foliage = shaderpack.foliage
		local gain = 2 * (foliage and foliage.WorldLightScale and foliage.WorldLightScale() or 1)
		render.SuppressEngineLighting(true)
		render.ResetModelLighting(cheapLight.x * gain, cheapLight.y * gain, cheapLight.z * gain)
		render.SetMaterial(CHEAP_MAT)
		for _, m in ipairs(cheapMeshes) do
			m:Draw()
		end
		render.SuppressEngineLighting(false)
	end)
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
cvars.AddChangeCallback("sv_borealis_ice_slippery", spawn, "borealis_ice")
