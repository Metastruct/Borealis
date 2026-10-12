local bspdata = shaderpack.bspdata or {}
shaderpack.bspdata = bspdata

local LOAD_BUDGET_MS = 8 -- BSP parse work per frame
local TRI_CELL = 1024 -- triangle index cell size

-- little-endian decoders over lump strings (1-based positions)
local byte = string.byte
local function u16(s, pos)
	local b1, b2 = byte(s, pos, pos + 1)

	return b2 * 256 + b1
end

local function i16(s, pos)
	local v = u16(s, pos)

	return v >= 32768 and v - 65536 or v
end

local function i32(s, pos)
	local b1, b2, b3, b4 = byte(s, pos, pos + 3)
	local v = ((b4 * 256 + b3) * 256 + b2) * 256 + b1

	return v >= 2147483648 and v - 4294967296 or v
end

local function f32(s, pos)
	local b1, b2, b3, b4 = byte(s, pos, pos + 3)
	local sign = b4 >= 128 and -1 or 1
	local exp = (b4 % 128) * 2 + math.floor(b3 / 128)
	local mant = ((b3 % 128) * 256 + b2) * 256 + b1
	if exp == 0 then return sign * mant * 2 ^ -149 end
	if exp == 255 then return mant == 0 and sign * math.huge or 0 end

	return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
end

local function openLumps()
	local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
	if not f then return nil end

	return f, function(i)
		f:Seek(8 + i * 16)
		local ofs, len, ver = f:ReadLong(), f:ReadLong(), f:ReadLong()
		f:Seek(ofs)

		return f:Read(len) or "", len, ver
	end
end

bspdata.U16, bspdata.I16, bspdata.I32, bspdata.F32, bspdata.OpenLumps = u16, i16, i32, f32, openLumps

local function frameBudget()
	local sliceStart = SysTime()

	return function()
		if (SysTime() - sliceStart) * 1000 > LOAD_BUDGET_MS then
			coroutine.yield()
			sliceStart = SysTime()
		end
	end
end

bspdata.FrameBudget = frameBudget

-- BSP visibility: the node tree for point -> leaf, each leaf's cluster and the
-- compressed PVS rows.  The engine hides world geometry beyond sky brushes by
-- PVS, never by depth
local function parseVis()
	local f, lump = openLumps()
	if not f then return false, "cannot open maps/" .. game.GetMap() .. ".bsp" end

	local planes, plLen = lump(1)
	local nodesL, noLen = lump(5)
	local leavesL, leLen, leVer = lump(10)
	local visData = lump(4)
	local waterL, waLen = lump(36)
	f:Close()

	-- no node tree, no planes or no leaves means no vis lookup
	if noLen == 0 or plLen == 0 or leLen == 0 then
		return false, string.format("empty bsp lumps (planes %d, nodes %d, leaves %d)", plLen, noLen, leLen)
	end

	local yieldIfOverBudget = frameBudget()
	local bspPlanes = {}
	for i = 0, plLen / 20 - 1 do
		local p, o = i * 20 + 1, i * 4
		bspPlanes[o + 1], bspPlanes[o + 2], bspPlanes[o + 3], bspPlanes[o + 4] = f32(planes, p), f32(planes, p + 4), f32(planes, p + 8), f32(planes, p + 12)
		if i % 2048 == 0 then yieldIfOverBudget() end
	end

	local bspNodes = {}
	for i = 0, noLen / 32 - 1 do
		local p, o = i * 32 + 1, i * 3
		bspNodes[o + 1], bspNodes[o + 2], bspNodes[o + 3] = i32(nodesL, p), i32(nodesL, p + 4), i32(nodesL, p + 8)
		if i % 2048 == 0 then yieldIfOverBudget() end
	end

	local leafSize = leVer == 0 and 56 or 32 -- version 0 leaves carry ambient lighting
	local leafCluster, leafWater = {}, {}
	for i = 0, leLen / leafSize - 1 do
		leafCluster[i] = i16(leavesL, i * leafSize + 5)
		leafWater[i] = i16(leavesL, i * leafSize + 29)
	end

	local waterSurface = {}
	for i = 0, waLen / 12 - 1 do
		waterSurface[i] = f32(waterL, i * 12 + 1)
	end

	bspdata.vis = {
		map = game.GetMap(),
		planes = bspPlanes,
		nodes = bspNodes,
		leafCluster = leafCluster,
		leafWater = leafWater,
		waterSurface = waterSurface,
		visData = visData,
		numClusters = #visData >= 4 and i32(visData, 1) or 0,
	}

	return true
end

local visCo
local function stepVis()
	local vis = bspdata.vis
	if vis and vis.map == game.GetMap() then return true end
	if bspdata.visError then return false, bspdata.visError end

	visCo = visCo or coroutine.create(parseVis)
	local ok, res, why = coroutine.resume(visCo)
	if not ok then
		visCo = nil
		error(res, 0)
	end

	if coroutine.status(visCo) ~= "dead" then return false end
	visCo = nil
	if not res then
		bspdata.visError = why
		return false, why
	end

	return true
end

function bspdata.WaitVis()
	while true do
		local done, why = stepVis()
		if done then return bspdata.vis end
		if why then return nil, why end
		coroutine.yield()
	end
end

function bspdata.LoadVis()
	while true do
		local done, why = stepVis()
		if done then return bspdata.vis end
		if why then return nil, why end
	end
end

local function leafAt(vis, x, y, z)
	local bspNodes, bspPlanes = vis.nodes, vis.planes
	local n = 0
	while n >= 0 do
		local o = n * 3
		local p = bspNodes[o + 1] * 4
		n = bspNodes[(bspPlanes[p + 1] * x + bspPlanes[p + 2] * y + bspPlanes[p + 3] * z >= bspPlanes[p + 4]) and o + 2 or o + 3]
	end

	return -n - 1
end

-- vis cluster of a point, -1 in solid
function bspdata.ClusterAt(x, y, z)
	local vis = bspdata.vis

	return vis.leafCluster[leafAt(vis, x, y, z)]
end

function bspdata.WaterSurfaceAt(x, y, z)
	local vis = bspdata.vis
	local w = vis.leafWater[leafAt(vis, x, y, z)]

	return w >= 0 and vis.waterSurface[w] or nil
end

-- clusters visible from a cluster, decoded from the run-length zero packed row
-- and kept until the cluster changes.  nil means everything (in solid, no vis)
local pvsVis, pvsCluster, pvsSet
function bspdata.PVS(cluster)
	local vis = bspdata.vis
	if cluster == pvsCluster and vis == pvsVis then return pvsSet end
	pvsVis, pvsCluster = vis, cluster
	if cluster < 0 or vis.numClusters == 0 then
		pvsSet = nil

		return nil
	end

	local visData = vis.visData
	pvsSet = {}
	local p = i32(visData, 5 + cluster * 8) + 1
	local rowBytes = math.ceil(vis.numClusters / 8)
	local c = 0
	while c < rowBytes do
		local b = byte(visData, p)
		p = p + 1
		if b == 0 then
			c = c + byte(visData, p)
			p = p + 1
		else
			local base = c * 8
			for bit = 0, 7 do
				if b % 2 == 1 then pvsSet[base + bit] = true end
				b = math.floor(b / 2)
			end

			c = c + 1
		end
	end

	return pvsSet
end

local function addTri(triGrid, ax, ay, az, bx, by, bz, cx, cy, cz, aa, ab, ac)
	local minx, miny, maxx, maxy = math.min(ax, bx, cx), math.min(ay, by, cy), math.max(ax, bx, cx), math.max(ay, by, cy)
	local t = { ax, ay, az, bx, by, bz, cx, cy, cz, aa, ab, ac, minx, miny, maxx, maxy }
	for gy = math.floor(miny / TRI_CELL), math.floor(maxy / TRI_CELL) do
		for gx = math.floor(minx / TRI_CELL), math.floor(maxx / TRI_CELL) do
			local key = gx .. ":" .. gy
			local cell = triGrid[key]
			if not cell then
				cell = {}
				triGrid[key] = cell
			end

			cell[#cell + 1] = t
		end
	end
end

-- displacement grid: the face is a quad, corner order starts at startPosition,
-- disp verts run column-major relative to that order (verified against traces)
local function addDisplacement(emit, px, py, pz, dispinfo, dispverts, di, alphaFor)
	local dp = di * 176 + 1
	local sx, sy, sz = f32(dispinfo, dp), f32(dispinfo, dp + 4), f32(dispinfo, dp + 8)
	local vertStart = i32(dispinfo, dp + 12)
	local power = i32(dispinfo, dp + 20)
	local n = 2 ^ power + 1

	local best, bestD = 1, math.huge
	for c = 1, 4 do
		local d = (px[c] - sx) ^ 2 + (py[c] - sy) ^ 2 + (pz[c] - sz) ^ 2
		if d < bestD then best, bestD = c, d end
	end

	local cx, cy, cz = {}, {}, {}
	for c = 0, 3 do
		local corner = (best - 1 + c) % 4 + 1
		cx[c], cy[c], cz[c] = px[corner], py[corner], pz[corner]
	end

	local gx, gy, gz, ga = {}, {}, {}, {}
	for r = 0, n - 1 do
		local tr = r / (n - 1)
		local ax, ay, az = cx[0] + (cx[3] - cx[0]) * tr, cy[0] + (cy[3] - cy[0]) * tr, cz[0] + (cz[3] - cz[0]) * tr
		local bx, by, bz = cx[1] + (cx[2] - cx[1]) * tr, cy[1] + (cy[2] - cy[1]) * tr, cz[1] + (cz[2] - cz[1]) * tr
		for c = 0, n - 1 do
			local tc = c / (n - 1)
			local idx = r * n + c
			local vp = (vertStart + c * n + r) * 20 + 1
			local dx, dy, dz, dist, alpha = f32(dispverts, vp), f32(dispverts, vp + 4), f32(dispverts, vp + 8), f32(dispverts, vp + 12), f32(dispverts, vp + 16)
			gx[idx] = ax + (bx - ax) * tc + dx * dist
			gy[idx] = ay + (by - ay) * tc + dy * dist
			gz[idx] = az + (bz - az) * tc + dz * dist
			ga[idx] = alphaFor(alpha)
		end
	end

	for r = 0, n - 2 do
		for c = 0, n - 2 do
			local i00, i01, i10, i11 = r * n + c, r * n + c + 1, (r + 1) * n + c, (r + 1) * n + c + 1
			if (r + c) % 2 == 0 then
				emit(gx[i00], gy[i00], gz[i00], gx[i10], gy[i10], gz[i10], gx[i11], gy[i11], gz[i11], ga[i00], ga[i10], ga[i11])
				emit(gx[i00], gy[i00], gz[i00], gx[i11], gy[i11], gz[i11], gx[i01], gy[i01], gz[i01], ga[i00], ga[i11], ga[i01])
			else
				emit(gx[i00], gy[i00], gz[i00], gx[i10], gy[i10], gz[i10], gx[i01], gy[i01], gz[i01], ga[i00], ga[i10], ga[i01])
				emit(gx[i10], gy[i10], gz[i10], gx[i11], gy[i11], gz[i11], gx[i01], gy[i01], gz[i01], ga[i10], ga[i11], ga[i01])
			end
		end
	end
end

bspdata.Displacement = addDisplacement

-- triangles with per-vertex blend alpha (0 = picked, 255 = other), indexed by
-- TRI_CELL grid cell.  Parsed in a coroutine over several frames
function bspdata.Triangles(classify, minNormalZ)
	local f, lump = openLumps()
	if not f then return nil, "cannot open maps/" .. game.GetMap() .. ".bsp" end

	local strData = lump(43)
	local strTable, stLen = lump(44)
	local texdataL, tdLen = lump(2)
	local texinfoL, tiLen = lump(6)
	local faces, faLen = lump(7)
	local dispinfo = lump(26)
	local dispverts = lump(33)
	local verts = lump(3)
	local edges = lump(12)
	local surfedges = lump(13)
	local planes = lump(1)
	f:Close()

	local yieldIfOverBudget = frameBudget()
	local names = {}
	for i = 0, stLen / 4 - 1 do
		names[i] = string.match(strData, "^[^%z]*", i32(strTable, i * 4 + 1) + 1)
	end

	local texinfo = {}
	for i = 0, tiLen / 72 - 1 do
		texinfo[i] = i32(texinfoL, i * 72 + 69)
	end

	-- mode per texdata: 1 = whole surface, 2 = where blend alpha is low, 3 = where it is high
	local modes = {}
	for i = 0, tdLen / 32 - 1 do
		modes[i] = classify(names[i32(texdataL, i * 32 + 13)])
		if i % 50 == 49 then yieldIfOverBudget() end
	end

	local function vertex(idx)
		local p = idx * 12 + 1

		return f32(verts, p), f32(verts, p + 4), f32(verts, p + 8)
	end

	local triGrid = {}
	local function emit(...)
		addTri(triGrid, ...)
	end

	for i = 0, faLen / 56 - 1 do
		if i % 512 == 0 then yieldIfOverBudget() end
		local fp = i * 56 + 1
		local ti = i16(faces, fp + 10)
		local mode = texinfo[ti] and modes[texinfo[ti]]
		if mode and f32(planes, u16(faces, fp) * 20 + 9) >= minNormalZ then
			local firstedge, numedges, di = i32(faces, fp + 4), i16(faces, fp + 8), i16(faces, fp + 12)
			local px, py, pz = {}, {}, {}
			for e = 0, numedges - 1 do
				local se = i32(surfedges, (firstedge + e) * 4 + 1)
				local vi = u16(edges, math.abs(se) * 4 + 1 + (se < 0 and 2 or 0))
				px[e + 1], py[e + 1], pz[e + 1] = vertex(vi)
			end

			if di == -1 then
				for e = 2, numedges - 1 do
					addTri(triGrid, px[1], py[1], pz[1], px[e], py[e], pz[e], px[e + 1], py[e + 1], pz[e + 1], 0, 0, 0)
				end
			elseif numedges == 4 then
				addDisplacement(emit, px, py, pz, dispinfo, dispverts, di, function(a)
					return mode == 1 and 0 or (mode == 2 and a or 255 - a)
				end)
				yieldIfOverBudget()
			end
		end
	end

	return triGrid
end

-- point (x, y) against triangle t: z and blend alpha when inside
function bspdata.Sample(t, x, y)
	local ax, ay, bx, by, cx, cy = t[1], t[2], t[4], t[5], t[7], t[8]
	local v0x, v0y = cx - ax, cy - ay
	local v1x, v1y = bx - ax, by - ay
	local v2x, v2y = x - ax, y - ay
	local d00 = v0x * v0x + v0y * v0y
	local d01 = v0x * v1x + v0y * v1y
	local d11 = v1x * v1x + v1y * v1y
	local d20 = v2x * v0x + v2y * v0y
	local d21 = v2x * v1x + v2y * v1y
	local denom = d00 * d11 - d01 * d01
	if math.abs(denom) < 1e-6 then return nil end
	local wc = (d11 * d20 - d01 * d21) / denom
	local wb = (d00 * d21 - d01 * d20) / denom
	local wa = 1 - wb - wc
	if wa < -0.001 or wb < -0.001 or wc < -0.001 then return nil end

	return wa * t[3] + wb * t[6] + wc * t[9], wa * t[10] + wb * t[11] + wc * t[12]
end

-- triangles overlapping a chunk, from the grid index
function bspdata.Candidates(triGrid, x0, y0, x1, y1)
	local cand, seen = {}, {}
	for gy = math.floor(y0 / TRI_CELL), math.floor(y1 / TRI_CELL) do
		for gx = math.floor(x0 / TRI_CELL), math.floor(x1 / TRI_CELL) do
			local cell = triGrid[gx .. ":" .. gy]
			if cell then
				for _, t in ipairs(cell) do
					if not seen[t] and t[15] >= x0 and t[13] <= x1 and t[16] >= y0 and t[14] <= y1 then
						seen[t] = true
						cand[#cand + 1] = t
					end
				end
			end
		end
	end

	return cand
end
