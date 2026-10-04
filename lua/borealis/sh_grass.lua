local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

if SERVER then
	if not resource.AddShader then return end

	resource.AddShader("grass_vs30")
	resource.AddShader("grass_ps30")

	return
end

-- Grass tufts on every world surface whose material has a grass surfaceprop.
-- Faces come from the BSP (brushes and displacements, with the painted blend
-- alpha as density), tufts are generated per 512 unit chunk around the eye
-- inside a per-frame budget, and drawn as analytic blades by grass_ps30.

local GRASS_ENABLED = CreateClientConVar("cl_draw_grass", "0", true, false, "draw grass tufts on grass surfaces")
local GRASS_DISTANCE = CreateClientConVar("cl_draw_grass_distance", "3072", true, false, "grass draw distance in units", 1024, 16384)

-- winter: tod swaps the ground for snow (tod/snow.lua, December to February),
-- so the tufts thin out, shorten and go to dead straw poking through it.
-- tod_removesnow ends it at runtime through TOD_WinterRemoved
local month = tonumber(os.date("%m")) or 0
local WINTER = month >= 12 or month <= 2
local AUTUMN = false
local DENSITY, HEIGHT, DRYNESS, ROOT_COLOR, TIP_COLOR, DRY_COLOR

local function setSeason(winter, autumn)
	WINTER, AUTUMN = winter, autumn
	DENSITY = winter and 0.35 or 1 -- share of the tufts kept
	HEIGHT = winter and 0.7 or 1
	DRYNESS = winter and 1 or autumn and 0.6 or 0.15 -- 0 green .. 1 golden
	ROOT_COLOR = winter and { 0.09, 0.085, 0.06 } or autumn and { 0.07, 0.06, 0.02 } or { 0.06, 0.075, 0.02 }
	TIP_COLOR = autumn and { 0.13, 0.15, 0.045 } or { 0.15, 0.19, 0.05 }
	DRY_COLOR = winter and { 0.28, 0.25, 0.17 } or autumn and { 0.32, 0.2, 0.06 } or { 0.24, 0.21, 0.09 } -- tip colour of dry blades
end

setSeason(WINTER, AUTUMN)

local CHUNK = 512 -- world units per chunk
local SPACING = 18 -- tuft grid spacing
local JITTER = 8
local RADIUS, FADE_START, FADE_END -- chunks kept and drawn within RADIUS, blades fade out between the two, all from cl_grass_distance
local QUAD_W, QUAD_H = 26, 40 -- quad size at height scale 1
local MAX_SLOPE_Z = 0.7 -- skip faces steeper than this normal z
local WIND_ANGLE = math.atan2(0.6, 0.8)
local WIND = 0.45 -- bend at the tip, in quad widths
local TRANSLUCENCY = 0.35
local FILL_K = 0.5 -- ambient cube share added as fill light, not scaled by tod's light style
local BUILD_BUDGET_MS = 3 -- generation work per frame
local LOAD_BUDGET_MS = 8 -- BSP parse work per frame
local MESH_BATCH = 240 -- tufts per IMesh, about 1 ms to build
local STRIDE = 7 -- numbers per tuft in a chunk's flat tuft array: x, y, z, seed, height scale, packed light, vis cluster
local TRI_CELL = 1024 -- triangle index cell size
local SIGHT_TESTS_PER_FRAME = 40 -- line of sight tests per draw

--------------------------------------------------------------------------
-- BSP: grass triangles with per-vertex blend alpha (0 = grass, 255 = other),
-- indexed by TRI_CELL grid cell.  Parsed in a coroutine over several frames.
--------------------------------------------------------------------------
local tris, triGrid

-- BSP visibility: the node tree for point -> leaf, each leaf's cluster and the
-- compressed PVS rows.  The engine hides world geometry beyond sky brushes by
-- PVS, never by depth, so the tufts follow the same rule
local bspNodes, bspPlanes, leafCluster, visData, numClusters

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

local function addTri(ax, ay, az, bx, by, bz, cx, cy, cz, aa, ab, ac)
	local minx, miny, maxx, maxy = math.min(ax, bx, cx), math.min(ay, by, cy), math.max(ax, bx, cx), math.max(ay, by, cy)
	local t = { ax, ay, az, bx, by, bz, cx, cy, cz, aa, ab, ac, minx, miny, maxx, maxy }
	tris[#tris + 1] = t
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
local function addDisplacement(px, py, pz, dispinfo, dispverts, di, alphaFor)
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
				addTri(gx[i00], gy[i00], gz[i00], gx[i10], gy[i10], gz[i10], gx[i11], gy[i11], gz[i11], ga[i00], ga[i10], ga[i11])
				addTri(gx[i00], gy[i00], gz[i00], gx[i11], gy[i11], gz[i11], gx[i01], gy[i01], gz[i01], ga[i00], ga[i11], ga[i01])
			else
				addTri(gx[i00], gy[i00], gz[i00], gx[i10], gy[i10], gz[i10], gx[i01], gy[i01], gz[i01], ga[i00], ga[i10], ga[i01])
				addTri(gx[i10], gy[i10], gz[i10], gx[i11], gy[i11], gz[i11], gx[i01], gy[i01], gz[i01], ga[i10], ga[i11], ga[i01])
			end
		end
	end
end

local function loadGrassTriangles()
	local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
	if not f then return false, "cannot open maps/" .. game.GetMap() .. ".bsp" end

	local function lump(i)
		f:Seek(8 + i * 16)
		local ofs, len, ver = f:ReadLong(), f:ReadLong(), f:ReadLong()
		f:Seek(ofs)

		return f:Read(len) or "", len, ver
	end

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
	local planes, plLen = lump(1)
	local nodesL, noLen = lump(5)
	local leavesL, leLen, leVer = lump(10)
	visData = lump(4)
	f:Close()

	-- no node tree, no planes or no leaves means no vis lookup, so no grass
	if noLen == 0 or plLen == 0 or leLen == 0 then
		return false, string.format("empty bsp lumps (planes %d, nodes %d, leaves %d)", plLen, noLen, leLen)
	end

	local sliceStart = SysTime()
	local function breathe()
		if (SysTime() - sliceStart) * 1000 > LOAD_BUDGET_MS then
			coroutine.yield()
			sliceStart = SysTime()
		end
	end

	local names = {}
	for i = 0, stLen / 4 - 1 do
		names[i] = string.match(strData, "^[^%z]*", i32(strTable, i * 4 + 1) + 1)
	end

	local texdata = {}
	for i = 0, tdLen / 32 - 1 do
		texdata[i] = names[i32(texdataL, i * 32 + 13)]
	end

	local texinfo = {}
	for i = 0, tiLen / 72 - 1 do
		texinfo[i] = i32(texinfoL, i * 72 + 69)
	end

	-- grass mode per texdata: 1 = whole surface, 2 = where blend alpha is low, 3 = where it is high
	local grassMode = {}
	local seen = 0
	for i, name in pairs(texdata) do
		local mat = Material(name)
		local sp = (mat:GetString("$surfaceprop") or ""):lower()
		local sp2 = (mat:GetString("$surfaceprop2") or ""):lower()
		if sp == "grass" and (sp2 == "" or sp2 == "grass") then
			grassMode[i] = 1
		elseif sp == "grass" then
			grassMode[i] = 2
		elseif sp2 == "grass" then
			grassMode[i] = 3
		end

		seen = seen + 1
		if seen % 50 == 0 then breathe() end
	end

	bspPlanes = {}
	for i = 0, plLen / 20 - 1 do
		local p, o = i * 20 + 1, i * 4
		bspPlanes[o + 1], bspPlanes[o + 2], bspPlanes[o + 3], bspPlanes[o + 4] = f32(planes, p), f32(planes, p + 4), f32(planes, p + 8), f32(planes, p + 12)
		if i % 2048 == 0 then breathe() end
	end

	bspNodes = {}
	for i = 0, noLen / 32 - 1 do
		local p, o = i * 32 + 1, i * 3
		bspNodes[o + 1], bspNodes[o + 2], bspNodes[o + 3] = i32(nodesL, p), i32(nodesL, p + 4), i32(nodesL, p + 8)
		if i % 2048 == 0 then breathe() end
	end

	local leafSize = leVer == 0 and 56 or 32 -- version 0 leaves carry ambient lighting
	leafCluster = {}
	for i = 0, leLen / leafSize - 1 do
		leafCluster[i] = i16(leavesL, i * leafSize + 5)
	end

	numClusters = #visData >= 4 and i32(visData, 1) or 0

	local function vertex(idx)
		local p = idx * 12 + 1

		return f32(verts, p), f32(verts, p + 4), f32(verts, p + 8)
	end

	for i = 0, faLen / 56 - 1 do
		if i % 512 == 0 then breathe() end
		local fp = i * 56 + 1
		local ti = i16(faces, fp + 10)
		local mode = texinfo[ti] and grassMode[texinfo[ti]]
		if mode and f32(planes, u16(faces, fp) * 20 + 9) >= MAX_SLOPE_Z then
			local firstedge, numedges, di = i32(faces, fp + 4), i16(faces, fp + 8), i16(faces, fp + 12)
			local px, py, pz = {}, {}, {}
			for e = 0, numedges - 1 do
				local se = i32(surfedges, (firstedge + e) * 4 + 1)
				local vi = u16(edges, math.abs(se) * 4 + 1 + (se < 0 and 2 or 0))
				px[e + 1], py[e + 1], pz[e + 1] = vertex(vi)
			end

			if di == -1 then
				for e = 2, numedges - 1 do
					addTri(px[1], py[1], pz[1], px[e], py[e], pz[e], px[e + 1], py[e + 1], pz[e + 1], 0, 0, 0)
				end
			elseif numedges == 4 then
				addDisplacement(px, py, pz, dispinfo, dispverts, di, function(a)
					return mode == 1 and 0 or (mode == 2 and a or 255 - a)
				end)
				breathe()
			end
		end
	end

	return true
end

-- vis cluster of a point, -1 in solid
local function clusterAt(x, y, z)
	local n = 0
	while n >= 0 do
		local o = n * 3
		local p = bspNodes[o + 1] * 4
		n = bspNodes[(bspPlanes[p + 1] * x + bspPlanes[p + 2] * y + bspPlanes[p + 3] * z >= bspPlanes[p + 4]) and o + 2 or o + 3]
	end

	return leafCluster[-n - 1]
end

-- clusters visible from a cluster, decoded from the run-length zero packed row
-- and kept until the cluster changes.  nil means everything (in solid, no vis)
local pvsCluster, pvsSet
local function pvsFor(cluster)
	if cluster == pvsCluster then return pvsSet end
	pvsCluster = cluster
	if cluster < 0 or numClusters == 0 then
		pvsSet = nil

		return nil
	end

	pvsSet = {}
	local p = i32(visData, 5 + cluster * 8) + 1
	local rowBytes = math.ceil(numClusters / 8)
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

--------------------------------------------------------------------------
-- chunks
--------------------------------------------------------------------------
local chunks -- key -> { cx, cy, mesh = {IMesh}|false|nil, tufts }
local tuftCache -- key -> flat tuft array, or false when empty, of evicted chunks
local buildQueue
local current -- chunk being generated

local function chunkKey(cx, cy)
	return cx * 65536 + cy
end

-- point (x, y) against triangle t: z and blend alpha when inside
local function sample(t, x, y)
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
local function candidates(x0, y0, x1, y1)
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

local UP = Vector(0, 0, 1)
local traceStart, traceEnd, lightPos = Vector(0, 0, 0), Vector(0, 0, 0), Vector(0, 0, 0)
local coverTraceRes = {}
local coverTrace = { mask = MASK_SOLID_BRUSHONLY, start = traceStart, endpos = traceEnd, output = coverTraceRes }

-- more generation work when the frame has headroom, less when it is already slow
local lastThinkMs = 0
local function budget()
	return math.Clamp(16 - RealFrameTime() * 1000 + lastThinkMs, BUILD_BUDGET_MS * 0.7, BUILD_BUDGET_MS * 2)
end

-- rasterises the chunk into a flat tuft array (STRIDE numbers per tuft),
-- yielding when the frame budget is spent
local function rasterChunk(ch, cand)
	local x0, y0 = ch.cx * CHUNK, ch.cy * CHUNK
	local x1, y1 = x0 + CHUNK, y0 + CHUNK
	local tufts, n = {}, 0
	local rng = ch.cx * 73856093 + ch.cy * 19349663
	local function rand()
		rng = (rng * 1103515245 + 12345) % 2147483648

		return rng / 2147483648
	end

	local lightCache = {} -- one lighting sample per 2x2 cells, lightmap luxels are ~16 units, packed as r * 65536 + g * 256 + b of light / 2
	local sliceStart = SysTime()
	for gy = y0, y1 - 1, SPACING do
		if (SysTime() - sliceStart) * 1000 > budget() then
			coroutine.yield()
			sliceStart = SysTime()
		end

		for gx = x0, x1 - 1, SPACING do
			local x = gx + SPACING * 0.5 + (rand() - 0.5) * 2 * JITTER
			local y = gy + SPACING * 0.5 + (rand() - 0.5) * 2 * JITTER
			local seed, r3, r4, r5 = rand(), rand(), rand(), rand()
			for _, t in ipairs(cand) do
				if x >= t[13] and x <= t[15] and y >= t[14] and y <= t[16] then
					local z, alpha = sample(t, x, y)
					if z and r3 * 255 > alpha and r5 <= DENSITY then
						-- skip tufts under floors, roofs and other covering brushes
						traceStart:SetUnpacked(x, y, z + QUAD_H + 2)
						traceEnd:SetUnpacked(x, y, z + 1)
						util.TraceLine(coverTrace)
						if not coverTraceRes.Hit then
							local lkey = (math.floor(x / (SPACING * 2)) * 4096 + math.floor(y / (SPACING * 2))) * 1024 + math.floor(z / 64)
							local light = lightCache[lkey]
							if not light then
								lightPos:SetUnpacked(x, y, z + 12)
								local l = render.ComputeLighting(lightPos, UP)
								light = math.Clamp(math.floor(l.x * 127.5), 0, 255) * 65536 + math.Clamp(math.floor(l.y * 127.5), 0, 255) * 256 + math.Clamp(math.floor(l.z * 127.5), 0, 255)
								lightCache[lkey] = light
							end

							-- cluster sampled above the blade, a hair higher when that lands in solid
							local cluster = clusterAt(x, y, z + 8)
							if cluster < 0 then cluster = clusterAt(x, y, z + 24) end

							-- mostly tall, some short
							tufts[n + 1], tufts[n + 2], tufts[n + 3], tufts[n + 4], tufts[n + 5], tufts[n + 6], tufts[n + 7] = x, y, z, seed, 0.5 + r4 * r4 * 0.9, light, cluster
							n = n + STRIDE
						end
					end
				end
			end
		end
	end

	-- tufts sorted by cluster, so a mesh batch spans few clusters
	local count = n / STRIDE
	local order = {}
	for i = 1, count do
		order[i] = i
	end

	table.sort(order, function(a, b)
		return tufts[(a - 1) * STRIDE + 7] < tufts[(b - 1) * STRIDE + 7]
	end)

	local sorted = {}
	for i = 1, count do
		local src, dst = (order[i] - 1) * STRIDE, (i - 1) * STRIDE
		for k = 1, STRIDE do
			sorted[dst + k] = tufts[src + k]
		end
	end

	return sorted
end

local COS60, SIN60 = math.cos(math.rad(60)), math.sin(math.rad(60))
local DIRS = { { 1, 0 }, { COS60, SIN60 }, { -COS60, SIN60 } } -- three crossed quads per tuft
local vpos = Vector(0, 0, 0)
local vr, vg, vb, va = 0, 0, 0, 0
local function vert(px, py, pz, u, v)
	vpos:SetUnpacked(px, py, pz)
	mesh.Position(vpos)
	mesh.TexCoord(0, u, v)
	mesh.Color(vr, vg, vb, va)
	mesh.AdvanceVertex()
end

-- one batch { m = IMesh, groups } for tufts first .. last (tuft indices,
-- 1-based).  The tufts come sorted by vis cluster, each run is a group with
-- its cluster (-1 for in solid), its centre and its first and last tuft.
-- screenspace_general binds position, colour and texcoord 0 only: colour
-- rgb = light / 2, colour a = seed, uv.x = blade u + 2 * height index
local function buildMesh(tufts, first, last)
	local m = Mesh()
	local groups, g = {}, nil
	mesh.Begin(m, MATERIAL_QUADS, (last - first + 1) * #DIRS)
	for i = first, last do
		local o = (i - 1) * STRIDE
		local x, y, z, seed, hs, light, cluster = tufts[o + 1], tufts[o + 2], tufts[o + 3] + 0.5, tufts[o + 4], tufts[o + 5], tufts[o + 6], tufts[o + 7]
		if not g or cluster ~= g.cluster then
			g = { cluster = cluster, n = 0, x = 0, y = 0, z = 0, ax = x, ay = y, az = z, sightEpoch = -1, blocked = false }
			groups[#groups + 1] = g
		end

		g.n, g.x, g.y, g.z = g.n + 1, g.x + x, g.y + y, g.z + z
		g.bx, g.by, g.bz = x, y, z
		vr = math.floor(light / 65536)
		vg = math.floor(light / 256) % 256
		vb = light % 256
		va = math.floor(seed * 255)
		local hIndex = math.Clamp(math.floor((hs - 0.5) / 0.9 * 7 + 0.5), 0, 7)
		hs = 0.5 + hIndex / 7 * 0.9
		local h = QUAD_H * hs * HEIGHT
		local w = QUAD_W * (0.7 + 0.3 * hs) * 0.5
		local rot = seed * math.pi
		local cr, sr = math.cos(rot), math.sin(rot)
		local u0 = hIndex * 2
		for _, d in ipairs(DIRS) do
			local dx = (d[1] * cr - d[2] * sr) * w
			local dy = (d[1] * sr + d[2] * cr) * w
			local lx, ly, rx, ry = x - dx, y - dy, x + dx, y + dy
			vert(lx, ly, z, u0, 1)
			vert(lx, ly, z + h, u0, 0)
			vert(rx, ry, z + h, u0 + 1, 0)
			vert(rx, ry, z, u0 + 1, 1)
		end
	end

	mesh.End()

	local lift = QUAD_H * HEIGHT * 0.5
	for _, gr in ipairs(groups) do
		gr.x, gr.y, gr.z = gr.x / gr.n, gr.y / gr.n, gr.z / gr.n + lift
		gr.az, gr.bz = gr.az + lift, gr.bz + lift
	end

	return { m = m, groups = groups }
end

local function destroyMeshes(ch)
	if not ch.mesh then return end
	for _, b in ipairs(ch.mesh) do
		b.m:Destroy()
	end
end

local function byPrio(a, b)
	return a.prio < b.prio
end

-- bounding sphere of a chunk's tufts, for the frustum test in draw
local function chunkBounds(ch, tufts)
	local zmin, zmax = math.huge, -math.huge
	for o = 3, #tufts, STRIDE do
		local z = tufts[o]
		if z < zmin then zmin = z end
		if z > zmax then zmax = z end
	end

	local half = CHUNK * 0.5
	local hz = (zmax - zmin) * 0.5 + QUAD_H
	ch.cz = zmin + hz
	ch.radius = math.sqrt(half * half * 2 + hz * hz)
end

-- picks the next queued chunk: nearest first, chunks in front of the camera
-- before the rest.  The queue is re-sorted only when chunks were added or the
-- eye moved a chunk, a large radius queues thousands of mostly empty chunks
local queueDirty, queueEye = false, Vector()
local function nextChunk()
	local eye, fwd = EyePos(), EyeVector()
	if queueDirty or eye:DistToSqr(queueEye) > CHUNK * CHUNK then
		queueDirty, queueEye = false, eye
		for _, ch in ipairs(buildQueue) do
			local dx, dy = ch.cx * CHUNK + CHUNK * 0.5 - eye.x, ch.cy * CHUNK + CHUNK * 0.5 - eye.y
			local dist = math.sqrt(dx * dx + dy * dy)
			local behind = dist > CHUNK and (dx * fwd.x + dy * fwd.y) / dist < -0.35
			ch.prio = dist + (behind and RADIUS or 0)
		end

		table.sort(buildQueue, byPrio)
	end

	local ch = table.remove(buildQueue, 1)
	local key = chunkKey(ch.cx, ch.cy)
	if ch.mesh ~= nil or chunks[key] ~= ch then return end

	local cached = tuftCache[key]
	if cached == false then
		ch.mesh, ch.tufts = false, 0
	elseif cached then
		ch.pendingTufts, ch.nextTuft, ch.meshes = cached, 1, {}
		chunkBounds(ch, cached)
		current = ch
	else
		local x0, y0 = ch.cx * CHUNK, ch.cy * CHUNK
		local cand = candidates(x0, y0, x0 + CHUNK, y0 + CHUNK)
		if #cand == 0 then
			ch.mesh, ch.tufts = false, 0
			tuftCache[key] = false
		else
			ch.co = coroutine.create(function() return rasterChunk(ch, cand) end)
			current = ch
		end
	end
end

-- advances the current chunk: raster until the budget is spent, then one mesh batch at a time
local function stepChunk()
	local ch = current
	if ch.pendingTufts then
		local tufts = ch.pendingTufts
		local total = #tufts / STRIDE
		local first = ch.nextTuft
		local last = math.min(first + MESH_BATCH - 1, total)
		ch.meshes[#ch.meshes + 1] = buildMesh(tufts, first, last)
		if last >= total then
			ch.tufts = total
			ch.mesh = ch.meshes
			ch.pendingTufts, ch.co = nil, nil
			current = nil
		else
			ch.nextTuft = last + 1
		end

		return true
	end

	local ok, tufts = coroutine.resume(ch.co)
	if not ok then
		ErrorNoHalt("[grass] chunk build failed: " .. tostring(tufts) .. "\n")
		ch.mesh, ch.tufts = false, 0
		current = nil
	elseif coroutine.status(ch.co) == "dead" then
		local key = chunkKey(ch.cx, ch.cy)
		if #tufts == 0 then
			ch.mesh, ch.tufts = false, 0
			tuftCache[key] = false
			current = nil
		else
			tuftCache[key] = tufts
			ch.pendingTufts, ch.nextTuft, ch.meshes = tufts, 1, {}
			chunkBounds(ch, tufts)
		end
	else
		return false -- budget spent inside the raster
	end

	return true
end

--------------------------------------------------------------------------
-- rendering
--------------------------------------------------------------------------
local MAT
local loader -- BSP parse coroutine
local ready = false
local stop -- defined below, called when the parse gives up

local function packColor(r, g, b)
	return math.floor(math.Clamp(r, 0, 1) * 255) * 65536 + math.floor(math.Clamp(g, 0, 1) * 255) * 256 + math.floor(math.Clamp(b, 0, 1) * 255)
end

-- tod rescales the lightmaps at runtime through the named light_environment's
-- light style; ComputeLighting returns the unscaled lightmap, so the current
-- style scale is applied per frame (engine: (letter - 'a') * 22 / 256)
local function worldLightScale()
	if not (tod and tod.MultToLightEnv and tod.CurrentParams) then return 1 end
	local code = tod.MultToLightEnv(tod.CurrentParams.world_light_multiplier or 1)
	if not isnumber(code) then return 1 end

	return (code - 97) * 22 / 256
end

local function think()
	local t0 = SysTime()
	if not ready then
		local ok, res, why = coroutine.resume(loader)
		if not ok then
			ErrorNoHalt("[grass] bsp parse failed: " .. tostring(res) .. "\n")
			stop()
			return
		end

		if coroutine.status(loader) == "dead" then
			-- a parse that gave up leaves no tree to look clusters up in
			if not res then
				ErrorNoHalt("[grass] grass off: " .. tostring(why) .. "\n")
				stop()
				return
			end

			ready = true
		end

		lastThinkMs = (SysTime() - t0) * 1000
		return
	end

	local frameBudget = budget()
	while (SysTime() - t0) * 1000 < frameBudget do
		if current then
			if not stepChunk() then break end
		elseif #buildQueue > 0 then
			nextChunk()
		else
			break
		end
	end

	lastThinkMs = (SysTime() - t0) * 1000
end

local function byDrawDist(a, b)
	return a.drawDist < b.drawDist
end

local visible = {}
local evictNext = 0
local lastWet = 0

-- line of sight from the eye to a group, against world brushes only: a
-- blocking face either draws (depth hides the blades) or does not (nodraw,
-- sky, a back face) and the sky fills it, so the blades are skipped either
-- way.  Windows and grates are passed through like the depth test does.
-- Tests are redone when the eye moves or after a while, a few per frame
local sightEpoch, sightEye, sightNext = 0, Vector(), 0
local sightStart, sightEnd, sightRes = Vector(), Vector(), {}
local sightTrace = { start = sightStart, endpos = sightEnd, mask = CONTENTS_SOLID, output = sightRes, filter = function() return false end }
local function sightBlocked(x, y, z)
	sightEnd:SetUnpacked(x, y, z)
	util.TraceLine(sightTrace)

	return sightRes.Hit and not sightRes.StartSolid
end
local function draw(_, _, sky3d)
	if not ready or sky3d or render.GetRenderTarget() then return end
	local eye = EyePos()
	local fwd = EyeVector()
	local amb = render.GetAmbientLightColor()

	MAT:SetFloat("$c0_x", eye.x)
	MAT:SetFloat("$c0_y", eye.y)
	MAT:SetFloat("$c0_z", eye.z)
	MAT:SetFloat("$c0_w", CurTime() % 1000)
	MAT:SetFloat("$c1_y", packColor(amb.x * FILL_K, amb.y * FILL_K, amb.z * FILL_K))
	MAT:SetFloat("$c2_x", worldLightScale())

	-- wet blades go darker and greener while it rains (tod/rain.lua)
	local wet = tod and tod.rain and tod.rain.amount or 0
	if wet ~= lastWet then
		lastWet = wet
		local k = 1 - 0.3 * wet
		MAT:SetFloat("$c2_y", packColor(ROOT_COLOR[1] * k, ROOT_COLOR[2] * k, ROOT_COLOR[3] * k))
		MAT:SetFloat("$c2_z", packColor(TIP_COLOR[1] * k, TIP_COLOR[2] * (1 - 0.2 * wet), TIP_COLOR[3] * k))
		MAT:SetFloat("$c3_z", packColor(DRY_COLOR[1] * k, DRY_COLOR[2] * k, DRY_COLOR[3] * k))
	end
	MAT:SetFloat("$c2_w", render.GetToneMappingScaleLinear().x)
	render.SetMaterial(MAT)

	-- view frustum: the setup's fov is the horizontal one at this aspect
	local vs = render.GetViewSetup()
	local ang = EyeAngles()
	local right, up = ang:Right(), ang:Up()
	local tanH = math.tan(math.rad(vs.fov or 90) * 0.5)
	local tanV = tanH / (vs.aspect or (ScrW() / ScrH()))
	local kH, kV = math.sqrt(1 + tanH * tanH), math.sqrt(1 + tanV * tanV)

	local n = math.ceil(RADIUS / CHUNK)
	local ecx, ecy = math.floor(eye.x / CHUNK), math.floor(eye.y / CHUNK)
	local half = CHUNK * 0.5
	local nvis = 0
	for cy = ecy - n, ecy + n do
		for cx = ecx - n, ecx + n do
			local ddx, ddy = cx * CHUNK + half - eye.x, cy * CHUNK + half - eye.y
			local dist = math.sqrt(ddx * ddx + ddy * ddy)
			if dist - half * 1.42 < RADIUS then
				local key = chunkKey(cx, cy)
				local ch = chunks[key]
				if not ch then
					ch = { cx = cx, cy = cy }
					chunks[key] = ch
					buildQueue[#buildQueue + 1] = ch
					queueDirty = true
				elseif ch.mesh then
					-- bounding sphere against the four side planes
					local ddz, r = ch.cz - eye.z, ch.radius
					local fz = ddx * fwd.x + ddy * fwd.y + ddz * fwd.z
					if fz > -r then
						local fx = ddx * right.x + ddy * right.y + ddz * right.z
						local fy = ddx * up.x + ddy * up.y + ddz * up.z
						if math.abs(fx) < fz * tanH + r * kH and math.abs(fy) < fz * tanV + r * kV then
							ch.drawDist = dist
							nvis = nvis + 1
							visible[nvis] = ch
						end
					end
				end
			end
		end
	end

	-- the material tests depth but does not write it; force both, near to far
	for i = #visible, nvis + 1, -1 do
		visible[i] = nil
	end

	table.sort(visible, byDrawDist)

	-- a batch draws when one of its groups is in the eye's PVS and in line of
	-- sight at its centre or either end.  An untested group counts as visible
	local eyeCluster = clusterAt(eye.x, eye.y, eye.z)
	local pvs = pvsFor(eyeCluster)
	if RealTime() > sightNext or eye:DistToSqr(sightEye) > 64 * 64 then
		sightEpoch, sightNext = sightEpoch + 1, RealTime() + 0.5
		sightEye:Set(eye)
	end

	sightStart:Set(eye)
	local tests = 0
	render.OverrideDepthEnable(true, true)
	for _, ch in ipairs(visible) do
		for _, b in ipairs(ch.mesh) do
			local show = false
			for _, g in ipairs(b.groups) do
				local c = g.cluster
				if c == eyeCluster then
					show = true
					break
				elseif pvs == nil or c < 0 or pvs[c] then
					if g.sightEpoch ~= sightEpoch and tests < SIGHT_TESTS_PER_FRAME then
						tests = tests + 1
						g.sightEpoch = sightEpoch
						g.blocked = sightBlocked(g.x, g.y, g.z) and sightBlocked(g.ax, g.ay, g.az) and sightBlocked(g.bx, g.by, g.bz)
					end

					if not g.blocked then
						show = true
						break
					end
				end
			end

			if show then b.m:Draw() end
		end
	end

	render.OverrideDepthEnable(false, false)

	-- evict chunks well outside the radius, keeping their tuft lists
	if RealTime() > evictNext then
		evictNext = RealTime() + 2
		local limit = (RADIUS + CHUNK * 2) ^ 2
		for key, ch in pairs(chunks) do
			local ddx, ddy = ch.cx * CHUNK + half - eye.x, ch.cy * CHUNK + half - eye.y
			if ddx * ddx + ddy * ddy > limit and ch ~= current then
				destroyMeshes(ch)
				chunks[key] = nil
			end
		end
	end
end

function stop()
	hook.Remove("Think", "ms_grass")
	hook.Remove("PostDrawOpaqueRenderables", "ms_grass")
	if chunks then
		for _, ch in pairs(chunks) do
			destroyMeshes(ch)
		end
	end

	table.Empty(visible)
	chunks, tuftCache, buildQueue, current = nil, nil, nil, nil
	tris, triGrid, loader, ready = nil, nil, nil, false
	bspNodes, bspPlanes, leafCluster, visData, pvsCluster, pvsSet = nil, nil, nil, nil, nil, nil
end

-- draw distance: the chunk radius and the shader's fade range.  Chunks past a
-- shrunk radius get evicted by draw, a grown one fills in through the queue
local function setDistance()
	RADIUS = math.Clamp(GRASS_DISTANCE:GetInt(), 1024, 16384)
	FADE_START, FADE_END = RADIUS * 0.72, RADIUS * 0.98
	if MAT then
		MAT:SetFloat("$c1_w", FADE_START)
		MAT:SetFloat("$c3_w", FADE_END)
	end
end

setDistance()

local function start(PIXEL_SHADER, VERTEX_SHADER)
	stop()
	MAT = MAT or CreateMaterial("ms_grass_" .. os.time(), "screenspace_general", {
		["$pixshader"] = PIXEL_SHADER,
		["$vertexshader"] = VERTEX_SHADER,
		["$basetexture"] = "",
		["$ignorez"] = 0,
		["$depthtest"] = 1,
		["$vertexcolor"] = 1,
		["$vertextransform"] = 1,
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$linearwrite"] = 0, -- sRGB write like the world shaders, the baked light is linear
		["$nocull"] = 1,
		["<dx90"] = { ["$no_draw"] = 1 },
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = WIND_ANGLE, ["$c1_y"] = 0, ["$c1_z"] = WIND, ["$c1_w"] = FADE_START,
		["$c2_x"] = 1, ["$c2_y"] = packColor(unpack(ROOT_COLOR)), ["$c2_z"] = packColor(unpack(TIP_COLOR)), ["$c2_w"] = 1,
		["$c3_x"] = TRANSLUCENCY, ["$c3_y"] = DRYNESS, ["$c3_z"] = packColor(unpack(DRY_COLOR)), ["$c3_w"] = FADE_END,
	})
	-- the material outlives a restart, so the season's palette is set every time
	MAT:SetFloat("$c2_y", packColor(unpack(ROOT_COLOR)))
	MAT:SetFloat("$c3_y", DRYNESS)
	MAT:SetFloat("$c3_z", packColor(unpack(DRY_COLOR)))
	lastWet = -1

	setDistance()

	tris, triGrid = {}, {}
	chunks, tuftCache, buildQueue = {}, {}, {}
	loader = coroutine.create(loadGrassTriangles)
	hook.Add("Think", "ms_grass", think)
	hook.Add("PostDrawOpaqueRenderables", "ms_grass", draw)
end

local function shadersAvailable()
	return file.Exists("shaders/fxc/grass_ps30.vcs", "GAME") and file.Exists("shaders/fxc/grass_vs30.vcs", "GAME")
end

local function apply()
	if not GRASS_ENABLED:GetBool() then
		stop()
		return
	end

	if shadersAvailable() then
		start("grass_ps30", "grass_vs30")
	elseif HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
		hook.Add("ShaderMounted", "ms_grass", function()
			hook.Remove("ShaderMounted", "ms_grass")
			if GRASS_ENABLED:GetBool() and shadersAvailable() then
				start("grass_ps30", "grass_vs30")
			end
		end)
	end
end

cvars.RemoveChangeCallback("cl_draw_grass", "ms_grass")
cvars.AddChangeCallback("cl_draw_grass", apply, "ms_grass")
cvars.RemoveChangeCallback("cl_draw_grass_distance", "ms_grass")
cvars.AddChangeCallback("cl_draw_grass_distance", setDistance, "ms_grass")
hook.Remove("ShaderMounted", "ms_grass")

-- density and height are baked into the tufts, so leaving winter is a rebuild
hook.Add("TOD_WinterRemoved", "ms_grass", function()
	if not WINTER then return end
	setSeason(false, AUTUMN)
	apply()
end)

hook.Add("TOD_Autumn", "ms_grass", function()
	if WINTER or AUTUMN then return end
	setSeason(false, true)
	if MAT then
		MAT:SetFloat("$c3_y", DRYNESS)
		lastWet = -1
	end
end)

-- the parse needs the map and its materials in, so the first apply waits for
-- the world; on a reload after that point it runs straight away
if LocalPlayer and IsValid(LocalPlayer()) then
	apply()
else
	hook.Add("InitPostEntity", "ms_grass", function()
		hook.Remove("InitPostEntity", "ms_grass")
		apply()
	end)
end
