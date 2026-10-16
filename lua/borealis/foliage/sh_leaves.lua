local TEXTURES = { "shaderpack/leaves/leaf1", "shaderpack/leaves/leaf2", "shaderpack/leaves/leaf3" }

if SERVER then
	local files = {}
	for i, tex in ipairs(TEXTURES) do
		files[i] = "materials/" .. tex .. ".vtf"
	end

	shaderpack.AddResources({}, files)

	return
end

local leaves = shaderpack.leaves or {}
shaderpack.leaves = leaves
local depthslices, wind = shaderpack.depthslices, shaderpack.wind

local ENABLED = CreateClientConVar("cl_draw_leaves", "1", true, false, "draw falling and fallen leaves in autumn")
local AUTUMN = os.date("%m") == "10"

local LEAF_COLORS = {
	Color(214, 104, 28),
	Color(176, 52, 24),
	Color(222, 164, 40),
	Color(122, 70, 34),
	Color(198, 132, 36),
}

local CELL = 192
local RADIUS = 1600
local CLUSTER_CHANCE = 0.35
local CELLS_PER_TICK = 12
local FALL_INTERVAL = 0.6
local FALL_MIN_SUN = -6
local FALL_LIFE = 30
local LANDED_LIFE = 40
local FADE = 3
local DRIFT = 100
local SWAY = 35
local ORDER = 0
local LIQUID = bit.bor(CONTENTS_WATER, CONTENTS_SLIME)

local leafMats = {}

local function stop()
	hook.Remove("Think", "ms_leaves")
	depthslices.RemoveEffect("ms_leaves")

	for _, cell in pairs(leaves.cells or {}) do
		for _, leaf in ipairs(cell.leaves or {}) do
			leaf.p:SetDieTime(0)
		end
	end

	if leaves.emitter and leaves.emitter:IsValid() then
		leaves.emitter:Finish()
	end

	leaves.emitter, leaves.cells = nil, nil
end

stop()

local function lcg(seed)
	local rng = seed % 2147483648

	return function()
		rng = (rng * 1103515245 + 12345) % 2147483648

		return rng / 2147483648
	end
end

local function leafLook(p, rand)
	local size = 4 + rand() * 3
	local col = LEAF_COLORS[math.floor(rand() * #LEAF_COLORS) + 1]
	local k = 0.8 + rand() * 0.2
	p:SetStartSize(size)
	p:SetEndSize(size)

	return { p = p, size = size, r = col.r * k, g = col.g * k, b = col.b * k }
end

local function lightAt(pos, normal)
	local scale = shaderpack.foliage.WorldLightScale()
	local l = render.ComputeLighting(pos + normal * 4, normal)
	local amb = render.GetAmbientLightColor()

	return math.min(1, (l.x * scale + amb.x * 0.5) ^ 0.4545),
		math.min(1, (l.y * scale + amb.y * 0.5) ^ 0.4545),
		math.min(1, (l.z * scale + amb.z * 0.5) ^ 0.4545)
end

local function shade(list, pos, normal)
	local r, g, b = lightAt(pos, normal)
	for _, leaf in ipairs(list) do
		leaf.p:SetColor(leaf.r * r, leaf.g * g, leaf.b * b)
	end
end

local function rest(p, pos, normal, roll)
	p:SetPos(pos + normal * 0.5)
	p:SetAngles(normal:Angle() + Angle(0, 0, roll))
	p:SetVelocity(vector_origin)
	p:SetAngleVelocity(Angle(0, 0, 0))
	p:SetGravity(vector_origin)
end

local groundTrace = { mask = MASK_SOLID_BRUSHONLY }

local function groundAt(x, y, z)
	for _, lift in ipairs({ 1024, 128 }) do
		groundTrace.start = Vector(x, y, z + lift)
		groundTrace.endpos = Vector(x, y, z - 3000)
		local tr = util.TraceLine(groundTrace)
		if not tr.StartSolid then
			if tr.Hit and not tr.HitSky and tr.MatType == MAT_GRASS and tr.HitNormal.z > 0.7
				and bit.band(util.PointContents(tr.HitPos + vector_up * 2), LIQUID) == 0 then
				return tr.HitPos, tr.HitNormal
			end

			return
		end
	end
end

local function spawnCell(cell, z)
	local rand = lcg(cell.cx * 73856093 + cell.cy * 19349663)
	if rand() > CLUSTER_CHANCE then return end

	local x0, y0 = (cell.cx + rand()) * CELL, (cell.cy + rand()) * CELL
	local list = {}
	for _ = 1, 2 + math.floor(rand() * 5) do
		local pos, normal = groundAt(x0 + (rand() - 0.5) * 80, y0 + (rand() - 0.5) * 80, z)
		local shape, roll = math.floor(rand() * #leafMats) + 1, rand() * 360
		if pos then
			local p = leaves.emitter:Add(leafMats[shape], pos)
			if p then
				p:SetDieTime(1e9)
				list[#list + 1] = leafLook(p, rand)
				rest(p, pos, normal, roll)
				cell.pos, cell.normal = cell.pos or pos, cell.normal or normal
			end
		end
	end

	if #list == 0 then return end
	cell.leaves = list
	shade(list, cell.pos, cell.normal)
end

local function land(leaf, pos, normal)
	if normal.z < 0.6 then return end
	local p = leaf.p
	p:SetCollide(false)
	rest(p, pos, normal, math.Rand(0, 360))
	shade({ leaf }, pos, normal)
	p:SetDieTime(p:GetLifeTime() + LANDED_LIFE)
	p:SetThinkFunction(function(self)
		local size = leaf.size * math.Clamp((self:GetDieTime() - self:GetLifeTime()) / FADE, 0, 1)
		self:SetStartSize(size)
		self:SetEndSize(size)
		self:SetNextThink(CurTime() + 0.1)
	end)
	p:SetNextThink(CurTime() + 0.1)
end

local skyTrace = { mask = MASK_SOLID_BRUSHONLY }
local waterTrace = { mask = MASK_WATER }

local function waterSurface(pos)
	waterTrace.start = pos + vector_up * 32
	waterTrace.endpos = pos
	local tr = util.TraceLine(waterTrace)
	if tr.Hit and not tr.StartSolid then return tr.HitPos end
end

local function dropLeaf()
	local eye = EyePos()
	local a, d = math.Rand(0, math.pi * 2), math.Rand(100, 900)
	local pos = Vector(eye.x + math.cos(a) * d, eye.y + math.sin(a) * d, eye.z + math.Rand(120, 420))
	if bit.band(util.PointContents(pos), bit.bor(CONTENTS_SOLID, LIQUID)) ~= 0 then return end

	skyTrace.start = pos
	skyTrace.endpos = pos + Vector(0, 0, 16384)
	if not util.TraceLine(skyTrace).HitSky then return end

	local p = leaves.emitter:Add(leafMats[math.random(#leafMats)], pos)
	if not p then return end

	local leaf = leafLook(p, math.random)
	shade({ leaf }, pos, vector_up)
	p:SetDieTime(FALL_LIFE)
	p:SetAngles(AngleRand())
	p:SetAngleVelocity(Angle(math.Rand(-140, 140), math.Rand(-140, 140), math.Rand(-140, 140)))
	p:SetCollide(true)
	p:SetBounce(0)
	p:SetCollideCallback(function(_, hit, normal)
		land(leaf, hit, normal)
	end)

	local phase, sway = math.Rand(0, math.pi * 2), math.Rand(1.5, 3)
	p:SetThinkFunction(function(self)
		local at = self:GetPos()
		if bit.band(util.PointContents(at), LIQUID) ~= 0 then
			local top = waterSurface(at)
			if top then
				land(leaf, top, vector_up)

				return
			end
		end

		local t = CurTime() * sway + phase
		local drift = DRIFT * wind.Strength()
		self:SetVelocity(Vector(wind.X * drift + math.sin(t) * SWAY, wind.Y * drift + math.cos(t * 0.7) * SWAY, -28 - math.sin(t * 2) * 10))
		self:SetNextThink(CurTime() + 0.1)
	end)

	p:SetNextThink(CurTime())
end

local function kill(list)
	if not list then return end
	for _, leaf in ipairs(list) do
		leaf.p:SetDieTime(0)
	end
end

local nextUpdate, nextFall, nextShade = 0, 0, 0

local function think()
	local now = RealTime()
	if now > nextFall then
		nextFall = now + FALL_INTERVAL * math.Rand(0.5, 1.5)
		local rain = tod and tod.rain and tod.rain.amount or 0
		if shaderpack.Elevation(shaderpack.SunDir()) >= FALL_MIN_SUN and rain <= 0 then
			dropLeaf()
		end
	end

	if now > nextShade then
		nextShade = now + 1
		for _, cell in pairs(leaves.cells) do
			if cell.leaves then
				shade(cell.leaves, cell.pos, cell.normal)
			end
		end
	end

	if now < nextUpdate then return end
	nextUpdate = now + 0.25

	local eye = EyePos()
	local cells = leaves.cells
	local n = math.ceil(RADIUS / CELL)
	local ecx, ecy = math.floor(eye.x / CELL), math.floor(eye.y / CELL)
	local budget = CELLS_PER_TICK
	for cy = ecy - n, ecy + n do
		for cx = ecx - n, ecx + n do
			local key = cx * 65536 + cy
			if cells[key] == nil and budget > 0 then
				local dx, dy = (cx + 0.5) * CELL - eye.x, (cy + 0.5) * CELL - eye.y
				if dx * dx + dy * dy < RADIUS * RADIUS then
					cells[key] = { cx = cx, cy = cy }
					spawnCell(cells[key], eye.z)
					budget = budget - 1
				end
			end
		end
	end

	local limit = (RADIUS + CELL * 2) ^ 2
	for key, cell in pairs(cells) do
		local dx, dy = (cell.cx + 0.5) * CELL - eye.x, (cell.cy + 0.5) * CELL - eye.y
		if dx * dx + dy * dy > limit then
			kill(cell.leaves)
			cells[key] = nil
		end
	end

	leaves.emitter:SetPos(eye)
end

local function drawLeaves()
	render.OverrideDepthEnable(true, true)
	leaves.emitter:Draw()
	render.OverrideDepthEnable(false, false)
end

local function start()
	stop()
	if not AUTUMN then return end
	if not file.Exists("materials/" .. TEXTURES[1] .. ".vtf", "GAME") then return end

	for shape, tex in ipairs(TEXTURES) do
		leafMats[shape] = leafMats[shape] or CreateMaterial("ms_leaf" .. shape, "UnlitGeneric", {
			["$basetexture"] = tex,
			["$vertexcolor"] = 1,
			["$alphatest"] = 1,
			["$nocull"] = 1,
		})
	end

	leaves.emitter = ParticleEmitter(EyePos(), true)
	leaves.emitter:SetNoDraw(true)
	leaves.cells = {}
	hook.Add("Think", "ms_leaves", think)
	depthslices.AddEffect("ms_leaves", ORDER, drawLeaves)
end

shaderpack.AfterWorld("ms_leaves", shaderpack.Toggle("ms_leaves", ENABLED, {}, start, stop))
