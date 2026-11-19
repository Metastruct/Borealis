local snow = shaderpack.snow
local heightfield = snow.heightfield or {}
snow.heightfield = heightfield

local bspdata = bspdata

local CHUNK, DEPTH = snow.CHUNK, snow.DEPTH
local CELL, MARGIN = 16, 6
local STEP = 24
local MIN_RISE = 0.5
local STEP_MIN = 1
local CLEARANCE = 8
local SKY_DISTANCE, RAY_HEIGHT = snow.SKY_DISTANCE, snow.RAY_HEIGHT
local SLOPE_WIDTH = 48
local EDGE_MIN_HEIGHT = 0.3
local DRIFT_PER_WALL_HEIGHT, DRIFT_MAX = 0.2, 24
local DRIFT_WIDTH_PER_HEIGHT, DRIFT_MIN_WIDTH = 3, 32
local WALL_INSET, WALL_MAX_NZ = 2, 0.5
local WALL_CHECK_HEIGHT = DRIFT_MAX / DRIFT_PER_WALL_HEIGHT
local CORNER_SHARE = 0.5
local RISE_SINK = 0.5
local REPOSE = 0.8
local SHED_START, SHED_END = 0.9, 1.6
local RELAX_PASSES, RELAX_RATE = 4, 0.5
local DIAGONAL = math.sqrt(2)
local WALL_FIELDS = { "wall1", "wall2", "wall3", "wall4" }
local WALL_EDGES = { "wallEdge1", "wallEdge2", "wallEdge3", "wallEdge4" }
local DIRS = {
	{ 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
	{ 1, 1, DIAGONAL, 1, 3 }, { 1, -1, DIAGONAL, 1, 4 }, { -1, 1, DIAGONAL, 2, 3 }, { -1, -1, DIAGONAL, 2, 4 },
}

local KIND_SNOW, KIND_SHELTERED, KIND_WATER = 1, 2, 3

heightfield.CELL, heightfield.MARGIN = CELL, MARGIN
heightfield.STEP, heightfield.STEP_MIN, heightfield.MIN_RISE = STEP, STEP_MIN, MIN_RISE
heightfield.EDGE_MIN_HEIGHT, heightfield.SLOPE_WIDTH, heightfield.DRIFT_MAX = EDGE_MIN_HEIGHT, SLOPE_WIDTH, DRIFT_MAX
heightfield.KIND_SNOW, heightfield.KIND_SHELTERED, heightfield.KIND_WATER = KIND_SNOW, KIND_SHELTERED, KIND_WATER

local res = {}
local trace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = res }

local function noYield() end

local function gatherFloors(triGrid, data, yield)
	local n, gx0, gy0, columns = data.n, data.gx0, data.gy0, data.columns
	local x0, y0 = gx0 * CELL, gy0 * CELL
	local x1, y1 = x0 + n * CELL, y0 + n * CELL
	for _, t in ipairs(bspdata.Candidates(triGrid, x0, y0, x1, y1)) do
		if t.vn then
			local i0 = math.max(math.ceil(t[13] / CELL - 0.5 - gx0), 0)
			local i1 = math.min(math.floor(t[15] / CELL - 0.5 - gx0), n - 1)
			local j0 = math.max(math.ceil(t[14] / CELL - 0.5 - gy0), 0)
			local j1 = math.min(math.floor(t[16] / CELL - 0.5 - gy0), n - 1)
			for j = j0, j1 do
				local y = (gy0 + j + 0.5) * CELL
				for i = i0, i1 do
					local x = (gx0 + i + 0.5) * CELL
					local z = bspdata.Sample(t, x, y)
					if z and (not t.sky or bspdata.BeyondWorld(x, y, z)) then
						local list = columns[j * n + i]
						list[#list + 1] = { z, t.nx, t.ny, t.nz }
					end
				end
			end

			yield()
		end
	end
end

local function buildSpans(data, yield)
	local n, gx0, gy0, columns, spans = data.n, data.gx0, data.gy0, data.columns, data.spans
	for j = 0, n - 1 do
		local y = (gy0 + j + 0.5) * CELL
		for i = 0, n - 1 do
			local x = (gx0 + i + 0.5) * CELL
			local floors = columns[j * n + i]
			table.sort(floors, function(a, b) return a[1] > b[1] end)
			local list = {}
			local last = math.huge
			for _, f in ipairs(floors) do
				local floor = f[1]
				if last - floor >= 1 then
					last = floor
					trace.start:SetUnpacked(x, y, floor + 1)
					trace.endpos:SetUnpacked(x, y, floor + SKY_DISTANCE)
					bspdata.TraceLine(trace)
					if not res.StartSolid then
						local ceil = res.Hit and res.HitPos.z or floor + SKY_DISTANCE
						if ceil - floor >= CLEARANCE then
							local kind = (not res.Hit or res.HitSky) and KIND_SNOW or KIND_SHELTERED
							if snow.Submerged(x, y, floor) then kind = KIND_WATER end

							local s = { x = x, y = y, i = i, j = j, floor = floor, ceil = ceil, nx = f[2], ny = f[3], nz = math.max(f[4], 0.3), kind = kind, links = {}, drops = {}, delta = 0 }
							list[#list + 1] = s
							spans[#spans + 1] = s
						end
					end
				end
			end

			columns[j * n + i] = list
			yield()
		end
	end
end

local function link(a, b)
	local best, bestDz
	for _, s in ipairs(b) do
		local dz = math.abs(s.floor - a.floor)
		if dz <= STEP and math.min(a.ceil, s.ceil) - math.max(a.floor, s.floor) >= CLEARANCE and (not best or dz < bestDz) then
			best, bestDz = s, dz
		end
	end

	return best
end

local function wallHeight(s, dx, dy)
	local z = s.floor + RAY_HEIGHT
	trace.start:SetUnpacked(s.x, s.y, z)
	trace.endpos:SetUnpacked(s.x + dx * CELL, s.y + dy * CELL, z)
	bspdata.TraceLine(trace)
	if not res.Hit or res.StartSolid or res.HitSky or res.HitNoDraw or math.abs(res.HitNormal.z) >= WALL_MAX_NZ then return end
	if (res.HitTexture or ""):lower():find("^tools/") then return end

	local n, hit = res.HitNormal, res.HitPos
	local distance = res.Fraction * CELL * math.sqrt(dx * dx + dy * dy)
	local wx, wy = hit.x - n.x * WALL_INSET, hit.y - n.y * WALL_INSET
	trace.start:SetUnpacked(wx, wy, s.floor + WALL_CHECK_HEIGHT)
	trace.endpos:SetUnpacked(wx, wy, s.floor)
	bspdata.TraceLine(trace)

	return res.StartSolid and WALL_CHECK_HEIGHT or res.Hit and res.HitPos.z - s.floor or 0, distance
end

local function driftFor(height)
	if not height or height <= STEP then return 0, DRIFT_MIN_WIDTH end

	local drift = math.min(height * DRIFT_PER_WALL_HEIGHT, DRIFT_MAX)

	return drift, math.max(drift * DRIFT_WIDTH_PER_HEIGHT, DRIFT_MIN_WIDTH)
end

local function planeAt(s, dx, dy)
	return s.floor - (s.nx * dx + s.ny * dy) / s.nz
end

local function stepUp(s, l, dx, dy)
	dx, dy = dx * CELL, dy * CELL

	return l.floor - planeAt(s, dx, dy) > STEP_MIN and planeAt(l, -dx, -dy) - s.floor > STEP_MIN
end

local function dropTarget(s, b)
	local best
	for _, t in ipairs(b) do
		if t.floor < s.floor - STEP and t.ceil > s.floor + CLEARANCE and (not best or t.floor > best.floor) then best = t end
	end

	return best
end

local function linkSpans(data, yield)
	local n, columns = data.n, data.columns
	local fadeSeeds, wallSeeds, riseSeeds = {}, { {}, {}, {}, {} }, {}
	for _, s in ipairs(data.spans) do
		local links = s.links
		for k, dir in ipairs(DIRS) do
			local i, j = s.i + dir[1], s.j + dir[2]
			local b = i >= 0 and i < n and j >= 0 and j < n and columns[j * n + i]
			if b and (k <= 4 or links[dir[4]] and links[dir[5]]) then
				links[k] = link(s, b)
			end

			if s.kind == KIND_SNOW and k <= 4 and b then
				local l = links[k]
				local edge = { dx = dir[1], dy = dir[2] }
				if l then
					if l.kind ~= KIND_SNOW then
						fadeSeeds[#fadeSeeds + 1] = { s, CELL * 0.5, edge }
					elseif stepUp(s, l, dir[1], dir[2]) then
						edge.upper, edge.floor, edge.top = l, l.floor, l.floor
						riseSeeds[#riseSeeds + 1] = { s, CELL * 0.5, edge }
					end
				else
					s.drops[k] = dropTarget(s, b)
					local height, distance = wallHeight(s, dir[1], dir[2])
					if driftFor(height) > 0 then
						edge.height = height
						local seeds = wallSeeds[k]
						seeds[#seeds + 1] = { s, distance, edge }
					else
						fadeSeeds[#fadeSeeds + 1] = { s, CELL * 0.5, edge }
					end
				end
			end
		end

		yield()
	end

	return fadeSeeds, wallSeeds, riseSeeds
end

local function heapPush(h, item, key)
	local i = #h + 1
	h[i] = { key, item }
	while i > 1 do
		local p = math.floor(i / 2)
		if h[p][1] <= h[i][1] then break end
		h[p], h[i] = h[i], h[p]
		i = p
	end
end

local function heapPop(h)
	local top = h[1]
	local last = table.remove(h)
	if #h > 0 then
		h[1] = last
		local i = 1
		while true do
			local l, r, m = i * 2, i * 2 + 1, i
			if h[l] and h[l][1] < h[m][1] then m = l end
			if h[r] and h[r][1] < h[m][1] then m = r end
			if m == i then break end
			h[m], h[i] = h[i], h[m]
			i = m
		end
	end

	return top[1], top[2]
end

local function belowRise(span, edge)
	return edge.top - span.floor > MIN_RISE
end

local function distanceField(field, carry, seeds, yield, accept)
	local h = {}
	for _, seed in ipairs(seeds) do
		local s, d = seed[1], seed[2]
		if d < (s[field] or math.huge) then
			s[field] = d
			if carry then s[carry] = seed[3] end
			heapPush(h, s, d)
		end
	end

	local popped = 0
	while #h > 0 do
		local d, s = heapPop(h)
		if d <= s[field] then
			for k = 1, 8 do
				local nb = s.links[k]
				if nb and nb.kind == KIND_SNOW and (not accept or accept(nb, s[carry])) then
					local nd = d + DIRS[k][3] * CELL
					if nd < (nb[field] or math.huge) then
						nb[field] = nd
						if carry then nb[carry] = s[carry] end
						heapPush(h, nb, nd)
					end
				end
			end
		end

		popped = popped + 1
		if popped % 64 == 0 then yield() end
	end
end

local function signedEdgeDistance(s, field, edge, x, y)
	local d = s[field] or math.huge
	if not edge then return d end

	return d - ((x - s.x) * edge.dx + (y - s.y) * edge.dy) / math.sqrt(edge.dx * edge.dx + edge.dy * edge.dy)
end

local function edgeDistance(s, field, edge, x, y)
	return math.max(signedEdgeDistance(s, field, edge, x, y), 0)
end

local function wallLift(s, x, y)
	local first, second = 0, 0
	for k = 1, 4 do
		local wall = s[WALL_EDGES[k]]
		if wall then
			local drift, width = driftFor(wall.height)
			local d = edgeDistance(s, WALL_FIELDS[k], wall, x, y)
			if d < width then
				local f = 1 - d / width
				local here = drift * f * f
				if here > first then
					first, second = here, first
				elseif here > second then
					second = here
				end
			end
		end
	end

	return first + second * CORNER_SHARE
end

local function profile(s, x, y)
	local fade = math.min(edgeDistance(s, "fade", s.fadeEdge, x, y) / SLOPE_WIDTH, 1)
	local height = EDGE_MIN_HEIGHT + (1 - EDGE_MIN_HEIGHT) * fade
	local lift = wallLift(s, x, y) * fade
	local rise = s.riseEdge
	if rise then
		local plane = planeAt(s, x - s.x, y - s.y)
		local r = rise.top - plane
		if r > MIN_RISE and rise.floor - plane <= STEP then
			local d = signedEdgeDistance(s, "rise", rise, x, y)
			if d < SLOPE_WIDTH then lift = math.max(lift, d >= 0 and r * (1 - d / SLOPE_WIDTH) or r + d * RISE_SINK) end
		end
	end

	return height, lift
end

heightfield.Profile = profile

local function shedFactor(s)
	local slope = math.sqrt(s.nx * s.nx + s.ny * s.ny) / s.nz

	return math.Clamp((SHED_END - slope) / (SHED_END - SHED_START), 0, 1)
end

local function relax(snowSpans, yield)
	local excess = {}
	for _ = 1, RELAX_PASSES do
		for _, s in ipairs(snowSpans) do
			s.inflow, s.outflow = 0, 0
		end

		for _, s in ipairs(snowSpans) do
			local amount = s.amount
			if amount > 0 then
				local top = s.floor + amount
				local total, most = 0, 0
				for k = 1, 8 do
					local e = 0
					local nb = s.links[k]
					if nb then
						if nb.kind == KIND_SNOW then e = top - nb.floor - nb.amount - DIRS[k][3] * CELL * REPOSE end
					elseif s.drops[k] then
						e = amount - CELL * 0.5 * REPOSE
					end

					e = math.max(e, 0)
					excess[k] = e
					total = total + e
					if e > most then most = e end
				end

				if total > 0 then
					local moved = math.min(amount, most * RELAX_RATE)
					s.outflow = moved
					for k = 1, 8 do
						local target = s.links[k] or s.drops[k]
						if excess[k] > 0 and target.kind == KIND_SNOW then
							target.inflow = target.inflow + moved * excess[k] / total
						end
					end
				end
			end
		end

		for _, s in ipairs(snowSpans) do
			s.amount = s.amount - s.outflow + s.inflow
		end

		yield()
	end
end

function heightfield.Build(triGrid, cx, cy, yield)
	yield = yield or noYield
	local n = CHUNK / CELL + MARGIN * 2
	local data = { cx = cx, cy = cy, n = n, gx0 = cx * CHUNK / CELL - MARGIN, gy0 = cy * CHUNK / CELL - MARGIN, columns = {}, spans = {}, points = {} }
	for k = 0, n * n - 1 do
		data.columns[k] = {}
	end

	gatherFloors(triGrid, data, yield)
	buildSpans(data, yield)
	local fadeSeeds, wallSeeds, riseSeeds = linkSpans(data, yield)
	distanceField("fade", "fadeEdge", fadeSeeds, yield)
	for k = 1, 4 do
		distanceField(WALL_FIELDS[k], WALL_EDGES[k], wallSeeds[k], yield)
	end
	for _, seed in ipairs(riseSeeds) do
		local s, edge = seed[1], seed[3]
		local upper = edge.upper
		local _, lift = profile(upper, (s.x + upper.x) * 0.5, (s.y + upper.y) * 0.5)
		edge.top = upper.floor + lift
		edge.upper = nil
	end
	distanceField("rise", "riseEdge", riseSeeds, yield, belowRise)

	local snowSpans = {}
	for _, s in ipairs(data.spans) do
		if s.kind == KIND_SNOW then
			snowSpans[#snowSpans + 1] = s
			s.height, s.lift = profile(s, s.x, s.y)
			s.base = DEPTH * s.height + s.lift
			s.amount = s.base * shedFactor(s)
		end
	end

	relax(snowSpans, yield)
	for _, s in ipairs(snowSpans) do
		s.delta = s.amount - s.base
	end

	return data
end
