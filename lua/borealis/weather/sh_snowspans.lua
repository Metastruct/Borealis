local snowspans = shaderpack.snowspans or {}
shaderpack.snowspans = snowspans

local bspdata = shaderpack.bspdata

local CHUNK, CELL, MARGIN = 512, 16, 6
local DEPTH = 10
local STEP = 24
local MIN_RISE = 0.5
local STEP_MIN = 1
local CLEARANCE = 8
local MATCH = 12
local SKY_DISTANCE = 16384
local SLOPE_WIDTH = 48
local EDGE_MIN_HEIGHT = 0.3
local DRIFT_PER_WALL_HEIGHT, DRIFT_MAX = 0.2, 24
local DRIFT_WIDTH_PER_HEIGHT, DRIFT_MIN_WIDTH = 3, 32
local DRIFT_RAY_HEIGHT, WALL_INSET, WALL_MAX_NZ = 4, 2, 0.5
local WALL_CHECK_HEIGHT = DRIFT_MAX / DRIFT_PER_WALL_HEIGHT
local CORNER_SHARE = 0.5
local RISE_SINK = 0.5
local SOLID_TOLERANCE = 1
local REPOSE = 0.8
local SHED_START, SHED_END = 0.9, 1.6
local RELAX_PASSES, RELAX_RATE = 4, 0.5
local GRADIENT_STEP = CELL * 0.5
local DIAGONAL = math.sqrt(2)
local WALL_FIELDS = { "wall1", "wall2", "wall3", "wall4" }
local WALL_EDGES = { "wallEdge1", "wallEdge2", "wallEdge3", "wallEdge4" }
local DIRS = {
	{ 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
	{ 1, 1, DIAGONAL, 1, 3 }, { 1, -1, DIAGONAL, 1, 4 }, { -1, 1, DIAGONAL, 2, 3 }, { -1, -1, DIAGONAL, 2, 4 },
}

local KIND_SNOW, KIND_SHELTERED, KIND_WATER = 1, 2, 3
snowspans.KIND_SNOW, snowspans.KIND_SHELTERED, snowspans.KIND_WATER = KIND_SNOW, KIND_SHELTERED, KIND_WATER

local res = {}
local trace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = res }
local point = Vector()

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
					if z then
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
	local traces = 0
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
					util.TraceLine(trace)
					traces = traces + 1
					if not res.StartSolid then
						local ceil = res.Hit and res.HitPos.z or floor + SKY_DISTANCE
						if ceil - floor >= CLEARANCE then
							local kind = (not res.Hit or res.HitSky) and KIND_SNOW or KIND_SHELTERED
							point:SetUnpacked(x, y, floor + 2)
							if bit.band(util.PointContents(point), MASK_WATER) ~= 0 then kind = KIND_WATER end

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

	return traces
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
	local z = s.floor + DRIFT_RAY_HEIGHT
	trace.start:SetUnpacked(s.x, s.y, z)
	trace.endpos:SetUnpacked(s.x + dx * CELL, s.y + dy * CELL, z)
	util.TraceLine(trace)
	if not res.Hit or res.StartSolid or res.HitSky or res.HitNoDraw or math.abs(res.HitNormal.z) >= WALL_MAX_NZ then return end
	if (res.HitTexture or ""):lower():find("^tools/") then return end

	local n, hit = res.HitNormal, res.HitPos
	local distance = res.Fraction * CELL * math.sqrt(dx * dx + dy * dy)
	local wx, wy = hit.x - n.x * WALL_INSET, hit.y - n.y * WALL_INSET
	trace.start:SetUnpacked(wx, wy, s.floor + WALL_CHECK_HEIGHT)
	trace.endpos:SetUnpacked(wx, wy, s.floor)
	util.TraceLine(trace)

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

local function surfaceOf(s, x, y)
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

local function shedFactor(s)
	local slope = math.sqrt(s.nx * s.nx + s.ny * s.ny) / s.nz

	return math.Clamp((SHED_END - slope) / (SHED_END - SHED_START), 0, 1)
end

local function relax(snow, yield)
	local excess = {}
	for _ = 1, RELAX_PASSES do
		for _, s in ipairs(snow) do
			s.inflow, s.outflow = 0, 0
		end

		for _, s in ipairs(snow) do
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

		for _, s in ipairs(snow) do
			s.amount = s.amount - s.outflow + s.inflow
		end

		yield()
	end
end

function snowspans.Build(triGrid, cx, cy, yield)
	yield = yield or noYield
	local t0 = SysTime()
	local n = CHUNK / CELL + MARGIN * 2
	local data = { cx = cx, cy = cy, n = n, gx0 = cx * CHUNK / CELL - MARGIN, gy0 = cy * CHUNK / CELL - MARGIN, columns = {}, spans = {}, points = {} }
	for k = 0, n * n - 1 do
		data.columns[k] = {}
	end

	gatherFloors(triGrid, data, yield)
	local t1 = SysTime()
	local traces = buildSpans(data, yield)
	local t2 = SysTime()
	local fadeSeeds, wallSeeds, riseSeeds = linkSpans(data, yield)
	local t3 = SysTime()
	distanceField("fade", "fadeEdge", fadeSeeds, yield)
	for k = 1, 4 do
		distanceField(WALL_FIELDS[k], WALL_EDGES[k], wallSeeds[k], yield)
	end
	for _, seed in ipairs(riseSeeds) do
		local s, edge = seed[1], seed[3]
		local upper = edge.upper
		local _, lift = surfaceOf(upper, (s.x + upper.x) * 0.5, (s.y + upper.y) * 0.5)
		edge.top = upper.floor + lift
		edge.upper = nil
	end
	distanceField("rise", "riseEdge", riseSeeds, yield, belowRise)

	local snow = {}
	for _, s in ipairs(data.spans) do
		if s.kind == KIND_SNOW then
			snow[#snow + 1] = s
			s.height, s.lift = surfaceOf(s, s.x, s.y)
			s.base = DEPTH * s.height + s.lift
			s.amount = s.base * shedFactor(s)
		end
	end

	local t4 = SysTime()
	relax(snow, yield)
	for _, s in ipairs(snow) do
		s.delta = s.amount - s.base
	end

	local t5 = SysTime()
	data.stats = {
		columns = n * n, spans = #data.spans, snow = #snow, traces = traces,
		gatherMs = (t1 - t0) * 1000, spanMs = (t2 - t1) * 1000, linkMs = (t3 - t2) * 1000, fieldMs = (t4 - t3) * 1000, relaxMs = (t5 - t4) * 1000,
	}

	return data
end

local function matchSpan(list, z)
	local best, bestDz
	for _, s in ipairs(list) do
		local dz = math.abs(s.floor - z)
		if dz <= MATCH and (not best or dz < bestDz) then best, bestDz = s, dz end
	end

	return best
end

local function exposedPoint(data, x, y, z)
	local key = math.floor(x * 4 + 0.5) .. "," .. math.floor(y * 4 + 0.5) .. "," .. math.floor(z * 4 + 0.5)
	local open = data.points[key]
	if open == nil then
		trace.start:SetUnpacked(x, y, z + 2)
		trace.endpos:SetUnpacked(x, y, z + SKY_DISTANCE)
		util.TraceLine(trace)
		open = not res.StartSolid and (not res.Hit or res.HitSky)
		if open then
			point:SetUnpacked(x, y, z + 2)
			open = bit.band(util.PointContents(point), MASK_WATER) == 0
		end
		data.points[key] = open
	end

	return open
end

local picks = { {}, {}, {}, {} }

local function reachable(x, y, z, s)
	local dx, dy, dz = s.x - x, s.y - y, s.floor - z
	trace.start:SetUnpacked(x, y, z + DRIFT_RAY_HEIGHT)
	trace.endpos:SetUnpacked(s.x, s.y, s.floor + DRIFT_RAY_HEIGHT)
	util.TraceLine(trace)
	if res.StartSolid and res.FractionLeftSolid * math.sqrt(dx * dx + dy * dy + dz * dz) > SOLID_TOLERANCE then return false end

	return res.Fraction >= 1
end

local function sample(data, x, y, z, nx, ny, nz, allowPoint)
	local n, gx0, gy0, columns = data.n, data.gx0, data.gy0, data.columns
	local fx, fy = x / CELL - 0.5 - gx0, y / CELL - 0.5 - gy0
	local i0, j0 = math.floor(fx), math.floor(fy)
	local tx, ty = fx - i0, fy - j0
	local count, slots = 0, 0
	for k = 0, 3 do
		local di, dj = k % 2, math.floor(k / 2)
		local w = (di == 1 and tx or 1 - tx) * (dj == 1 and ty or 1 - ty)
		local i, j = i0 + di, j0 + dj
		if w > 0 and i >= 0 and i < n and j >= 0 and j < n then
			slots = slots + 1
			local cx, cy = (gx0 + i + 0.5) * CELL, (gy0 + j + 0.5) * CELL
			local cz = z - (nx * (cx - x) + ny * (cy - y)) / nz
			local s = matchSpan(columns[j * n + i], cz)
			if s then
				count = count + 1
				local p = picks[count]
				p.s, p.w, p.o = s, w, s.floor - cz
			end
		end
	end

	if count < slots then
		local kept = 0
		for c = 1, count do
			local p = picks[c]
			if reachable(x, y, z, p.s) then
				kept = kept + 1
				picks[c], picks[kept] = picks[kept], p
			end
		end
		count = kept
	end

	local near
	for c = 1, count do
		local p = picks[c]
		if not near or math.abs(p.o) < math.abs(near.o) then near = p end
	end

	local matched, snowW, height, lift, bestW, best = 0, 0, 0, 0, 0
	for c = 1, count do
		local p = picks[c]
		local s, w, gap = p.s, p.w, p.o - (near and near.o or 0)
		if p == near or not (gap > STEP_MIN and near.s.riseEdge or gap < -STEP_MIN and s.riseEdge) then
			matched = matched + w
			if s.kind == KIND_SNOW then
				local h, l = surfaceOf(s, x, y)
				snowW = snowW + w
				height = height + w * h
				lift = lift + w * (l + s.delta)
				if w > bestW then bestW, best = w, s end
			end
		end
	end

	if matched <= 0 then
		local nearest, nearestD
		for j = j0 - 1, j0 + 2 do
			for i = i0 - 1, i0 + 2 do
				if (i < i0 or i > i0 + 1 or j < j0 or j > j0 + 1) and i >= 0 and i < n and j >= 0 and j < n then
					local cx, cy = (gx0 + i + 0.5) * CELL, (gy0 + j + 0.5) * CELL
					local d = (cx - x) * (cx - x) + (cy - y) * (cy - y)
					if not nearestD or d < nearestD then
						local s = matchSpan(columns[j * n + i], z - (nx * (cx - x) + ny * (cy - y)) / nz)
						if s and reachable(x, y, z, s) then nearest, nearestD = s, d end
					end
				end
			end
		end

		if not nearest then
			if allowPoint and exposedPoint(data, x, y, z) then return EDGE_MIN_HEIGHT, 0, { x = x, y = y, floor = z } end

			return 0, 0
		end

		if nearest.kind ~= KIND_SNOW then return 0, 0 end

		local h, l = surfaceOf(nearest, x, y)

		return h, l + nearest.delta, nearest
	end

	if snowW <= 0 then return 0, 0 end

	return height / matched, lift / snowW, best
end

function snowspans.Surface(data, x, y, z, nx, ny)
	nx, ny = nx or 0, ny or 0
	local nz = math.max(math.sqrt(math.max(1 - nx * nx - ny * ny, 0)), 0.3)
	local height, lift, best = sample(data, x, y, z, nx, ny, nz, true)
	if height <= 0 or DEPTH * height + lift <= 0 then return 0 end

	local e = GRADIENT_STEP
	local function surfaceAt(dx, dy)
		local h, l = sample(data, x + dx, y + dy, z - (nx * dx + ny * dy) / nz, nx, ny, nz)
		if h <= 0 then return end

		return DEPTH * h + l
	end

	local here = DEPTH * height + lift
	local px, mx, py, my = surfaceAt(e, 0), surfaceAt(-e, 0), surfaceAt(0, e), surfaceAt(0, -e)
	local gx = px and mx and (px - mx) / (2 * e) or px and (px - here) / e or mx and (here - mx) / e or 0
	local gy = py and my and (py - my) / (2 * e) or py and (py - here) / e or my and (here - my) / e or 0
	if lift < 0 then height, lift = height + lift / DEPTH, 0 end

	return height, lift, best.x, best.y, best.floor, gx, gy
end

function snowspans.SnowBelow(data, x, y, z)
	local n = data.n
	local i, j = math.floor(x / CELL - data.gx0), math.floor(y / CELL - data.gy0)
	if i < 0 or i >= n or j < 0 or j >= n then return false end

	for _, s in ipairs(data.columns[j * n + i]) do
		if s.kind == KIND_SNOW and s.floor < z - MIN_RISE and s.floor >= z - STEP then return true end
	end

	return false
end

function snowspans.ChunkAt(pos)
	return math.floor(pos.x / CHUNK), math.floor(pos.y / CHUNK)
end

if SERVER then return end

local COLORS = {
	[KIND_SHELTERED] = { 200, 40, 40 },
	[KIND_WATER] = { 40, 80, 220 },
}

local overlays = {}
local mode = "depth"

local function spanColor(s)
	if s.kind ~= KIND_SNOW then
		local c = COLORS[s.kind]

		return c[1], c[2], c[3]
	end

	if mode == "fade" then
		local f = math.min(s.fade / SLOPE_WIDTH, 1) * 255

		return 255 - f, f, 0
	elseif mode == "wall" then
		local f = math.min(s.lift / DRIFT_MAX, 1) * 255

		return f, f, 255
	elseif mode == "relax" then
		local f = math.min(math.abs(s.delta) / DEPTH, 1) * 255

		return s.delta < 0 and 255 or 255 - f, s.delta > 0 and 255 or 255 - f, 255 - f
	end

	local f = 80 + 175 * math.min(math.max(s.amount, 0) / (DEPTH + DRIFT_MAX), 1)

	return f, f, f
end

local function buildMesh(data)
	local quads = {}
	local half = CELL * 0.45
	for _, s in ipairs(data.spans) do
		if s.i >= MARGIN and s.i < data.n - MARGIN and s.j >= MARGIN and s.j < data.n - MARGIN then
			quads[#quads + 1] = s
		end
	end

	if #quads == 0 then return end

	local m = Mesh()
	local pos = Vector()
	mesh.Begin(m, MATERIAL_QUADS, #quads)
	for _, s in ipairs(quads) do
		local z = s.floor + 1 + (s.kind == KIND_SNOW and math.max(s.amount, 0) or 0)
		local r, g, b = spanColor(s)
		for _, c in ipairs({ { -half, -half }, { -half, half }, { half, half }, { half, -half } }) do
			pos:SetUnpacked(s.x + c[1], s.y + c[2], z)
			mesh.Position(pos)
			mesh.Color(r, g, b, 200)
			mesh.AdvanceVertex()
		end
	end
	mesh.End()

	return m
end

function snowspans.Show(data)
	local key = data.cx .. ":" .. data.cy
	if overlays[key] and overlays[key].mesh then overlays[key].mesh:Destroy() end
	overlays[key] = { data = data, mesh = buildMesh(data) }
end

function snowspans.SetMode(m)
	mode = m
	for _, o in pairs(overlays) do
		if o.mesh then o.mesh:Destroy() end
		o.mesh = buildMesh(o.data)
	end
end

function snowspans.Clear()
	for _, o in pairs(overlays) do
		if o.mesh then o.mesh:Destroy() end
	end
	overlays = {}
end

hook.Add("PostDrawTranslucentRenderables", "borealis_snowspans", function(depth, _, sky3d)
	if depth or sky3d or next(overlays) == nil then return end

	render.SetColorMaterial()
	for _, o in pairs(overlays) do
		if o.mesh then o.mesh:Draw() end
	end
end)
