local PS, VS, DEPTH_PS, STAMP_PS = "borealis_snowcover_ps30", "borealis_water_vs30", "borealis_waterdepth_ps30", "borealis_snowstamp_ps30"
local NOISE = "shaderpack/procsky/fognoise"
local SHADERS = { PS, VS, DEPTH_PS, STAMP_PS }

if SERVER then
	shaderpack.AddResources(SHADERS, { NOISE })
end

local bspdata, depthslices, foliage, chunks, dynamiclights = shaderpack.bspdata, shaderpack.depthslices, shaderpack.foliage, shaderpack.chunks, shaderpack.dynamiclights
local ENABLED = CLIENT and CreateClientConVar("borealis_snowcover", "1", true, false, "draw deep snow with footprints in winter")
local DISTANCE = CLIENT and CreateClientConVar("borealis_snowcover_distance", "3072", true, false, "snow cover draw distance in units", 1024, 16384)
local snowcover = shaderpack.snowcover or {}
shaderpack.snowcover = snowcover

local paused = false
local grid

function snowcover.SetPaused(state)
	paused = state
	grid:SetPaused(state)
end

local DEPTH = 10
local CHUNK, CELL = 512, 32
local MIN_NZ = 0.3
local fadeStart, fadeEnd
local MESH_TRIS = 10000
local SIGHT_RAISE = 8
local MESH_CACHE_TRIS = jit.arch == "x64" and math.huge or 300000
local PRELOAD = jit.arch == "x64"
local CACHE_DIR = "shaderpack/snowcover"
local CACHE_VERSION = 2
local CACHE_COUNT_BYTES, CACHE_HEADER_BYTES, CACHE_CLUSTER_BYTES, CACHE_SAMPLE_BYTES, CACHE_VERTEX_BYTES = 4, 11, 5, 9, 17
local CACHE_COORD_SCALE, CACHE_COORD_OFFSET, CACHE_NORMAL_SCALE = 32, 8388608, 32767.5
local CACHE_YIELD_VERTS = 256
local CACHE_EMPTY = "\0\0\0\0"
local BAKE_NET = "borealis_snow_bake"
local BAKE_EMPTY_MS, BAKE_PLAYERS_TICK_SHARE = 20, 0.5
local BAKE_MEMORY_MB = 900
local BAKE_SEND_BYTES, BAKE_SEND_RATE = 32000, 131072
local BAKE_ENTRY_BYTES = 8
local BAKE_MAX_SENDS, BAKE_REQUEST_COOLDOWN = 4, 600
local BAKE_MAX_BYTES = 134217728
local MSG_KEY, MSG_CHUNK = 0, 1
local SKY_TRACE_DISTANCE = 16384
local SKY_GAP_REACH = 24
local SKY_GAP_DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local SKY_CELL, LIGHT_CELL = 16, 16
local SMALL_TRI = CELL * 2
local SKIRT_DEPTH = 1
local SLOPE_WIDTH, SLOPE_CELL = 48, 64
local EDGE_CHECK_DISTANCE, EDGE_MATCH_Z, EDGE_WALL_HEIGHT = 2, 24, 2
local EDGE_MIN_HEIGHT = 0.3
local MERGE_MIN_RISE, MERGE_BURIED_GAP, MERGE_SKIRT_SINK = 0.5, 0.5, 0.6
local DRIFT_PER_WALL_HEIGHT, DRIFT_MAX = 0.2, 24
local DRIFT_WIDTH_PER_HEIGHT, DRIFT_MIN_WIDTH = 3, 32
local DRIFT_RAY_HEIGHT, DRIFT_RAY_REACH, DRIFT_RAYS = 4, 80, 8
local DRIFT_WALL_MAX_NZ = 0.5
local FILL_K = 0.5
local FLASHLIGHT_ALBEDO = "[0.6 0.6 0.62]"

local TRAIL_TEXELS, TRAIL_SPAN = 1024, 2048
local TEXEL = TRAIL_SPAN / TRAIL_TEXELS
local TRAIL_STEP = 128
local REFILL_INTERVAL = 1
local REFILL_TIME, SNOWFALL_TIME = 1200, 120
local CAPTURE_PAD = 4
local STAMP_BLUR = 2
local CAPTURE_HEIGHT = 4096
local GATHER_INTERVAL = 0.25
local RESTAMP_INTERVAL = 1

local setConstant, packColor, toLinear = shaderpack.SetConstant, shaderpack.PackColor, shaderpack.ToLinear

local function classify(name)
	if name:lower():find("^tools/") or Material(name):GetShader():lower():find("water", 1, true) then return end

	return 1
end

local function chunkKey(cx, cy)
	return cx * 65536 + cy
end

local bakeStart, bakeBudget = 0, math.huge

local function buildYield()
	if chunks then
		chunks.YieldIfOverBudget()
	elseif (SysTime() - bakeStart) * 1000 > bakeBudget then
		coroutine.yield()
	end
end

local function triNormal(t)
	local ux, uy, uz = t[4] - t[1], t[5] - t[2], t[6] - t[3]
	local vx, vy, vz = t[7] - t[1], t[8] - t[2], t[9] - t[3]
	local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
	local len = math.sqrt(nx * nx + ny * ny + nz * nz)
	if len < 1e-6 then return 0, 0, 0 end
	if nz < 0 then len = -len end

	return nx / len, ny / len, nz / len
end

local function vertexKey(x, y, z)
	return math.floor(x * 8 + 0.5) .. "," .. math.floor(y * 8 + 0.5) .. "," .. math.floor(z * 8 + 0.5)
end

local triGrid, edgeGrid, snowEndGrid, snowMergeGrid

local wetPos = Vector()

local function submerged(x, y, z)
	wetPos:SetUnpacked(x, y, z + 2)

	return bit.band(util.PointContents(wetPos), MASK_WATER) ~= 0
end

local function snowEndsAt(grid, x, y, z, ox, oy)
	local px, py = x + ox * EDGE_CHECK_DISTANCE, y + oy * EDGE_CHECK_DISTANCE
	wetPos:SetUnpacked(px, py, z + DEPTH + 1)
	if bit.band(util.PointContents(wetPos), CONTENTS_SOLID) ~= 0 then return false end

	wetPos:SetUnpacked(px, py, z + EDGE_WALL_HEIGHT)
	if bit.band(util.PointContents(wetPos), CONTENTS_SOLID) ~= 0 then return false end

	for _, t in ipairs(bspdata.Candidates(grid, px - 1, py - 1, px + 1, py + 1)) do
		if t.vn then
			local sz = bspdata.Sample(t, px, py)
			if sz and math.abs(sz - z) <= EDGE_MATCH_Z then return false end
		end
	end

	return true
end

local function snowBelow(grid, x, y, z)
	for _, t in ipairs(bspdata.Candidates(grid, x - 1, y - 1, x + 1, y + 1)) do
		if t.vn then
			local sz = bspdata.Sample(t, x, y)
			if sz and sz < z - MERGE_MIN_RISE and sz >= z - EDGE_MATCH_Z then return true end
		end
	end

	return false
end

local function dropsToSnow(grid, x, y, z, ox, oy)
	local px, py = x + ox * EDGE_CHECK_DISTANCE, y + oy * EDGE_CHECK_DISTANCE
	wetPos:SetUnpacked(px, py, z + EDGE_WALL_HEIGHT)
	if bit.band(util.PointContents(wetPos), CONTENTS_SOLID) ~= 0 then return false end

	return snowBelow(grid, px, py, z)
end

local function addSnowEnd(endGrid, seg)
	local ax, ay, bx, by = seg[1], seg[2], seg[4], seg[5]
	for cy = math.floor((math.min(ay, by) - SLOPE_WIDTH) / SLOPE_CELL), math.floor((math.max(ay, by) + SLOPE_WIDTH) / SLOPE_CELL) do
		for cx = math.floor((math.min(ax, bx) - SLOPE_WIDTH) / SLOPE_CELL), math.floor((math.max(ax, bx) + SLOPE_WIDTH) / SLOPE_CELL) do
			local key = chunkKey(cx, cy)
			local list = endGrid[key]
			if not list then
				list = {}
				endGrid[key] = list
			end

			list[#list + 1] = seg
		end
	end
end

local function loadGeometry()
	local grid, why = bspdata.Triangles(classify, MIN_NZ, true, SURF_TRANS)
	if not grid then return false, why end

	grid = bspdata.RemoveSkybox(grid)

	local yieldIfOverBudget = bspdata.FrameBudget()
	local seen, edges, normals, up = {}, {}, {}, {}
	for _, cell in pairs(grid) do
		for _, t in ipairs(cell) do
			if not seen[t] then
				seen[t] = true
				t.nx, t.ny, t.nz = triNormal(t)
				if t.nz >= MIN_NZ and submerged(t[1], t[2], t[3]) and submerged(t[4], t[5], t[6]) and submerged(t[7], t[8], t[9]) then
					t.nz = 0
				end

				if t.nz >= MIN_NZ then
					local keys = { vertexKey(t[1], t[2], t[3]), vertexKey(t[4], t[5], t[6]), vertexKey(t[7], t[8], t[9]) }
					t.keys = keys
					up[#up + 1] = t
					for _, k in ipairs(keys) do
						local sum = normals[k]
						if not sum then
							sum = { 0, 0, 0 }
							normals[k] = sum
						end

						sum[1], sum[2], sum[3] = sum[1] + t.nx, sum[2] + t.ny, sum[3] + t.nz
					end

					for e = 1, 3 do
						local ka, kb = keys[e], keys[e % 3 + 1]
						local key = ka < kb and ka .. "|" .. kb or kb .. "|" .. ka
						if edges[key] == nil then
							edges[key] = { t, e }
						else
							edges[key] = false
						end
					end
				end

				yieldIfOverBudget()
			end
		end
	end

	for _, t in ipairs(up) do
		local vn = {}
		for i, k in ipairs(t.keys) do
			local sum = normals[k]
			local len = math.sqrt(sum[1] * sum[1] + sum[2] * sum[2] + sum[3] * sum[3])
			vn[i * 2 - 1], vn[i * 2] = sum[1] / len, sum[2] / len
		end

		t.vn, t.keys = vn, nil
		yieldIfOverBudget()
	end

	local egrid, endGrid, mergeGrid = {}, {}, {}
	for _, rec in pairs(edges) do
		if rec then
			local t, e = rec[1], rec[2]
			local ia, ib, ic = (e - 1) * 3, (e % 3) * 3, ((e + 1) % 3) * 3
			local ax, ay, az, bx, by, bz = t[ia + 1], t[ia + 2], t[ia + 3], t[ib + 1], t[ib + 2], t[ib + 3]
			local ox, oy = by - ay, ax - bx
			local len = math.sqrt(ox * ox + oy * oy)
			if len > 1e-3 then
				ox, oy = ox / len, oy / len
				if (t[ic + 1] - ax) * ox + (t[ic + 2] - ay) * oy > 0 then ox, oy = -ox, -oy end

				local edge = { ax, ay, az, t[10 + (e - 1)], bx, by, bz, t[10 + e % 3], ox, oy }
				for cy = math.floor(math.min(ay, by) / CHUNK), math.floor(math.max(ay, by) / CHUNK) do
					for cx = math.floor(math.min(ax, bx) / CHUNK), math.floor(math.max(ax, bx) / CHUNK) do
						local key = chunkKey(cx, cy)
						local list = egrid[key]
						if not list then
							list = {}
							egrid[key] = list
						end

						list[#list + 1] = edge
					end
				end

				local pieces = math.max(1, math.ceil(len / CELL))
				for k = 1, pieces do
					local f0, f1 = (k - 1) / pieces, k / pieces
					local px, py, pz = ax + (bx - ax) * f0, ay + (by - ay) * f0, az + (bz - az) * f0
					local qx, qy, qz = ax + (bx - ax) * f1, ay + (by - ay) * f1, az + (bz - az) * f1
					local mx, my, mz = (px + qx) * 0.5, (py + qy) * 0.5, (pz + qz) * 0.5
					if snowEndsAt(grid, mx, my, mz, ox, oy) then
						addSnowEnd(endGrid, { px, py, pz, qx, qy, qz, ox, oy })
					elseif dropsToSnow(grid, mx, my, mz, ox, oy) then
						addSnowEnd(mergeGrid, { px, py, pz, qx, qy, qz, ox, oy })
					end
				end
			end
		end

		yieldIfOverBudget()
	end

	triGrid, edgeGrid, snowEndGrid, snowMergeGrid = grid, egrid, endGrid, mergeGrid

	return true
end

local UP = Vector(0, 0, 1)
local samplePos = Vector()
local skyTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = {} }

local function cellKey(x, y, z, size)
	return (math.floor(x / size) + 4096) * 67108864 + (math.floor(y / size) + 4096) * 8192 + math.floor(z / size) + 4096
end

local edgeRes = {}
local edgeTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = edgeRes }

local function edgeSlopeAt(x, y, z)
	local list = snowEndGrid[chunkKey(math.floor(x / SLOPE_CELL), math.floor(y / SLOPE_CELL))]
	if not list then return 1, 0, 0 end

	local best, gx, gy = SLOPE_WIDTH * SLOPE_WIDTH, 0, 0
	for _, seg in ipairs(list) do
		local ax, ay, bx, by = seg[1], seg[2], seg[4], seg[5]
		local dx, dy = bx - ax, by - ay
		local len2 = dx * dx + dy * dy
		local f = len2 > 0 and math.Clamp(((x - ax) * dx + (y - ay) * dy) / len2, 0, 1) or 0
		local px, py = ax + dx * f, ay + dy * f
		local ex, ey = x - px, y - py
		local d2 = ex * ex + ey * ey
		if d2 < best then
			local unobstructed = d2 < 1
			if not unobstructed then
				edgeTrace.start:SetUnpacked(x, y, z + 2)
				edgeTrace.endpos:SetUnpacked(px, py, seg[3] + (seg[6] - seg[3]) * f + 2)
				util.TraceLine(edgeTrace)
				unobstructed = not edgeRes.Hit
			end

			if unobstructed then
				best = d2
				if d2 < 1 then
					gx, gy = -seg[7], -seg[8]
				else
					local d = math.sqrt(d2)
					gx, gy = ex / d, ey / d
				end
			end
		end
	end

	if gx == 0 and gy == 0 then return 1, 0, 0 end

	local rise = DEPTH * (1 - EDGE_MIN_HEIGHT) / SLOPE_WIDTH

	return EDGE_MIN_HEIGHT + (1 - EDGE_MIN_HEIGHT) * math.sqrt(best) / SLOPE_WIDTH, gx * rise, gy * rise
end

local function mergeAt(x, y, z)
	local list = snowMergeGrid[chunkKey(math.floor(x / SLOPE_CELL), math.floor(y / SLOPE_CELL))]
	if not list then return 0, 0, 0, false end

	local lift, gx, gy, buried = 0, 0, 0, false
	for _, seg in ipairs(list) do
		local ax, ay, bx, by = seg[1], seg[2], seg[4], seg[5]
		local dx, dy = bx - ax, by - ay
		local len2 = dx * dx + dy * dy
		local f = len2 > 0 and math.Clamp(((x - ax) * dx + (y - ay) * dy) / len2, 0, 1) or 0
		local rise = seg[3] + (seg[6] - seg[3]) * f - z
		if rise > MERGE_MIN_RISE and rise <= EDGE_MATCH_Z then
			local px, py = ax + dx * f, ay + dy * f
			local ex, ey = x - px, y - py
			local d2 = ex * ex + ey * ey
			if d2 < SLOPE_WIDTH * SLOPE_WIDTH then
				if ex * seg[7] + ey * seg[8] <= 0 then
					if rise - MERGE_BURIED_GAP > lift then
						lift, gx, gy, buried = rise - MERGE_BURIED_GAP, 0, 0, true
					end
				else
					local d = math.sqrt(d2)
					local here = rise * (1 - d / SLOPE_WIDTH)
					if here > lift then
						edgeTrace.start:SetUnpacked(x, y, z + 2)
						edgeTrace.endpos:SetUnpacked(px + seg[7] * EDGE_CHECK_DISTANCE, py + seg[8] * EDGE_CHECK_DISTANCE, z + 2)
						util.TraceLine(edgeTrace)
						if not edgeRes.Hit then
							lift, buried = here, false
							gx, gy = -ex / d * rise / SLOPE_WIDTH, -ey / d * rise / SLOPE_WIDTH
						end
					end
				end
			end
		end
	end

	return lift, gx, gy, buried
end

local driftRes, driftHeightRes = {}, {}
local driftTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = driftRes }
local driftHeightTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = driftHeightRes }

local function drawnWall(res)
	return not res.HitSky and not res.HitNoDraw and not (res.HitTexture or ""):lower():find("^tools/")
end

local function driftFromWall(x, y, z)
	local probe = DRIFT_MAX / DRIFT_PER_WALL_HEIGHT
	driftHeightTrace.start:SetUnpacked(x, y, z + probe)
	driftHeightTrace.endpos:SetUnpacked(x, y, z)
	util.TraceLine(driftHeightTrace)
	local height = driftHeightRes.StartSolid and probe or driftHeightRes.Hit and driftHeightRes.HitPos.z - z or 0
	if height <= EDGE_MATCH_Z then return 0 end

	return math.min(height * DRIFT_PER_WALL_HEIGHT, DRIFT_MAX)
end

local function wallDriftAt(x, y, z)
	local lift, gx, gy, skyX, skyY = 0, 0, 0, nil, nil
	local rayZ = z + DRIFT_RAY_HEIGHT
	wetPos:SetUnpacked(x, y, rayZ)
	local inside = bit.band(util.PointContents(wetPos), CONTENTS_SOLID) ~= 0
	local exit = math.huge
	driftTrace.start:SetUnpacked(x, y, rayZ)
	for i = 1, DRIFT_RAYS do
		local angle = (i - 1) / DRIFT_RAYS * math.pi * 2
		local dx, dy = math.cos(angle), math.sin(angle)
		driftTrace.endpos:SetUnpacked(x + dx * DRIFT_RAY_REACH, y + dy * DRIFT_RAY_REACH, rayZ)
		util.TraceLine(driftTrace)
		if inside then
			local left = driftRes.FractionLeftSolid
			if left and left > 0 and left < 1 and left < exit then
				local outX = x + dx * (left * DRIFT_RAY_REACH + EDGE_CHECK_DISTANCE)
				local outY = y + dy * (left * DRIFT_RAY_REACH + EDGE_CHECK_DISTANCE)
				driftHeightTrace.start:SetUnpacked(outX, outY, rayZ)
				driftHeightTrace.endpos:SetUnpacked(x, y, rayZ)
				util.TraceLine(driftHeightTrace)
				if driftHeightRes.Hit and not driftHeightRes.StartSolid and drawnWall(driftHeightRes) then
					exit, skyX, skyY = left, outX, outY
				end
			end
		elseif driftRes.Hit and not driftRes.StartSolid and drawnWall(driftRes) and math.abs(driftRes.HitNormal.z) < DRIFT_WALL_MAX_NZ then
			local n = driftRes.HitNormal
			local hit = driftRes.HitPos
			local d = driftRes.Fraction * DRIFT_RAY_REACH * math.abs(dx * n.x + dy * n.y)
			local drift = driftFromWall(hit.x - n.x * EDGE_CHECK_DISTANCE, hit.y - n.y * EDGE_CHECK_DISTANCE, z)
			local width = math.max(drift * DRIFT_WIDTH_PER_HEIGHT, DRIFT_MIN_WIDTH)
			if drift > 0 and d < width then
				local f = 1 - d / width
				local here = drift * f * f
				if here > lift then
					local slope = 2 * drift * f / width
					lift, gx, gy = here, -n.x * slope, -n.y * slope
				end
			end
		end
	end

	if inside and skyX then
		lift = driftFromWall(x, y, z)
		if lift <= 0 then skyX, skyY = nil, nil end
	end

	return lift, gx, gy, skyX, skyY
end

local function slopedNormal(nx, ny, gx, gy)
	if gx == 0 and gy == 0 then return nx, ny end

	local nz = math.sqrt(math.max(1 - nx * nx - ny * ny, 0))
	nx, ny = nx - gx, ny - gy
	local len = math.sqrt(nx * nx + ny * ny + nz * nz)

	return nx / len, ny / len
end

local function reachesSky(x, y, z, rays)
	local key = cellKey(x, y, z, SKY_CELL)
	local open = rays[key]
	if open == nil then
		skyTrace.start:SetUnpacked(x, y, z)
		skyTrace.endpos:SetUnpacked(x, y, z + SKY_TRACE_DISTANCE)
		local tr = util.TraceLine(skyTrace)
		open = (not tr.Hit or tr.HitSky) and not tr.StartSolid
		rays[key] = open
	end

	return open
end

local function openToSky(x, y, z, rays)
	if not reachesSky(x, y, z, rays) then return false end

	for _, dir in ipairs(SKY_GAP_DIRS) do
		local sx, sy = x + dir[1] * SKY_GAP_REACH, y + dir[2] * SKY_GAP_REACH
		if not reachesSky(sx, sy, z, rays) then
			edgeTrace.start:SetUnpacked(x, y, z)
			edgeTrace.endpos:SetUnpacked(sx, sy, z)
			util.TraceLine(edgeTrace)
			if not edgeRes.Hit then return false end
		end
	end

	return true
end

local function snowAt(x, y, z, nonSnow, cache)
	local cover = 1 - nonSnow / 255
	if cover <= 0 then return 0, 0, 0, 0, 0 end

	local lift, mergeGx, mergeGy, buried = mergeAt(x, y, z)
	local top = buried and z + lift or z
	local driftKey = vertexKey(x, y, z)
	local drift = cache.drift[driftKey]
	if not drift then
		drift = { wallDriftAt(x, y, z) }
		cache.drift[driftKey] = drift
	end

	local skyX, skyY = drift[4] or x, drift[5] or y
	if drift[1] > lift then
		lift, mergeGx, mergeGy = drift[1], drift[2], drift[3]
	end

	local skyKey = cellKey(skyX, skyY, top, SKY_CELL)
	local open = cache.sky[skyKey]
	if open == nil then
		samplePos:SetUnpacked(skyX, skyY, top + 2)
		open = openToSky(skyX, skyY, top + 4, cache.rays) and bit.band(util.PointContents(samplePos), MASK_WATER) == 0
		cache.sky[skyKey] = open
	end

	if not open then return 0, 0, 0, 0, 0 end

	local lightKey = cellKey(skyX, skyY, top, LIGHT_CELL)
	local light = cache.light[lightKey]
	if not light then
		local samples = cache.samples
		local n = #samples
		samples[n + 1], samples[n + 2], samples[n + 3] = skyX, skyY, top + DEPTH + 2
		light = n / 3 + 1
		cache.light[lightKey] = light
	end

	local height, gx, gy = edgeSlopeAt(x, y, z)

	return cover * height, light, (gx + mergeGx) * cover, (gy + mergeGy) * cover, lift * cover
end

local function clipPoly(poly, axis, value, sign)
	local out = {}
	local n = #poly
	for i = 1, n do
		local a, b = poly[i], poly[i % n + 1]
		local da, db = (a[axis] - value) * sign, (b[axis] - value) * sign
		if da >= 0 then out[#out + 1] = a end
		if (da >= 0) ~= (db >= 0) then
			local f = da / (da - db)
			local v = {}
			for k = 1, #a do
				v[k] = a[k] + (b[k] - a[k]) * f
			end
			out[#out + 1] = v
		end
	end

	return out
end

local STRIDE = 7

local function buildVerts(ch)
	local x0, y0 = ch.cx * CHUNK, ch.cy * CHUNK
	local x1, y1 = x0 + CHUNK, y0 + CHUNK
	local cand = bspdata.Candidates(triGrid, x0, y0, x1, y1)
	local cache = { sky = {}, rays = {}, light = {}, samples = {}, drift = {} }
	local groups, order, group = {}, {}
	local zmin, zmax = math.huge, -math.huge
	local yieldIfOverBudget = buildYield

	local function emit(x, y, z, nx, ny, cover, light)
		local v, k = group.verts, group.n
		v[k + 1], v[k + 2], v[k + 3], v[k + 4], v[k + 5], v[k + 6], v[k + 7] = x, y, z, nx, ny, light, cover
		group.n = k + STRIDE
		if z < zmin then zmin = z end
		if z > zmax then zmax = z end
	end

	local function useCluster(x, y, z)
		local c = math.max(bspdata.ClusterAt(x, y, z + DEPTH + 4), -1)
		group = groups[c]
		if not group then
			group = { verts = {}, n = 0 }
			groups[c] = group
			order[#order + 1] = c
		end
	end

	local function emitTri(poly, i1, i2, i3)
		local a, b, c = poly[i1], poly[i2], poly[i3]
		local ca, la, gax, gay, ma = snowAt(a[1], a[2], a[3], a[4], cache)
		local cb, lb, gbx, gby, mb = snowAt(b[1], b[2], b[3], b[4], cache)
		local cc, lc, gcx, gcy, mc = snowAt(c[1], c[2], c[3], c[4], cache)
		if ca + cb + cc <= 0 then return false end

		local nax, nay = slopedNormal(a[5], a[6], gax, gay)
		local nbx, nby = slopedNormal(b[5], b[6], gbx, gby)
		local ncx, ncy = slopedNormal(c[5], c[6], gcx, gcy)
		emit(a[1], a[2], a[3] + ca * DEPTH + ma, nax, nay, ca, la)
		emit(b[1], b[2], b[3] + cb * DEPTH + mb, nbx, nby, cb, lb)
		emit(c[1], c[2], c[3] + cc * DEPTH + mc, ncx, ncy, cc, lc)

		return true
	end

	for _, t in ipairs(cand) do
		if t.vn then
			local vn = t.vn
			local tri = { { t[1], t[2], t[3], t[10], vn[1], vn[2] }, { t[4], t[5], t[6], t[11], vn[3], vn[4] }, { t[7], t[8], t[9], t[12], vn[5], vn[6] } }
			if t[15] - t[13] <= SMALL_TRI and t[16] - t[14] <= SMALL_TRI then
				local mx, my = (t[1] + t[4] + t[7]) / 3, (t[2] + t[5] + t[8]) / 3
				if mx >= x0 and mx < x1 and my >= y0 and my < y1 then
					useCluster(mx, my, (t[3] + t[6] + t[9]) / 3)
					emitTri(tri, 1, 2, 3)
				end

				yieldIfOverBudget()
			else
				local ix0 = math.floor(math.max(t[13], x0) / CELL)
				local ix1 = math.floor((math.min(t[15], x1) - 1e-3) / CELL)
				local iy0 = math.floor(math.max(t[14], y0) / CELL)
				local iy1 = math.floor((math.min(t[16], y1) - 1e-3) / CELL)
				for iy = iy0, iy1 do
					for ix = ix0, ix1 do
						local cx0, cy0 = ix * CELL, iy * CELL
						local poly = clipPoly(tri, 1, cx0, 1)
						if #poly >= 3 then poly = clipPoly(poly, 1, cx0 + CELL, -1) end
						if #poly >= 3 then poly = clipPoly(poly, 2, cy0, 1) end
						if #poly >= 3 then poly = clipPoly(poly, 2, cy0 + CELL, -1) end

						if #poly >= 3 then
							local px, py, pz = 0, 0, 0
							for _, p in ipairs(poly) do
								px, py, pz = px + p[1], py + p[2], pz + p[3]
							end

							useCluster(px / #poly, py / #poly, pz / #poly)
							for k = 2, #poly - 1 do
								emitTri(poly, 1, k, k + 1)
							end
						end

						yieldIfOverBudget()
					end
				end
			end
		end
	end

	for _, e in ipairs(edgeGrid[chunkKey(ch.cx, ch.cy)] or {}) do
		local ax, ay, bx, by = e[1], e[2], e[5], e[6]
		local dx, dy = bx - ax, by - ay
		local ta, tb = 0, 1
		for _, side in ipairs({ { -dx, ax - x0 }, { dx, x1 - ax }, { -dy, ay - y0 }, { dy, y1 - ay } }) do
			local p, q = side[1], side[2]
			if p == 0 then
				if q < 0 then ta, tb = 1, 0 end
			else
				local r = q / p
				if p < 0 then ta = math.max(ta, r) else tb = math.min(tb, r) end
			end
		end

		if tb > ta then
			local function at(f)
				return ax + dx * f, ay + dy * f, e[3] + (e[7] - e[3]) * f, e[4] + (e[8] - e[4]) * f
			end

			local stops = { tb }
			for _, axis in ipairs({ { ax, dx }, { ay, dy } }) do
				local start, delta = axis[1], axis[2]
				if delta ~= 0 then
					local g0, g1 = start + delta * ta, start + delta * tb
					for line = math.ceil(math.min(g0, g1) / CELL), math.floor(math.max(g0, g1) / CELL) do
						local f = (line * CELL - start) / delta
						if f > ta + 1e-4 and f < tb - 1e-4 then stops[#stops + 1] = f end
					end
				end
			end

			table.sort(stops)

			local px, py, pz, pa = at(ta)
			local pc, pl, _, _, pm = snowAt(px, py, pz, pa, cache)
			for _, stop in ipairs(stops) do
				local qx, qy, qz, qa = at(stop)
				local qc, ql, _, _, qm = snowAt(qx, qy, qz, qa, cache)
				local mx, my, mz = (px + qx) * 0.5, (py + qy) * 0.5, (pz + qz) * 0.5
				local covered = dropsToSnow(triGrid, mx, my, mz, e[9], e[10]) and snowBelow(triGrid, mx - e[9] * EDGE_CHECK_DISTANCE, my - e[10] * EDGE_CHECK_DISTANCE, mz)
				if pc + qc > 0 then
					useCluster(mx, my, mz)
					local sink = covered and MERGE_SKIRT_SINK or 0
					emit(px, py, pz + pc * DEPTH + pm - sink, e[9], e[10], pc, pl)
					emit(qx, qy, qz + qc * DEPTH + qm - sink, e[9], e[10], qc, ql)
					emit(qx, qy, qz - SKIRT_DEPTH, e[9], e[10], 0, ql)
					emit(px, py, pz + pc * DEPTH + pm - sink, e[9], e[10], pc, pl)
					emit(qx, qy, qz - SKIRT_DEPTH, e[9], e[10], 0, ql)
					emit(px, py, pz - SKIRT_DEPTH, e[9], e[10], 0, pl)
				end

				px, py, pz, pc, pl, pm = qx, qy, qz, qc, ql, qm
			end
		end

		yieldIfOverBudget()
	end

	table.sort(order)
	local verts, n, clusters, clusterTris = {}, 0, {}, {}
	for _, c in ipairs(order) do
		local g = groups[c]
		if g.n > 0 then
			local v = g.verts
			for i = 1, g.n do
				verts[n + i] = v[i]
			end

			n = n + g.n
			clusters[#clusters + 1] = c
			clusterTris[#clusterTris + 1] = g.n / STRIDE / 3
		end

		yieldIfOverBudget()
	end

	ch.clusters, ch.clusterTris, ch.samples = clusters, clusterTris, cache.samples
	ch.cz = (zmin + zmax) * 0.5
	local hz = (zmax - zmin) * 0.5
	ch.radius = math.sqrt(CHUNK * CHUNK * 0.5 + hz * hz)

	return verts, n / STRIDE / 3
end

-- JIT compilation made these functions run ~x4 times slower on macos through wine/rosetta
-- I'm assuming this is primarily due to rosetta, needs testing on windows before enabling
--for _, fn in ipairs({ vertexKey, snowBelow, dropsToSnow, cellKey, edgeSlopeAt, mergeAt, drawnWall, driftFromWall, wallDriftAt, slopedNormal, reachesSky, openToSky, snowAt, clipPoly, buildVerts }) do
--	jit.off(fn, true)
--end

local cacheDir

local function cacheKey()
	local map = "maps/" .. game.GetMap() .. ".bsp"

	return string.lower(string.format("%s_%d_v%d", game.GetMap(), file.Size(map, "GAME") or 0, CACHE_VERSION))
end

local function staleCache(name)
	local map = "^" .. string.PatternSafe(game.GetMap():lower())

	return name:find(map .. "_%d+_v%d+$") or name:find(map .. "_%d+_%d+_%d+_%d+$")
end

local function pruneCache(key)
	local yieldIfOverBudget = bspdata.FrameBudget()
	local _, dirs = file.Find(CACHE_DIR .. "/*", "DATA")
	for _, dir in ipairs(dirs or {}) do
		if dir ~= key and staleCache(dir) then
			local path = CACHE_DIR .. "/" .. dir
			for _, name in ipairs((file.Find(path .. "/*", "DATA"))) do
				file.Delete(path .. "/" .. name)
				yieldIfOverBudget()
			end

			file.Delete(path)
		end
	end
end

local function cachePath(ch)
	return cacheDir .. "/" .. ch.cx .. "_" .. ch.cy .. ".dat"
end

local function packCoord(v)
	local n = math.floor(v * CACHE_COORD_SCALE + 0.5) + CACHE_COORD_OFFSET

	return n % 256, math.floor(n / 256) % 256, math.floor(n / 65536)
end

local function unpackCoord(a, b, c)
	return (a + b * 256 + c * 65536 - CACHE_COORD_OFFSET) / CACHE_COORD_SCALE
end

local function packNormal(v)
	local n = math.floor((v + 1) * CACHE_NORMAL_SCALE + 0.5)

	return n % 256, math.floor(n / 256)
end

local function encodeChunk(ch, verts, tris)
	if tris == 0 then return CACHE_EMPTY end

	local char = string.char
	local z1, z2, z3 = packCoord(ch.cz)
	local r1, r2, r3 = packCoord(ch.radius)
	local clusterCount, sampleCount = #ch.clusters, #ch.samples / 3
	local parts = {
		char(tris % 256, math.floor(tris / 256) % 256, math.floor(tris / 65536) % 256, math.floor(tris / 16777216)),
		char(z1, z2, z3, r1, r2, r3, clusterCount % 256, math.floor(clusterCount / 256), sampleCount % 256, math.floor(sampleCount / 256) % 256, math.floor(sampleCount / 65536)),
	}
	for i, c in ipairs(ch.clusters) do
		local id, count = c + 1, ch.clusterTris[i]
		parts[#parts + 1] = char(id % 256, math.floor(id / 256), count % 256, math.floor(count / 256) % 256, math.floor(count / 65536))
	end

	for i = 1, sampleCount * 3, 3 do
		local xa, xb, xc = packCoord(ch.samples[i])
		local ya, yb, yc = packCoord(ch.samples[i + 1])
		local za, zb, zc = packCoord(ch.samples[i + 2])
		parts[#parts + 1] = char(xa, xb, xc, ya, yb, yc, za, zb, zc)
	end

	local o = 0
	for i = 1, tris * 3 do
		local xa, xb, xc = packCoord(verts[o + 1])
		local ya, yb, yc = packCoord(verts[o + 2])
		local za, zb, zc = packCoord(verts[o + 3])
		local n1, n2 = packNormal(verts[o + 4])
		local n3, n4 = packNormal(verts[o + 5])
		local light = verts[o + 6]
		parts[#parts + 1] = char(xa, xb, xc, ya, yb, yc, za, zb, zc, n1, n2, n3, n4, light % 256, math.floor(light / 256) % 256, math.floor(light / 65536), math.floor(verts[o + 7] * 255 + 0.5))
		o = o + STRIDE
		if i % CACHE_YIELD_VERTS == 0 then buildYield() end
	end

	return util.Compress(table.concat(parts))
end

local function blobPath(key)
	return CACHE_DIR .. "/" .. key .. ".dat"
end

local function pruneBlobs(key)
	for _, name in ipairs((file.Find(CACHE_DIR .. "/*", "DATA"))) do
		local base = name:match("^(.+)%.dat$")
		if base and base ~= key and staleCache(base) then
			file.Delete(CACHE_DIR .. "/" .. name)
		end
	end
end

if SERVER then
	util.AddNetworkString(BAKE_NET)

	local BAKE_ON_LISTEN = CreateConVar("borealis_snowcover_bake_listen", "0", FCVAR_ARCHIVE, "server: bake snow chunks on listen servers too, where the bake shares a process with the game")
	local key, blob, bakeCo, hibernateValue, fatId
	local waiting, sends, served, announced = {}, {}, {}, {}
	local sendQueue, sendCount = {}, 0
	local fatOwner = {}
	local downloadUrl = GetConVar("sv_downloadurl")

	local function announce(ply)
		announced[ply] = true
		net.Start(BAKE_NET)
		net.WriteUInt(MSG_KEY, 2)
		net.WriteString(key)
		net.WriteUInt(#blob, 32)
		net.Send(ply)
	end

	local function ready(data)
		blob = data
		if fatdl and downloadUrl:GetString() ~= "" then
			fatId = fatdl.Write(BAKE_NET, data, nil, { fatOwner })
		end

		for ply in pairs(waiting) do
			if IsValid(ply) then announce(ply) end
		end

		waiting = {}
	end

	local function chunkList()
		local seen, list = {}, {}
		for _, cell in pairs(triGrid) do
			for _, t in ipairs(cell) do
				if t.vn then
					for cy = math.floor(t[14] / CHUNK), math.floor(t[16] / CHUNK) do
						for cx = math.floor(t[13] / CHUNK), math.floor(t[15] / CHUNK) do
							local k = chunkKey(cx, cy)
							if not seen[k] then
								seen[k] = true
								list[#list + 1] = { cx = cx, cy = cy }
							end
						end
					end
				end
			end

			buildYield()
		end

		return list
	end

	local function assemble(list)
		local header, body = {}, {}
		local char = string.char
		for _, ch in ipairs(list) do
			local raw = file.Read(cachePath(ch), "DATA")
			if raw and raw ~= CACHE_EMPTY then
				local x, y, len = ch.cx + 32768, ch.cy + 32768, #raw
				header[#header + 1] = char(x % 256, math.floor(x / 256), y % 256, math.floor(y / 256), len % 256, math.floor(len / 256) % 256, math.floor(len / 65536) % 256, math.floor(len / 16777216))
				body[#body + 1] = raw
			end

			buildYield()
		end

		local count = #header

		return char(count % 256, math.floor(count / 256) % 256, math.floor(count / 65536) % 256, math.floor(count / 16777216)) .. table.concat(header) .. table.concat(body)
	end

	local function bake()
		file.CreateDir(cacheDir)
		pruneCache(key)
		pruneBlobs(key)

		local vis, why = bspdata.WaitVis()
		if not vis then return nil, why end

		local ok
		ok, why = loadGeometry()
		if not ok then return nil, why end

		local list = chunkList()
		for _, ch in ipairs(list) do
			if file.Size(cachePath(ch), "DATA") <= 0 then
				local verts, tris = buildVerts(ch)
				file.Write(cachePath(ch), encodeChunk(ch, verts, tris))
			end

			buildYield()
		end

		local data = assemble(list)
		file.Write(blobPath(key), data)
		for _, ch in ipairs(list) do
			file.Delete(cachePath(ch))
			buildYield()
		end

		file.Delete(cacheDir)
		triGrid, edgeGrid, snowEndGrid, snowMergeGrid = nil, nil, nil, nil
		bspdata.vis = nil

		return data
	end

	local lastBake = 0

	local function think()
		if bakeCo and SysTime() - lastBake >= engine.TickInterval() and collectgarbage("count") / 1024 < BAKE_MEMORY_MB then
			bakeStart = SysTime()
			bakeBudget = player.GetCount() == 0 and BAKE_EMPTY_MS or engine.TickInterval() * 1000 * BAKE_PLAYERS_TICK_SHARE
			local ok, data, why = coroutine.resume(bakeCo)
			lastBake = SysTime()
			if not ok or coroutine.status(bakeCo) == "dead" then
				bakeCo = nil
				RunConsoleCommand("sv_hibernate_think", hibernateValue)
				if ok and data then
					ready(data)
				else
					ErrorNoHalt("[snowcover] bake failed: " .. tostring(ok and why or data) .. "\n")
				end
			end
		end

		while sendCount < BAKE_MAX_SENDS and #sendQueue > 0 do
			local ply = table.remove(sendQueue, 1)
			if IsValid(ply) then
				sends[ply] = { offset = 0, at = 0 }
				sendCount = sendCount + 1
			end
		end

		local now = RealTime()
		for ply, send in pairs(sends) do
			if not IsValid(ply) then
				sends[ply] = nil
				sendCount = sendCount - 1
			elseif now >= send.at then
				local data = string.sub(blob, send.offset + 1, send.offset + BAKE_SEND_BYTES)
				net.Start(BAKE_NET)
				net.WriteUInt(MSG_CHUNK, 2)
				net.WriteUInt(#data, 16)
				net.WriteData(data, #data)
				net.Send(ply)
				send.offset = send.offset + #data
				send.at = now + #data / BAKE_SEND_RATE
				if send.offset >= #blob then
					sends[ply] = nil
					sendCount = sendCount - 1
				end
			end
		end
	end

	net.Receive(BAKE_NET, function(_, ply)
		if not blob or not announced[ply] or not ply:IsFullyAuthenticated() then return end

		announced[ply] = nil
		local id, now = ply:SteamID64(), RealTime()
		if (served[id] or 0) > now then return end

		for other, expiry in pairs(served) do
			if expiry <= now then served[other] = nil end
		end

		served[id] = now + BAKE_REQUEST_COOLDOWN
		if fatId then
			fatdl.Send(BAKE_NET, ply, nil, fatId)
		else
			sendQueue[#sendQueue + 1] = ply
		end
	end)

	hook.Add("PlayerDisconnected", BAKE_NET, function(ply)
		announced[ply], waiting[ply] = nil, nil
		for i = #sendQueue, 1, -1 do
			if sendQueue[i] == ply then table.remove(sendQueue, i) end
		end
	end)

	local function connected(ply)
		if blob then
			announce(ply)
		elseif key then
			waiting[ply] = true
		end
	end

	local function start()
		if shaderpack.Season() ~= "winter" then return end

		key = cacheKey()
		if not key then return end

		cacheDir = CACHE_DIR .. "/" .. key
		hook.Add("Think", BAKE_NET, think)
		local data = file.Read(blobPath(key), "DATA")
		if data then
			ready(data)
		elseif game.IsDedicated() or BAKE_ON_LISTEN:GetBool() then
			hibernateValue = GetConVar("sv_hibernate_think"):GetString()
			RunConsoleCommand("sv_hibernate_think", "1")
			bakeCo = coroutine.create(bake)
		end
	end

	shaderpack.OnPlayerReady(BAKE_NET, connected)

	if game.GetWorld():IsWorld() then
		start()
		for _, ply in ipairs(player.GetHumans()) do
			connected(ply)
		end
	else
		hook.Add("Initialize", BAKE_NET, start)
	end

	return
end

local blobFile, blobIndex
local blobPending

local function useBlob(key, size)
	local path = blobPath(key)
	if file.Size(path, "DATA") ~= size then return false end

	local f = file.Open(path, "rb", "DATA")
	if not f then return false end

	local byte = string.byte
	local c1, c2, c3, c4 = byte(f:Read(CACHE_COUNT_BYTES) or "", 1, 4)
	if not c4 then
		f:Close()

		return false
	end

	local count = c1 + c2 * 256 + c3 * 65536 + c4 * 16777216
	if CACHE_COUNT_BYTES + count * BAKE_ENTRY_BYTES > size then
		f:Close()

		return false
	end

	local header = count > 0 and f:Read(count * BAKE_ENTRY_BYTES) or ""
	local index, list = {}, {}
	local offset = CACHE_COUNT_BYTES + count * BAKE_ENTRY_BYTES
	for i = 0, count - 1 do
		local x1, x2, y1, y2, l1, l2, l3, l4 = byte(header, i * BAKE_ENTRY_BYTES + 1, i * BAKE_ENTRY_BYTES + BAKE_ENTRY_BYTES)
		local len = l1 + l2 * 256 + l3 * 65536 + l4 * 16777216
		local cx, cy = x1 + x2 * 256 - 32768, y1 + y2 * 256 - 32768
		index[chunkKey(cx, cy)] = { offset, len }
		list[#list + 1] = { cx = cx, cy = cy }
		offset = offset + len
	end

	if offset ~= size then
		f:Close()

		return false
	end

	if blobFile then blobFile:Close() end
	blobFile, blobIndex = f, index
	if PRELOAD then grid:Preload(list) end

	return true
end

local function blobReceived(data)
	local key, size = blobPending.key, blobPending.size
	blobPending = nil
	if #data ~= size then return end

	if blobFile then
		blobFile:Close()
		blobFile, blobIndex = nil, nil
	end

	file.CreateDir(CACHE_DIR)
	pruneBlobs(key)
	file.Write(blobPath(key), data)
	useBlob(key, #data)
end

local function receiveFatdl()
	fatdl.Receive(BAKE_NET, function(data)
		if blobPending then blobReceived(data) end
	end)
end

if fatdl then
	receiveFatdl()
else
	hook.Add("Initialize", BAKE_NET, function()
		if fatdl then receiveFatdl() end
	end)
end

net.Receive(BAKE_NET, function()
	local kind = net.ReadUInt(2)
	if kind == MSG_KEY then
		local key, size = net.ReadString(), net.ReadUInt(32)
		if not key:find("^[%w_%-]+$") or size <= 0 or size > BAKE_MAX_BYTES then return end
		if useBlob(key, size) or shaderpack.Season() ~= "winter" then return end

		blobPending = { key = key, size = size, parts = {}, got = 0 }
		net.Start(BAKE_NET)
		net.SendToServer()
	elseif kind == MSG_CHUNK and blobPending then
		local data = net.ReadData(net.ReadUInt(16))
		blobPending.parts[#blobPending.parts + 1] = data
		blobPending.got = blobPending.got + #data
		if blobPending.got >= blobPending.size then
			blobReceived(table.concat(blobPending.parts))
		end
	end
end)

local function chunkBytes(ch)
	if blobIndex then
		local entry = blobIndex[chunkKey(ch.cx, ch.cy)]
		if not entry then return CACHE_EMPTY end

		blobFile:Seek(entry[1])

		return blobFile:Read(entry[2])
	end

	return cacheDir and file.Read(cachePath(ch), "DATA")
end

local function readCached(ch)
	local raw = chunkBytes(ch)
	if not raw or #raw < CACHE_COUNT_BYTES then return end
	if raw == CACHE_EMPTY then return {}, 0 end

	local data = util.Decompress(raw)
	if not data or #data < CACHE_COUNT_BYTES + CACHE_HEADER_BYTES then return end

	local byte = string.byte
	local t1, t2, t3, t4, z1, z2, z3, r1, r2, r3, c1, c2, s1, s2, s3 = byte(data, 1, CACHE_COUNT_BYTES + CACHE_HEADER_BYTES)
	local tris = t1 + t2 * 256 + t3 * 65536 + t4 * 16777216
	local clusterCount, sampleCount = c1 + c2 * 256, s1 + s2 * 256 + s3 * 65536
	local p = CACHE_COUNT_BYTES + CACHE_HEADER_BYTES
	if #data ~= p + clusterCount * CACHE_CLUSTER_BYTES + sampleCount * CACHE_SAMPLE_BYTES + tris * 3 * CACHE_VERTEX_BYTES then return end

	local clusters, clusterTris, grouped = {}, {}, 0
	for i = 1, clusterCount do
		local lo, hi, n1, n2, n3 = byte(data, p + 1, p + CACHE_CLUSTER_BYTES)
		clusters[i], clusterTris[i] = lo + hi * 256 - 1, n1 + n2 * 256 + n3 * 65536
		grouped = grouped + clusterTris[i]
		p = p + CACHE_CLUSTER_BYTES
	end

	if grouped ~= tris then return end

	local samples = {}
	for i = 1, sampleCount * 3, 3 do
		local xa, xb, xc, ya, yb, yc, za, zb, zc = byte(data, p + 1, p + CACHE_SAMPLE_BYTES)
		samples[i], samples[i + 1], samples[i + 2] = unpackCoord(xa, xb, xc), unpackCoord(ya, yb, yc), unpackCoord(za, zb, zc)
		p = p + CACHE_SAMPLE_BYTES
	end

	local yieldIfOverBudget = chunks.YieldIfOverBudget
	local verts = {}
	local o = 0
	for i = 1, tris * 3 do
		local xa, xb, xc, ya, yb, yc, za, zb, zc, n1, n2, n3, n4, l1, l2 = byte(data, p + 1, p + 15)
		local l3, cover = byte(data, p + 16, p + 17)
		verts[o + 1], verts[o + 2], verts[o + 3] = unpackCoord(xa, xb, xc), unpackCoord(ya, yb, yc), unpackCoord(za, zb, zc)
		verts[o + 4], verts[o + 5] = (n1 + n2 * 256) / CACHE_NORMAL_SCALE - 1, (n3 + n4 * 256) / CACHE_NORMAL_SCALE - 1
		verts[o + 6], verts[o + 7] = l1 + l2 * 256 + l3 * 65536, cover / 255
		p, o = p + CACHE_VERTEX_BYTES, o + STRIDE
		if i % CACHE_YIELD_VERTS == 0 then yieldIfOverBudget() end
	end

	ch.cz, ch.radius, ch.clusters, ch.clusterTris, ch.samples = unpackCoord(z1, z2, z3), unpackCoord(r1, r2, r3), clusters, clusterTris, samples

	return verts, tris
end

local function writeCached(ch, verts, tris)
	if not cacheDir or blobIndex then return end

	file.Write(cachePath(ch), encodeChunk(ch, verts, tris))
end

local resolveLights
do
	local LIGHT_REFINE_CELL, LIGHT_REFINE_DIFF = 64, 4
	local LIGHT_NEIGHBOURS = {}
	for dz = -1, 1 do
		for dy = -1, 1 do
			for dx = -1, 1 do
				if dx ~= 0 or dy ~= 0 or dz ~= 0 then
					LIGHT_NEIGHBOURS[#LIGHT_NEIGHBOURS + 1] = cellKey(dx * LIGHT_REFINE_CELL, dy * LIGHT_REFINE_CELL, dz * LIGHT_REFINE_CELL, LIGHT_REFINE_CELL) - cellKey(0, 0, 0, LIGHT_REFINE_CELL)
				end
			end
		end
	end

	local function lightDiff(a, b)
		return math.max(math.abs(math.floor(a / 65536) - math.floor(b / 65536)), math.abs(math.floor(a / 256) % 256 - math.floor(b / 256) % 256), math.abs(a % 256 - b % 256))
	end

	function resolveLights(ch, verts, tris)
		local yieldIfOverBudget = chunks.YieldIfOverBudget
		local samples, lights, cellOf, reps, far, farDist, refine = ch.samples, {}, {}, {}, {}, {}, {}
		local count, computed = #samples / 3, 0

		local function compute(i)
			local at = i * 3
			samplePos:SetUnpacked(samples[at - 2], samples[at - 1], samples[at])
			local l, d = render.ComputeLighting(samplePos, UP), render.ComputeDynamicLighting(samplePos, UP)
			lights[i] = math.Clamp(math.floor((l.x - d.x) * 127.5), 0, 255) * 65536 + math.Clamp(math.floor((l.y - d.y) * 127.5), 0, 255) * 256 + math.Clamp(math.floor((l.z - d.z) * 127.5), 0, 255)
			computed = computed + 1
			if computed % CACHE_YIELD_VERTS == 0 then yieldIfOverBudget() end
		end

		for i = 1, count do
			local at = i * 3
			local x, y, z = samples[at - 2], samples[at - 1], samples[at]
			local key = cellKey(x, y, z, LIGHT_REFINE_CELL)
			cellOf[i] = key
			local rep = reps[key]
			if not rep then
				reps[key] = i
				compute(i)
			else
				local ra = rep * 3
				local dx, dy, dz = x - samples[ra - 2], y - samples[ra - 1], z - samples[ra]
				local dist = dx * dx + dy * dy + dz * dz
				if not far[key] or dist > farDist[key] then
					far[key], farDist[key] = i, dist
				end
			end
		end

		for key, i in pairs(reps) do
			local light, other = lights[i], far[key]
			if other then
				compute(other)
				refine[key] = lightDiff(light, lights[other]) > LIGHT_REFINE_DIFF
			end

			if not refine[key] then
				for _, offset in ipairs(LIGHT_NEIGHBOURS) do
					local nb = reps[key + offset]
					if nb and lightDiff(light, lights[nb]) > LIGHT_REFINE_DIFF then
						refine[key] = true
						break
					end
				end
			end
		end

		for i = 1, count do
			if not lights[i] then
				local key = cellOf[i]
				if refine[key] then
					compute(i)
				else
					lights[i] = lights[reps[key]]
				end
			end
		end

		for o = 6, tris * 3 * STRIDE, STRIDE do
			verts[o] = lights[verts[o]] or 0
		end

		ch.samples = nil
	end
end

local vpos, vnormal = Vector(), Vector()

local function markSteps(steps, verts, o)
	local a, b, c = o, o + STRIDE, o + STRIDE * 2
	local x0, x1 = math.min(verts[a + 1], verts[b + 1], verts[c + 1]), math.max(verts[a + 1], verts[b + 1], verts[c + 1])
	local y0, y1 = math.min(verts[a + 2], verts[b + 2], verts[c + 2]), math.max(verts[a + 2], verts[b + 2], verts[c + 2])
	local z0, z1 = math.min(verts[a + 3], verts[b + 3], verts[c + 3]), math.max(verts[a + 3], verts[b + 3], verts[c + 3])
	local ix, iy = math.floor(x0 / CELL), math.floor(y0 / CELL)
	for x = ix, math.max(ix, math.ceil(x1 / CELL) - 1) do
		for y = iy, math.max(iy, math.ceil(y1 / CELL) - 1) do
			for z = math.floor(z0 / CELL), math.floor(z1 / CELL) do
				steps[cellKey(x * CELL, y * CELL, z * CELL, CELL)] = true
			end
		end
	end
end

local function buildChunk(ch)
	local verts, tris = readCached(ch)
	if not verts then
		if not triGrid then
			local ok, why = loadGeometry()
			if not ok then error(why) end
		end

		verts, tris = buildVerts(ch)
		writeCached(ch, verts, tris)
	end

	if tris > 0 then resolveLights(ch, verts, tris) end

	local groups, steps = {}, {}
	ch.groups = groups
	local o = 0
	for i, cluster in ipairs(tris > 0 and ch.clusters or {}) do
		local left = ch.clusterTris[i]
		local first, last = o, o + (left * 3 - 1) * STRIDE
		local g = {
			cluster = cluster, meshes = {}, x = 0, y = 0, z = 0,
			ax = verts[first + 1], ay = verts[first + 2], az = verts[first + 3] + SIGHT_RAISE,
			bx = verts[last + 1], by = verts[last + 2], bz = verts[last + 3] + SIGHT_RAISE,
		}
		groups[i] = g

		while left > 0 do
			chunks.YieldIfOverBudget()
			local count = math.min(left, MESH_TRIS)
			local m = Mesh()
			mesh.Begin(m, MATERIAL_TRIANGLES, count)
			for k = 1, count * 3 do
				local light = verts[o + 6]
				local nx, ny = verts[o + 4], verts[o + 5]
				g.x, g.y, g.z = g.x + verts[o + 1], g.y + verts[o + 2], g.z + verts[o + 3]
				vpos:SetUnpacked(verts[o + 1], verts[o + 2], verts[o + 3])
				if k % 3 == 1 then markSteps(steps, verts, o) end
				vnormal:SetUnpacked(nx, ny, math.sqrt(math.max(1 - nx * nx - ny * ny, 0)))
				mesh.Position(vpos)
				mesh.Normal(vnormal)
				mesh.TexCoord(0, nx, ny)
				mesh.Color(math.floor(light / 65536), math.floor(light / 256) % 256, light % 256, math.floor(verts[o + 7] * 255 + 0.5))
				mesh.AdvanceVertex()
				o = o + STRIDE
			end
			mesh.End()
			g.meshes[#g.meshes + 1] = m
			left = left - count
		end

		local n = ch.clusterTris[i] * 3
		g.x, g.y, g.z = g.x / n, g.y / n, g.z / n + SIGHT_RAISE
	end
	ch.steps = steps

	return tris
end

local function load()
	local vis, why = bspdata.WaitVis()
	if not vis then return false, why end

	local key = cacheKey()
	cacheDir = key and CACHE_DIR .. "/" .. key or nil
	if key then
		file.CreateDir(cacheDir)
		pruneCache(key)
	end

	return true
end

local function destroyChunk(ch)
	for _, g in ipairs(ch.groups or {}) do
		for _, m in ipairs(g.meshes) do
			m:Destroy()
		end
	end
	ch.groups, ch.steps = nil, nil
end

local trailRT, stampRT, winX, winY
local stampMat, blurMat
local capturing = false

local function eachRTRect(X0, Y0, w, h, fn)
	local px, py = X0 % TRAIL_TEXELS, Y0 % TRAIL_TEXELS
	local w1, h1 = math.min(w, TRAIL_TEXELS - px), math.min(h, TRAIL_TEXELS - py)
	fn(px, py, w1, h1, 0, 0)
	if w1 < w then fn(0, py, w - w1, h1, w1, 0) end
	if h1 < h then fn(px, 0, w1, h - h1, 0, h1) end
	if w1 < w and h1 < h then fn(0, 0, w - w1, h - h1, w1, h1) end
end

local function clearRect(px, py, w, h)
	render.SetViewPort(px, py, w, h)
	render.Clear(0, 0, 0, 0)
end

local function recentre(eye)
	local half = TRAIL_TEXELS / 2
	local cx = math.floor(eye.x / TEXEL / TRAIL_STEP + 0.5) * TRAIL_STEP - half
	local cy = math.floor(-eye.y / TEXEL / TRAIL_STEP + 0.5) * TRAIL_STEP - half
	if cx == winX and cy == winY then return end

	render.PushRenderTarget(trailRT)
	if not winX or math.abs(cx - winX) >= TRAIL_TEXELS or math.abs(cy - winY) >= TRAIL_TEXELS then
		render.Clear(0, 0, 0, 0)
	else
		local dx, dy = cx - winX, cy - winY
		if dx > 0 then
			eachRTRect(winX + TRAIL_TEXELS, cy, dx, TRAIL_TEXELS, clearRect)
		elseif dx < 0 then
			eachRTRect(cx, cy, -dx, TRAIL_TEXELS, clearRect)
		end

		if dy > 0 then
			eachRTRect(cx, winY + TRAIL_TEXELS, TRAIL_TEXELS, dy, clearRect)
		elseif dy < 0 then
			eachRTRect(cx, cy, TRAIL_TEXELS, -dy, clearRect)
		end

		render.SetViewPort(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)
	end
	render.PopRenderTarget()
	winX, winY = cx, cy
end

local nextRefill = 0

local function refill()
	local now = RealTime()
	if now < nextRefill then return end
	nextRefill = now + REFILL_INTERVAL

	local snow = tod and tod.snow and tod.snow.amount or 0
	local dec = (1 / REFILL_TIME + snow / SNOWFALL_TIME) * REFILL_INTERVAL
	local c, err = 1, math.huge
	for v = 1, 255 do
		local e = math.abs(toLinear(v) - dec)
		if e > err then break end
		c, err = v, e
	end

	render.PushRenderTarget(trailRT)
	cam.Start2D()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_REVERSE_SUBTRACT, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
	surface.SetDrawColor(c, c, c, 255)
	surface.DrawRect(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	surface.SetDrawColor(0, 0, 0, 255)
	surface.DrawRect(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)
	render.OverrideBlend(false)
	cam.End2D()
	render.PopRenderTarget()
end

local candidates, nextGather = {}, 0

local function printable(e)
	if not IsValid(e) or e:IsDormant() or e:GetNoDraw() or (e:GetModel() or "") == "" then return false end
	if e:IsPlayer() then return e:Alive() and not e:InVehicle() end
	if e:IsNPC() or e:IsNextBot() or e:IsRagdoll() or e:IsVehicle() or e:GetClass() == "prop_physics" then return true end

	local parent = e:GetParent()

	return IsValid(parent) and printable(parent)
end

local function gather(eye)
	local now = RealTime()
	if now < nextGather then return end
	nextGather = now + GATHER_INTERVAL

	local half = TRAIL_SPAN / 2
	candidates = {}
	for _, e in ipairs(ents.FindInBox(eye - Vector(half, half, half), eye + Vector(half, half, half))) do
		if printable(e) then candidates[#candidates + 1] = e end
	end
end

local captureView = { type = "3D", origin = Vector(), angles = Angle(90, 90, 0), znear = 1, zfar = CAPTURE_HEIGHT * 2, ortho = {} }
local groundRes = {}
local groundTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = groundRes }
local CLIP_NORMAL = Vector(0, 0, -1)

local stamps = {}
local lastStamp = {}

hook.Add("EntityRemoved", "borealis_snowcover", function(e)
	lastStamp[e] = nil
end)

local function stampRect(e)
	if not printable(e) then return end

	local now = RealTime()
	local pos, ang = e:GetPos(), e:GetAngles()
	local last = lastStamp[e]
	if last and now - last.t < RESTAMP_INTERVAL and last.pos == pos and last.ang == ang then return end

	local mins, maxs = e:WorldSpaceAABB()
	local mx, my = (mins.x + maxs.x) * 0.5, (mins.y + maxs.y) * 0.5
	groundTrace.start:SetUnpacked(mx, my, mins.z + DEPTH)
	groundTrace.endpos:SetUnpacked(mx, my, mins.z - DEPTH * 2)
	util.TraceLine(groundTrace)
	if not groundRes.Hit then return end

	local top = groundRes.HitPos.z + DEPTH
	if mins.z > top then return end

	local X0 = math.max(math.floor(mins.x / TEXEL) - CAPTURE_PAD, winX)
	local X1 = math.min(math.ceil(maxs.x / TEXEL) + CAPTURE_PAD, winX + TRAIL_TEXELS)
	local Y0 = math.max(math.floor(-maxs.y / TEXEL) - CAPTURE_PAD, winY)
	local Y1 = math.min(math.ceil(-mins.y / TEXEL) + CAPTURE_PAD, winY + TRAIL_TEXELS)
	if X1 <= X0 or Y1 <= Y0 then return end

	lastStamp[e] = { t = now, pos = pos, ang = ang }

	return { e = e, top = top, X0 = X0, Y0 = Y0, w = X1 - X0, h = Y1 - Y0 }
end

local function drawStamp(s)
	render.PushCustomClipPlane(CLIP_NORMAL, -s.top)
	eachRTRect(s.X0, s.Y0, s.w, s.h, function(px, py, w, h, ox, oy)
		local hw, hh = w * TEXEL * 0.5, h * TEXEL * 0.5
		captureView.x, captureView.y, captureView.w, captureView.h = px, py, w, h
		captureView.origin:SetUnpacked((s.X0 + ox) * TEXEL + hw, -((s.Y0 + oy) * TEXEL + hh), s.top + CAPTURE_HEIGHT)
		local ortho = captureView.ortho
		ortho.left, ortho.right, ortho.top, ortho.bottom = -hw, hw, -hh, hh
		cam.Start(captureView)
		s.e:DrawModel()
		cam.End()
	end)
	render.PopCustomClipPlane()
end

local function blurRect(px, py, w, h)
	surface.DrawTexturedRect(px, py, w, h)
end

local function capture()
	local n = 0
	for _, e in ipairs(candidates) do
		local ok, s = pcall(stampRect, e)
		if ok and s then
			n = n + 1
			stamps[n] = s
		end
	end

	for i = #stamps, n + 1, -1 do
		stamps[i] = nil
	end

	if n == 0 then return end

	render.PushRenderTarget(stampRT)
	for i = 1, n do
		local s = stamps[i]
		eachRTRect(s.X0 - STAMP_BLUR, s.Y0 - STAMP_BLUR, s.w + STAMP_BLUR * 2, s.h + STAMP_BLUR * 2, clearRect)
	end
	render.SetViewPort(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)

	render.MaterialOverride(stampMat)
	render.SuppressEngineLighting(true)
	local clipping = render.EnableClipping(true)
	capturing = true
	for i = 1, n do
		local ok, err = pcall(drawStamp, stamps[i])
		if not ok then ErrorNoHalt("[snowcover] capture: " .. tostring(err) .. "\n") end
	end
	capturing = false
	render.EnableClipping(clipping)
	render.SuppressEngineLighting(false)
	render.MaterialOverride()
	render.PopRenderTarget()

	render.PushRenderTarget(trailRT)
	cam.Start2D()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.SetMaterial(blurMat)
	for i = 1, n do
		local s = stamps[i]
		eachRTRect(s.X0, s.Y0, s.w, s.h, blurRect)
	end
	render.OverrideBlend(false)
	cam.End2D()
	render.PopRenderTarget()
end

local function prepare()
	if not trailRT or paused then return end

	local eye = EyePos()
	recentre(eye)
	refill()
	gather(eye)
	capture()
end

local MAT, DEPTH_MAT, FLASHLIGHT_MAT
local materialSerial = 0
local extra = Matrix()

local function skyTint(tonemap)
	local procsky = shaderpack.procsky
	if procsky and procsky.GetSkyColors then
		local _, z = procsky.GetSkyColors()

		return z[1] * tonemap, z[2] * tonemap, z[3] * tonemap
	end

	local r, g, b = render.GetFogColor()

	return toLinear(r) * tonemap, toLinear(g) * tonemap, toLinear(b) * tonemap
end

local visible = {}
local visibleCount = 0
local sight = chunks.Sight()

local function drawVisible()
	render.SetMaterial(FLASHLIGHT_MAT)
	for i = 1, visibleCount do
		visible[i]:Draw()
	end
end

local function draw(depth, _, sky3d)
	if paused or not grid.ready or depth or sky3d or render.GetRenderTarget() then return end

	local view = chunks.View()
	local eye = view.eye
	sight:Begin(eye)

	local nvis = 0
	for _, ch in ipairs(grid:Visible(view)) do
		for _, g in ipairs(ch.groups) do
			if sight:Shows(g) then
				for _, m in ipairs(g.meshes) do
					nvis = nvis + 1
					visible[nvis] = m
				end
			end
		end
	end

	for i = #visible, nvis + 1, -1 do
		visible[i] = nil
	end

	if nvis == 0 then return end

	dynamiclights.Update(eye)
	MAT:SetTexture("$basetexture", trailRT)
	MAT:SetTexture("$texture2", dynamiclights.Texture())

	local tonemap = render.GetToneMappingScaleLinear().x
	local amb = render.GetAmbientLightColor()
	local sun = bspdata.BakedSun()
	local winMinX, winMaxX = (winX + 1) * TEXEL, (winX + TRAIL_TEXELS - 1) * TEXEL
	local winMinY, winMaxY = -(winY + TRAIL_TEXELS - 1) * TEXEL, -(winY + 1) * TEXEL
	setConstant(MAT, "$c0", eye.x, eye.y, eye.z, CurTime() % 1000)
	setConstant(MAT, "$c1", winMinX, winMinY, winMaxX, winMaxY)
	setConstant(MAT, "$c2", sun.x, sun.y, sun.z, foliage.WorldLightScale())
	setConstant(MAT, "$c3", packColor(amb.x * FILL_K, amb.y * FILL_K, amb.z * FILL_K), tonemap, fadeStart, fadeEnd)

	local fr, fg, fb = render.GetFogColor()
	local fogStart, fogEnd = render.GetFogDistances()
	local fogMax = render.GetFogMode() == MATERIAL_FOG_NONE and 0 or render.GetFogMaxDensity()
	local sr, sg, sb = skyTint(tonemap)
	extra:SetUnpacked(
		toLinear(fr) * tonemap, toLinear(fg) * tonemap, toLinear(fb) * tonemap, fogStart,
		fogEnd, fogMax, 0, 0,
		sr, sg, sb, 0,
		0, 0, 0, 0
	)
	MAT:SetMatrix("$viewprojmat", extra)

	cam.PushModelMatrix(Matrix(), false)
	render.SetMaterial(MAT)
	render.OverrideDepthEnable(true, true)
	for i = 1, nvis do
		visible[i]:Draw()
	end
	render.OverrideDepthEnable(false, false)

	visibleCount = nvis
	render.RenderFlashlights(drawVisible)

	if DEPTH_MAT and depthslices.BeginDepthWrite() then
		render.SetMaterial(DEPTH_MAT)
		for i = 1, nvis do
			visible[i]:Draw()
		end
		depthslices.EndDepthWrite()
	end
	cam.PopModelMatrix()
end

local winterRemoved = false

local function stop()
	hook.Remove("PreRender", "borealis_snowcover")
	hook.Remove("PostDrawOpaqueRenderables", "borealis_snowcover")
	hook.Remove("ShouldDrawLocalPlayer", "borealis_snowcover")
	grid:Stop()
	triGrid, edgeGrid, snowEndGrid, snowMergeGrid = nil, nil, nil, nil
	winX, winY = nil, nil
end

grid = chunks.Grid({
	name = "snowcover", size = CHUNK, cacheLimit = MESH_CACHE_TRIS,
	load = load, build = buildChunk, destroy = destroyChunk, failed = stop,
})

function snowcover.SetDistance(radius)
	radius = math.Clamp(radius, 1024, chunks.MAX_DISTANCE)
	grid.radius = radius
	fadeStart, fadeEnd = radius * 0.75, radius * 0.95
end

snowcover.SetDistance(DISTANCE:GetInt())

local function start()
	stop()
	if winterRemoved or shaderpack.Season() ~= "winter" then return end

	trailRT = GetRenderTargetEx("borealis_snowcover_trail_" .. TRAIL_TEXELS, TRAIL_TEXELS, TRAIL_TEXELS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA16161616F)
	stampRT = GetRenderTargetEx("borealis_snowcover_stamp_" .. TRAIL_TEXELS, TRAIL_TEXELS, TRAIL_TEXELS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
	local dynamicLightsRT = dynamiclights.Texture()
	if not dynamicLightsRT or not shaderpack.UsableRT(trailRT, TRAIL_TEXELS) or not shaderpack.UsableRT(stampRT, TRAIL_TEXELS) then
		trailRT, stampRT = nil, nil

		return
	end

	materialSerial = materialSerial + 1
	local suffix = os.time() .. "_" .. materialSerial
	stampMat = CreateMaterial("borealis_snowcover_stamp_" .. suffix, "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$model"] = 1,
		["$nocull"] = 1,
		["$ignorez"] = 1,
	})
	blurMat = CreateShaderMaterial("borealis_snowcover_blur_" .. suffix, {
		["$pixshader"] = STAMP_PS,
		["$basetexture"] = stampRT:GetName(),
		["$linearread_basetexture"] = 1,
		["$linearwrite"] = 1,
		["$alpha_blend"] = 0,
	})
	MAT = CreateShaderMaterial("borealis_snowcover_" .. suffix, {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$texture1"] = NOISE,
		["$linearread_basetexture"] = 1,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$linearwrite"] = 0,
		["$alpha_blend"] = 0,
		["$additive"] = 0,
		["$ignorez"] = 0,
		["$depthtest"] = 1,
		["$nocull"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	}, "screenspace_general_8tex")
	blurMat:SetTexture("$basetexture", stampRT)
	DEPTH_MAT = CreateShaderMaterial("borealis_snowcoverdepth_" .. suffix, {
		["$pixshader"] = DEPTH_PS,
		["$vertexshader"] = VS,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
	})
	FLASHLIGHT_MAT = CreateMaterial("borealis_snowcoverflashlight_" .. suffix, "VertexLitGeneric", {
		["$basetexture"] = "color/white",
		["$color2"] = FLASHLIGHT_ALBEDO,
		["$model"] = 1,
		["$nocull"] = 1,
	})

	for _, rt in ipairs({ trailRT, stampRT }) do
		render.PushRenderTarget(rt)
		render.Clear(0, 0, 0, 0)
		render.PopRenderTarget()
	end

	grid:Start()
	hook.Add("PreRender", "borealis_snowcover", prepare)
	hook.Add("PostDrawOpaqueRenderables", "borealis_snowcover", draw)
	hook.Add("ShouldDrawLocalPlayer", "borealis_snowcover", function()
		if capturing then return true end
	end)
end

local apply = shaderpack.Toggle("borealis_snowcover", ENABLED, SHADERS, start, stop, { NOISE })
shaderpack.AfterWorld("borealis_snowcover", apply)

cvars.RemoveChangeCallback("borealis_snowcover_distance", "borealis_snowcover")
cvars.AddChangeCallback("borealis_snowcover_distance", function()
	snowcover.SetDistance(DISTANCE:GetInt())
end, "borealis_snowcover")

hook.Add("TOD_WinterRemoved", "borealis_snowcover", function()
	winterRemoved = true
	stop()
end)

hook.Add("PlayerFootstep", "borealis_snowcover", function(ply, pos, _, _, volume)
	local ch = grid.chunks and grid.chunks[chunkKey(math.floor(pos.x / CHUNK), math.floor(pos.y / CHUNK))]
	local steps = ch and ch.steps
	if not steps or not (steps[cellKey(pos.x, pos.y, pos.z, CELL)] or steps[cellKey(pos.x, pos.y, pos.z + DEPTH, CELL)]) then return end

	ply:EmitSound("player/footsteps/snow" .. math.random(6) .. ".wav", 75, 100, volume)

	return true
end)
