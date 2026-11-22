if SERVER then AddCSLuaFile() end

local bspdata = _G.bspdata or {}
_G.bspdata = bspdata

local LOAD_BUDGET_MS = 8
local TRI_CELL = 1024

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

local function decompress(raw)
	if raw:sub(1, 4) ~= "LZMA" then return raw end

	local actual, packed = i32(raw, 5), i32(raw, 9)
	local size, n = {}, actual
	for i = 1, 8 do
		size[i] = string.char(n % 256)
		n = math.floor(n / 256)
	end

	return util.Decompress(raw:sub(13, 17) .. table.concat(size) .. raw:sub(18, 17 + packed)) or ""
end

local function openLumps()
	local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
	if not f then return nil end

	return f, function(i)
		f:Seek(8 + i * 16)
		local ofs, len, ver = f:ReadLong(), f:ReadLong(), f:ReadLong()
		f:Seek(ofs)
		local data = decompress(f:Read(len) or "")

		return data, #data, ver
	end
end

bspdata.U16, bspdata.I16, bspdata.I32, bspdata.F32, bspdata.OpenLumps = u16, i16, i32, f32, openLumps

function bspdata.TextureNames()
	local f, lump = openLumps()
	if not f then return {} end

	local data = lump(43)
	f:Close()

	local names = {}
	for name in data:gmatch("[^%z]+") do
		names[#names + 1] = name
	end

	return names
end

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

local function parseVis()
	local f, lump = openLumps()
	if not f then return false, "cannot open maps/" .. game.GetMap() .. ".bsp" end

	local planes, plLen = lump(1)
	local nodesL, noLen = lump(5)
	local leavesL, leLen, leVer = lump(10)
	local visData = lump(4)
	local waterL, waLen = lump(36)
	f:Close()

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

	local leafSize = leVer == 0 and 56 or 32
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

function bspdata.ClusterAt(x, y, z)
	local vis = bspdata.vis

	return vis.leafCluster[leafAt(vis, x, y, z)]
end

function bspdata.WaterSurfaceAt(x, y, z)
	local vis = bspdata.vis
	local w = vis.leafWater[leafAt(vis, x, y, z)]

	return w >= 0 and vis.waterSurface[w] or nil
end

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

local function addTri(triGrid, ax, ay, az, bx, by, bz, cx, cy, cz, aa, ab, ac, clip)
	local minx, miny, maxx, maxy = math.min(ax, bx, cx), math.min(ay, by, cy), math.max(ax, bx, cx), math.max(ay, by, cy)
	local gx0, gy0 = math.floor(minx / TRI_CELL), math.floor(miny / TRI_CELL)
	local gx1, gy1 = math.floor(maxx / TRI_CELL), math.floor(maxy / TRI_CELL)
	if clip then
		gx0, gy0 = math.max(gx0, math.floor(clip[1] / TRI_CELL)), math.max(gy0, math.floor(clip[2] / TRI_CELL))
		gx1, gy1 = math.min(gx1, math.floor(clip[3] / TRI_CELL)), math.min(gy1, math.floor(clip[4] / TRI_CELL))
		if gx0 > gx1 or gy0 > gy1 then return end
	end

	local t = { ax, ay, az, bx, by, bz, cx, cy, cz, aa, ab, ac, minx, miny, maxx, maxy }
	for gy = gy0, gy1 do
		for gx = gx0, gx1 do
			local key = gx .. ":" .. gy
			local cell = triGrid[key]
			if not cell then
				cell = {}
				triGrid[key] = cell
			end

			cell[#cell + 1] = t
		end
	end

	return t
end

bspdata.AddTriangle = addTri

local function displacementGrid(px, py, pz, dispinfo, dispverts, di)
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

	local gx, gy, gz, ga, fx, fy, fz = {}, {}, {}, {}, {}, {}, {}
	for r = 0, n - 1 do
		local tr = r / (n - 1)
		local ax, ay, az = cx[0] + (cx[3] - cx[0]) * tr, cy[0] + (cy[3] - cy[0]) * tr, cz[0] + (cz[3] - cz[0]) * tr
		local bx, by, bz = cx[1] + (cx[2] - cx[1]) * tr, cy[1] + (cy[2] - cy[1]) * tr, cz[1] + (cz[2] - cz[1]) * tr
		for c = 0, n - 1 do
			local tc = c / (n - 1)
			local idx = r * n + c
			local vp = (vertStart + c * n + r) * 20 + 1
			local dx, dy, dz, dist = f32(dispverts, vp), f32(dispverts, vp + 4), f32(dispverts, vp + 8), f32(dispverts, vp + 12)
			local flx, fly, flz = ax + (bx - ax) * tc, ay + (by - ay) * tc, az + (bz - az) * tc
			fx[idx], fy[idx], fz[idx] = flx, fly, flz
			gx[idx] = flx + dx * dist
			gy[idx] = fly + dy * dist
			gz[idx] = flz + dz * dist
			ga[idx] = f32(dispverts, vp + 16)
		end
	end

	return n, gx, gy, gz, ga, fx, fy, fz
end

bspdata.DisplacementGrid = displacementGrid

local function addDisplacement(emit, px, py, pz, dispinfo, dispverts, di, alphaFor)
	local n, gx, gy, gz, ga = displacementGrid(px, py, pz, dispinfo, dispverts, di)
	for idx = 0, n * n - 1 do
		ga[idx] = alphaFor(ga[idx])
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

function bspdata.Triangles(classify, minNormalZ, worldOnly, skipFlags)
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
	local firstFace, lastFace = 0, faLen / 56 - 1
	if worldOnly then
		local models = lump(14)
		firstFace = i32(models, 41)
		lastFace = firstFace + i32(models, 45) - 1
	end
	f:Close()

	local yieldIfOverBudget = frameBudget()
	local names = {}
	for i = 0, stLen / 4 - 1 do
		names[i] = string.match(strData, "^[^%z]*", i32(strTable, i * 4 + 1) + 1)
	end

	local texinfo, surfFlags = {}, {}
	for i = 0, tiLen / 72 - 1 do
		surfFlags[i] = i32(texinfoL, i * 72 + 65)
		texinfo[i] = i32(texinfoL, i * 72 + 69)
	end

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

	for i = firstFace, lastFace do
		if i % 512 == 0 then yieldIfOverBudget() end
		local fp = i * 56 + 1
		local ti = i16(faces, fp + 10)
		local mode = texinfo[ti] and modes[texinfo[ti]]
		if mode and bit.band(surfFlags[ti], skipFlags or 0) == 0 and f32(planes, u16(faces, fp) * 20 + 9) >= minNormalZ then
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

local SKYBOX_CHECK_HEIGHT = 14
local skyboxVis, skyboxSet

function bspdata.SkyboxPVS()
	local vis = bspdata.vis
	if vis == skyboxVis then return skyboxSet end
	skyboxVis, skyboxSet = vis, nil

	local f, lump = openLumps()
	if not f then return nil end

	local entities = lump(0)
	f:Close()
	for block in entities:gmatch("%b{}") do
		if block:find("\"classname\" \"sky_camera\"", 1, true) then
			local x, y, z = (block:match("\"origin\" \"([^\"]*)\"") or ""):match("(%S+)%s+(%S+)%s+(%S+)")
			local cluster = x and bspdata.ClusterAt(tonumber(x), tonumber(y), tonumber(z)) or -1
			skyboxSet = cluster >= 0 and bspdata.PVS(cluster) or nil

			return skyboxSet
		end
	end
end

local function inSkybox(skybox, x, y, z)
	local c = bspdata.ClusterAt(x, y, z + SKYBOX_CHECK_HEIGHT)

	return c >= 0 and skybox[c] or false
end

function bspdata.InSkybox(x, y, z)
	local skybox = bspdata.SkyboxPVS()

	return skybox ~= nil and inSkybox(skybox, x, y, z)
end

local function playableBounds(leaves, count, size)
	if not bspdata.LoadVis() then return end

	local skybox = bspdata.SkyboxPVS() or {}
	local x0, y0, z0 = math.huge, math.huge, math.huge
	local x1, y1, z1 = -math.huge, -math.huge, -math.huge
	for i = 0, count - 1 do
		local p = i * size + 1
		local cluster = i16(leaves, p + 4)
		if cluster >= 0 and not skybox[cluster] then
			x0, y0, z0 = math.min(x0, i16(leaves, p + 8)), math.min(y0, i16(leaves, p + 10)), math.min(z0, i16(leaves, p + 12))
			x1, y1, z1 = math.max(x1, i16(leaves, p + 14)), math.max(y1, i16(leaves, p + 16)), math.max(z1, i16(leaves, p + 18))
		end
	end

	if x0 > x1 then return end

	return Vector(x0, y0, z0), Vector(x1, y1, z1)
end

local function readWorld()
	local f, lump = openLumps()
	if not f then return end

	local entities = lump(0)
	local leaves, leLen, leVer = lump(10)
	f:Close()

	local worldspawn = entities:match("%b{}") or ""
	local mins = worldspawn:match("\"world_mins\" \"([^\"]*)\"")
	local maxs = worldspawn:match("\"world_maxs\" \"([^\"]*)\"")
	if not mins or not maxs then return end

	local leafSize = leVer == 0 and 56 or 32
	local lo, hi = playableBounds(leaves, leLen / leafSize, leafSize)
	if not lo then
		lo, hi = Vector(mins), Vector(maxs)
	end
	local world = { x0 = lo.x, y0 = lo.y, z0 = lo.z, x1 = hi.x, y1 = hi.y, z1 = hi.z }
	for block in entities:gmatch("%b{}") do
		if block:find("\"classname\" \"sky_camera\"", 1, true) then
			local origin = block:match("\"origin\" \"([^\"]*)\"")
			if origin then
				local o = Vector(origin)
				world.scale = tonumber(block:match("\"scale\" \"([^\"]*)\"")) or 16
				world.ox, world.oy, world.oz = o.x, o.y, o.z
			end

			break
		end
	end

	return world
end

local world, skyCamera

function bspdata.WorldBounds()
	if world == nil then world = readWorld() or false end

	return world or nil
end

function bspdata.SkyCamera()
	if skyCamera == nil then
		local w = bspdata.WorldBounds()
		skyCamera = w and w.scale and w or false
	end

	return skyCamera or nil
end

bspdata.SKY_CLUSTER = -2

function bspdata.SkyToWorld(x, y, z)
	local cam = bspdata.SkyCamera()
	local s = cam.scale

	return (x - cam.ox) * s, (y - cam.oy) * s, (z - cam.oz) * s
end

function bspdata.WorldToSky(x, y, z)
	local cam = bspdata.SkyCamera()
	local s = cam.scale

	return cam.ox + x / s, cam.oy + y / s, cam.oz + z / s
end

function bspdata.BeyondWorld(x, y, z, margin)
	local cam = skyCamera
	if cam == nil then cam = bspdata.SkyCamera() end
	if not cam then return false end

	local m = margin or 0

	return x < cam.x0 + m or x > cam.x1 - m or y < cam.y0 + m or y > cam.y1 - m or z < cam.z0 + m or z > cam.z1 - m
end

local savedStart, savedEnd = Vector(), Vector()

function bspdata.TraceLine(trace)
	local s, e = trace.start, trace.endpos
	local sx, sy, sz = s:Unpack()
	if not bspdata.BeyondWorld(sx, sy, sz) then return util.TraceLine(trace) end

	savedStart:Set(s)
	savedEnd:Set(e)
	s:SetUnpacked(bspdata.WorldToSky(sx, sy, sz))
	e:SetUnpacked(bspdata.WorldToSky(e:Unpack()))
	local tr = util.TraceLine(trace)
	s:Set(savedStart)
	e:Set(savedEnd)
	local hit = tr.HitPos
	hit:SetUnpacked(bspdata.SkyToWorld(hit:Unpack()))

	return tr
end

function bspdata.PointContents(pos)
	local x, y, z = pos:Unpack()
	if bspdata.BeyondWorld(x, y, z) then
		pos = Vector(bspdata.WorldToSky(x, y, z))
	end

	return util.PointContents(pos)
end

function bspdata.SkyBand(band)
	local cam = bspdata.SkyCamera()
	if not cam or not band then return end

	return { cam.x0 - band, cam.y0 - band, cam.x1 + band, cam.y1 + band }
end

function bspdata.AddSkyboxTriangles(triGrid, tris, band)
	if not bspdata.SkyCamera() then return 0 end

	local clip = bspdata.SkyBand(band)
	local toWorld, beyond = bspdata.SkyToWorld, bspdata.BeyondWorld
	local added = 0
	for _, s in ipairs(tris) do
		local ax, ay, az = toWorld(s[1], s[2], s[3])
		local bx, by, bz = toWorld(s[4], s[5], s[6])
		local cx, cy, cz = toWorld(s[7], s[8], s[9])
		if beyond(ax, ay, az) or beyond(bx, by, bz) or beyond(cx, cy, cz) then
			local t = addTri(triGrid, ax, ay, az, bx, by, bz, cx, cy, cz, s[10], s[11], s[12], clip)
			if t then
				t.sky = true
				added = added + 1
			end
		end
	end

	return added
end

local FACE_NORMAL_STEP = 2

function bspdata.SkyboxTriangles(skipFlags)
	local skybox = bspdata.SkyboxPVS()
	if not skybox then return {} end

	local f, lump = openLumps()
	if not f then return {} end

	local planes, verts, texinfo, faces = lump(1), lump(3), lump(6), lump(7)
	local edges, surfedges, models = lump(12), lump(13), lump(14)
	local dispinfo, dispverts = lump(26), lump(33)
	f:Close()

	local yieldIfOverBudget = frameBudget()
	local out = {}
	local function emit(ax, ay, az, bx, by, bz, cx, cy, cz)
		local n = #out
		out[n + 1], out[n + 2], out[n + 3] = ax, ay, az
		out[n + 4], out[n + 5], out[n + 6] = bx, by, bz
		out[n + 7], out[n + 8], out[n + 9] = cx, cy, cz
	end
	local function noAlpha() return 0 end

	local firstFace = i32(models, 41)
	for i = firstFace, firstFace + i32(models, 45) - 1 do
		if i % 256 == 0 then yieldIfOverBudget() end
		local fp = i * 56 + 1
		local ti = i16(faces, fp + 10)
		local numedges = i16(faces, fp + 8)
		if ti >= 0 and numedges >= 3 and bit.band(i32(texinfo, ti * 72 + 65), skipFlags or 0) == 0 then
			local pp = u16(faces, fp) * 20 + 1
			local nx, ny, nz = f32(planes, pp), f32(planes, pp + 4), f32(planes, pp + 8)
			if byte(faces, fp + 2) ~= 0 then nx, ny, nz = -nx, -ny, -nz end

			local firstedge, di = i32(faces, fp + 4), i16(faces, fp + 12)
			local px, py, pz = {}, {}, {}
			local cx, cy, cz = 0, 0, 0
			for e = 0, numedges - 1 do
				local se = i32(surfedges, (firstedge + e) * 4 + 1)
				local vp = u16(edges, math.abs(se) * 4 + 1 + (se < 0 and 2 or 0)) * 12 + 1
				px[e + 1], py[e + 1], pz[e + 1] = f32(verts, vp), f32(verts, vp + 4), f32(verts, vp + 8)
				cx, cy, cz = cx + px[e + 1], cy + py[e + 1], cz + pz[e + 1]
			end
			cx, cy, cz = cx / numedges, cy / numedges, cz / numedges

			local cluster = bspdata.ClusterAt(cx + nx * FACE_NORMAL_STEP, cy + ny * FACE_NORMAL_STEP, cz + nz * FACE_NORMAL_STEP)
			if cluster >= 0 and skybox[cluster] then
				if di == -1 then
					for e = 2, numedges - 1 do
						emit(px[1], py[1], pz[1], px[e], py[e], pz[e], px[e + 1], py[e + 1], pz[e + 1])
					end
				elseif numedges == 4 then
					addDisplacement(emit, px, py, pz, dispinfo, dispverts, di, noAlpha)
					yieldIfOverBudget()
				end
			end
		end
	end

	return out
end

function bspdata.SkyClusters(excluded)
	local f, lump = openLumps()
	if not f then return {} end

	local texinfo, faces = lump(6), lump(7)
	local leafs, _, leafVersion = lump(10)
	local leaffaces = lump(16)
	f:Close()

	local vis = bspdata.vis
	local leafSize = leafVersion == 0 and 56 or 32
	local skyFlags = bit.bor(SURF_SKY, SURF_SKY2D)
	local clusters = {}
	for leaf = 0, #leafs / leafSize - 1 do
		local cluster = vis.leafCluster[leaf] or -1
		if cluster >= 0 and not clusters[cluster] and not (excluded and excluded[cluster]) then
			local lp = leaf * leafSize + 1
			local first, count = u16(leafs, lp + 20), u16(leafs, lp + 22)
			for n = first, first + count - 1 do
				local ti = i16(faces, u16(leaffaces, n * 2 + 1) * 56 + 11)
				if ti >= 0 and bit.band(i32(texinfo, ti * 72 + 65), skyFlags) ~= 0 then
					clusters[cluster] = true
					break
				end
			end
		end
	end

	return clusters
end

function bspdata.RemoveSkybox(triGrid)
	local skybox = bspdata.SkyboxPVS()
	if not skybox then return triGrid, {} end

	local yieldIfOverBudget = frameBudget()
	local removed, removedList = {}, {}
	for key, cell in pairs(triGrid) do
		local kept = {}
		for _, t in ipairs(cell) do
			local remove = removed[t]
			if remove == nil then
				remove = inSkybox(skybox, (t[1] + t[4] + t[7]) / 3, (t[2] + t[5] + t[8]) / 3, (t[3] + t[6] + t[9]) / 3)
					or inSkybox(skybox, t[1], t[2], t[3])
					or inSkybox(skybox, t[4], t[5], t[6])
					or inSkybox(skybox, t[7], t[8], t[9])
				removed[t] = remove
				if remove then removedList[#removedList + 1] = t end
			end

			if not remove then kept[#kept + 1] = t end
			yieldIfOverBudget()
		end

		triGrid[key] = #kept > 0 and kept or nil
	end

	return triGrid, removedList
end

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

local SURF_WARP = 0x8
local WATER_TOP_FACING = 0.99

function bspdata.WaterFaces(withClusters)
	local f, lump = openLumps()
	if not f then return {} end

	local PLANES, TEXDATA, VERTS = lump(1), lump(2), lump(3)
	local TEXINFO, FACES = lump(6), lump(7)
	local LEAFS, _, leafVersion = lump(10)
	local EDGES, SURFEDGES, MODELS = lump(12), lump(13), lump(14)
	local LEAFFACES = lump(16)
	local STRDATA, STRTAB = lump(43), lump(44)
	f:Close()

	local vis = withClusters and bspdata.LoadVis()
	local leafSize = leafVersion == 0 and 56 or 32
	local faceClusters = {}
	for leaf = 0, vis and #LEAFS / leafSize - 1 or -1 do
		local cluster = vis.leafCluster[leaf] or -1
		if cluster >= 0 then
			local lp = leaf * leafSize + 1
			local first, count = u16(LEAFS, lp + 20), u16(LEAFS, lp + 22)
			for n = first, first + count - 1 do
				local fi = u16(LEAFFACES, n * 2 + 1)
				faceClusters[fi] = faceClusters[fi] or {}
				faceClusters[fi][cluster] = true
			end
		end
	end

	local function matName(td)
		local id = i32(TEXDATA, td * 32 + 13)
		local ofs = i32(STRTAB, id * 4 + 1)
		local e = STRDATA:find("\0", ofs + 1, true)

		return STRDATA:sub(ofs + 1, (e or 1) - 1)
	end

	local faces = {}
	for mi = 0, #MODELS / 48 - 1 do
		local mp = mi * 48 + 1
		local firstface, numfaces = i32(MODELS, mp + 40), i32(MODELS, mp + 44)

		for fi = firstface, firstface + numfaces - 1 do
			local p = fi * 56 + 1
			local ti = i16(FACES, p + 10)
			if ti >= 0 and i16(FACES, p + 12) < 0 then
				local tp = ti * 72 + 1
				if bit.band(i32(TEXINFO, tp + 64), SURF_WARP) ~= 0 then
					local pp = u16(FACES, p) * 20 + 1
					local nz, dist = f32(PLANES, pp + 8), f32(PLANES, pp + 12)
					if byte(FACES, p + 2) ~= 0 then nz, dist = -nz, -dist end

					local name = matName(i32(TEXINFO, tp + 68)):lower()
					if nz > WATER_TOP_FACING and not (name:find("_beneath", 1, true) or name:find("under", 1, true)) then
						local td = i32(TEXINFO, tp + 68)
						local tw, th = i32(TEXDATA, td * 32 + 17), i32(TEXDATA, td * 32 + 21)
						local firstedge, numedges = i32(FACES, p + 4), i16(FACES, p + 8)
						local poly = {}
						for n = 0, numedges - 1 do
							local se = i32(SURFEDGES, (firstedge + n) * 4 + 1)
							local vi = se >= 0 and u16(EDGES, se * 4 + 1) or u16(EDGES, -se * 4 + 3)
							local vp = vi * 12 + 1
							poly[#poly + 1] = Vector(f32(VERTS, vp), f32(VERTS, vp + 4), f32(VERTS, vp + 8))
						end

						faces[#faces + 1] = {
							model = mi, name = name, dist = dist, poly = poly, clusters = faceClusters[fi] or {},
							su = f32(TEXINFO, tp) / tw, ou = f32(TEXINFO, tp + 12) / tw,
							sv = f32(TEXINFO, tp + 20) / th, ov = f32(TEXINFO, tp + 28) / th,
						}
					end
				end
			end
		end
	end

	return faces
end

function bspdata.SkyTriangles()
	local f, lump = openLumps()
	if not f then return {} end

	local VERTS, TEXINFO, FACES = lump(3), lump(6), lump(7)
	local EDGES, SURFEDGES, MODELS = lump(12), lump(13), lump(14)
	f:Close()

	local skyFlags = bit.bor(SURF_SKY, SURF_SKY2D)
	local firstface = i32(MODELS, 41)
	local out = {}
	for fi = firstface, firstface + i32(MODELS, 45) - 1 do
		local p = fi * 56 + 1
		local ti = i16(FACES, p + 10)
		if ti >= 0 and bit.band(i32(TEXINFO, ti * 72 + 65), skyFlags) ~= 0 then
			local firstedge, numedges = i32(FACES, p + 4), i16(FACES, p + 8)
			local px, py, pz = {}, {}, {}
			for n = 0, numedges - 1 do
				local se = i32(SURFEDGES, (firstedge + n) * 4 + 1)
				local vi = se >= 0 and u16(EDGES, se * 4 + 1) or u16(EDGES, -se * 4 + 3)
				local vp = vi * 12 + 1
				px[n + 1], py[n + 1], pz[n + 1] = f32(VERTS, vp), f32(VERTS, vp + 4), f32(VERTS, vp + 8)
			end

			for n = 2, numedges - 1 do
				for _, k in ipairs({ 1, n, n + 1 }) do
					out[#out + 1] = px[k]
					out[#out + 1] = py[k]
					out[#out + 1] = pz[k]
				end
			end
		end
	end

	return out
end

local function readStaticProps()
	local f, lump = openLumps()
	if not f then return {}, {} end

	local gameLump = lump(35)
	local models, props = {}, {}
	for k = 0, (#gameLump >= 4 and i32(gameLump, 1) or 0) - 1 do
		local p = 5 + k * 16
		if gameLump:sub(p, p + 3) == "prps" then
			local version = u16(gameLump, p + 6)
			f:Seek(i32(gameLump, p + 8))
			local data = decompress(f:Read(i32(gameLump, p + 12)) or "")
			if #data < 12 then break end

			local count = i32(data, 1)
			for d = 0, count - 1 do
				models[d + 1] = data:sub(5 + d * 128, 4 + (d + 1) * 128):match("^[^%z]*")
			end

			local at = 5 + count * 128
			at = at + 4 + i32(data, at) * 2
			local total = i32(data, at)
			at = at + 4
			local size = total > 0 and math.floor((#data - at + 1) / total) or 0
			for n = 0, total - 1 do
				local q = at + n * size
				props[n + 1] = {
					model = models[u16(data, q + 24) + 1],
					origin = Vector(f32(data, q), f32(data, q + 4), f32(data, q + 8)),
					angles = Angle(f32(data, q + 12), f32(data, q + 16), f32(data, q + 20)),
					scale = version >= 11 and size >= 80 and f32(data, q + 76) or 1,
				}
			end

			break
		end
	end
	f:Close()

	return models, props
end

function bspdata.StaticProps()
	local _, props = readStaticProps()

	return props
end

function bspdata.EntityModels(classes)
	local f, lump = openLumps()
	if not f then return {} end

	local entities = lump(0):lower()
	f:Close()

	local models = {}
	for block in entities:gmatch("%b{}") do
		local model = block:match("\"model\" \"(models/[^\"]+%.mdl)\"")
		if model and (not classes or classes[block:match("\"classname\" \"([^\"]+)\"")]) then
			models[#models + 1] = model
		end
	end

	return models
end

function bspdata.StaticPropModels()
	return (readStaticProps())
end

function bspdata.DetailSprites()
	local f, lump = openLumps()
	if not f then return nil end

	local entities, gameLump = lump(0), lump(35)
	local data, version
	for k = 0, (#gameLump >= 4 and i32(gameLump, 1) or 0) - 1 do
		local p = 5 + k * 16
		if gameLump:sub(p, p + 3) == "prpd" then
			version = u16(gameLump, p + 6)
			f:Seek(i32(gameLump, p + 8))
			data = decompress(f:Read(i32(gameLump, p + 12)) or "")
			break
		end
	end
	f:Close()
	if not data or version < 4 or #data < 4 then return nil end

	local p = 5 + i32(data, 1) * 128
	p = p + 4 + i32(data, p) * 32
	local count = i32(data, p)
	p = p + 4

	local yieldIfOverBudget = frameBudget()
	local r, g, b, n = 0, 0, 0, 0
	for i = 0, count - 1 do
		if i % 4096 == 4095 then yieldIfOverBudget() end
		local q = p + i * 52
		if byte(data, q + 44) ~= 0 then
			local cr, cg, cb, e = byte(data, q + 28, q + 31)
			local scale = 2 ^ (e >= 128 and e - 256 or e)
			r, g, b, n = r + cr * scale, g + cg * scale, b + cb * scale, n + 1
		end
	end
	if n == 0 then return nil end

	local worldspawn = entities:match("%b{}") or ""

	return {
		material = (worldspawn:match("\"detailmaterial\" \"([^\"]*)\"") or "detail/detailsprites"):lower(),
		light = Vector(r / n, g / n, b / n),
	}
end

local function upArea(sum,ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz, minNormalZ)
	local ux, uy, uz = bx - ax, by - ay, bz - az
	local vx, vy, vz = cx - ax, cy - ay, cz - az
	local x, y, z = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
	local len = math.sqrt(x * x + y * y + z * z)
	if len < 1e-6 then return end
	local a = len * 0.5
	sum[5] = sum[5] + a
	if x * nx + y * ny + z * nz < 0 then z = -z end
	if z / len < minNormalZ then return end

	sum[1] = sum[1] + a
	sum[2] = sum[2] + (ax + bx + cx) / 3 * a
	sum[3] = sum[3] + (ay + by + cy) / 3 * a
	sum[4] = sum[4] + (az + bz + cz) / 3 * a
end

function bspdata.UpFacingArea(minNormalZ, accept)
	local f, lump = openLumps()
	if not f then return {} end

	local strData, strTable, texdataL, texinfoL = lump(43), lump(44), lump(2), lump(6)
	local faces, faLen = lump(7)
	local planes, verts, edges, surfedges = lump(1), lump(3), lump(12), lump(13)
	local dispinfo, dispverts = lump(26), lump(33)
	f:Close()

	local yieldIfOverBudget = frameBudget()
	local names, area, total = {}, {}, {}
	for i = 0, faLen / 56 - 1 do
		if i % 512 == 0 then yieldIfOverBudget() end
		local fp = i * 56 + 1
		local ti = i16(faces, fp + 10)
		if ti >= 0 then
			local pp = u16(faces, fp) * 20 + 1
			local nx, ny, nz = f32(planes, pp), f32(planes, pp + 4), f32(planes, pp + 8)
			if byte(faces, fp + 2) ~= 0 then nx, ny, nz = -nx, -ny, -nz end

			local firstedge, numedges, di = i32(faces, fp + 4), i16(faces, fp + 8), i16(faces, fp + 12)
			local px, py, pz = {}, {}, {}
			for e = 0, numedges - 1 do
				local se = i32(surfedges, (firstedge + e) * 4 + 1)
				local vp = u16(edges, math.abs(se) * 4 + 1 + (se < 0 and 2 or 0)) * 12 + 1
				px[e + 1], py[e + 1], pz[e + 1] = f32(verts, vp), f32(verts, vp + 4), f32(verts, vp + 8)
			end

			local sum = { 0, 0, 0, 0, 0 }
			if di == -1 then
				for e = 2, numedges - 1 do
					upArea(sum, px[1], py[1], pz[1], px[e], py[e], pz[e], px[e + 1], py[e + 1], pz[e + 1], nx, ny, nz, minNormalZ)
				end
			elseif numedges == 4 then
				local n, gx, gy, gz = displacementGrid(px, py, pz, dispinfo, dispverts, di)
				for r = 0, n - 2 do
					for c = 0, n - 2 do
						local i00, i01, i10, i11 = r * n + c, r * n + c + 1, (r + 1) * n + c, (r + 1) * n + c + 1
						upArea(sum, gx[i00], gy[i00], gz[i00], gx[i10], gy[i10], gz[i10], gx[i11], gy[i11], gz[i11], nx, ny, nz, minNormalZ)
						upArea(sum, gx[i00], gy[i00], gz[i00], gx[i11], gy[i11], gz[i11], gx[i01], gy[i01], gz[i01], nx, ny, nz, minNormalZ)
					end
				end
				yieldIfOverBudget()
			end

			local up = sum[1]
			if up > 0 and accept and not accept(sum[2] / up, sum[3] / up, sum[4] / up) then up = 0 end

			local td = i32(texinfoL, ti * 72 + 69)
			local name = names[td]
			if not name then
				name = string.match(strData, "^[^%z]*", i32(strTable, i32(texdataL, td * 32 + 13) * 4 + 1) + 1)
				names[td] = name
			end

			total[name] = (total[name] or 0) + sum[5]
			if up > 0 then
				area[name] = (area[name] or 0) + up
			end
		end
	end

	return area, total
end

local function lightLevel(value)
	local r, g, b, brightness = (value or ""):match("(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
	if not brightness then return 0 end

	return ((tonumber(r) / 255) ^ 2.2 + (tonumber(g) / 255) ^ 2.2 + (tonumber(b) / 255) ^ 2.2) / 3 * tonumber(brightness)
end

local bakedSun

function bspdata.BakedSun()
	if bakedSun then return bakedSun end

	bakedSun = Vector()
	local f, lump = openLumps()
	if not f then return bakedSun end

	local entities = lump(0)
	f:Close()
	for block in entities:gmatch("%b{}") do
		if block:find("\"classname\" \"light_environment\"", 1, true) then
			local function key(name)
				return block:match("\"" .. name .. "\" \"([^\"]*)\"")
			end

			local angles = key("angles") or ""
			local pitch = tonumber(key("pitch") or angles:match("(%S+)")) or 0
			local yaw = tonumber(angles:match("%S+%s+(%S+)")) or 0
			local sun, ambient = lightLevel(key("_light")), lightLevel(key("_ambient"))
			if sun + ambient > 0 then
				bakedSun = -Angle(-pitch, yaw, 0):Forward() * (sun / (sun + ambient))
			end

			break
		end
	end

	return bakedSun
end
