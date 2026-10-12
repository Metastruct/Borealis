local cover = shaderpack.cover or {}
shaderpack.cover = cover

local bspdata = shaderpack.bspdata

local COLUMN = 24 -- cover map cell, matches the shaders
local COLUMNS = 64 -- cover map size in cells, matches the shaders
local Z_MIN, Z_RANGE = -16384, 32768 -- the cut height's 16 bit range, matches the shaders
local TRACE_SLOT = 80 -- every column is traced again when the eye moves this far in z
local TRACE_HALF = 480 -- the traces look this far above and below the eye
local TRACES_PER_FRAME = 60
local IDLE_TRACES_PER_FRAME = 24 -- the whole window again while nothing is pending, so props built or moved after the trace count
local SPLASH_SLOPE = 0.8 -- steepest ground the rain still rings on, as the surface normal's z
local SEED_GLOSS = 0.7
-- MASK_SOLID: without CONTENTS_MONSTER a trace hits brushes only and every prop is missed; players are filtered per batch
local SOLID = MASK_SOLID
-- water is not in MASK_SOLID, so a solid trace runs straight through a lake and
-- lands on its bed: the rain stopped under the water and rippled down there
local WATER = MASK_WATER
local IN_WATER = CONTENTS_WATER
local GLOSS = {
	[MAT_GRASS] = 0.05,
	[MAT_FOLIAGE] = 0.05,
	[MAT_DIRT] = 0.3,
	[MAT_SNOW] = 0.3,
	[MAT_SAND] = 0.35,
	[MAT_WOOD] = 0.6,
	[MAT_GRATE] = 0.6,
}

local SPAN_VERSION = 2
local SPAN_MIN, SPAN_SIZE = Z_MIN, Z_RANGE
local SPAN_COLUMNS = 1024
local SPAN_COLUMN = SPAN_SIZE / SPAN_COLUMNS
local SPAN_SLOTS = 4
local SPAN_TILE = 64
local SPAN_DIR = "shaderpack/cover"
local SPAN_NET = "ms_cover_spans"
local SPAN_CHUNK = 60000
local SPAN_VTF_FLAGS = 0x1 + 0x4 + 0x8 + 0x100 + 0x200
local SPAN_VTF_FORMAT = 25
local SKY_FLAGS = bit.bor(SURF_SKY, SURF_SKY2D)
local IGNORED_FLAGS = bit.bor(SURF_TRIGGER, SURF_HINT, SURF_SKIP)
local MSG_KEY, MSG_CHUNK = 0, 1

cover.COLUMN, cover.COLUMNS, cover.Z_MIN, cover.Z_RANGE = COLUMN, COLUMNS, Z_MIN, Z_RANGE
cover.GLOSS = GLOSS
cover.listeners = cover.listeners or {}

local function le16(v)
	return string.char(v % 256, math.floor(v / 256) % 256)
end

local function le32(v)
	return le16(v % 65536) .. le16(math.floor(v / 65536))
end

local function vtfHeader()
	local header = "VTF\0" .. le32(7) .. le32(2) .. le32(80) .. le16(SPAN_COLUMNS * 2) .. le16(SPAN_COLUMNS) .. le32(SPAN_VTF_FLAGS) .. le16(1) .. le16(0) .. le32(0)
		.. "\0\0\0\63\0\0\0\63\0\0\0\63" .. le32(0) .. "\0\0\128\63" .. le32(SPAN_VTF_FORMAT) .. string.char(1) .. "\255\255\255\255" .. string.char(0, 0) .. le16(1)

	return header .. string.rep("\0", 80 - #header)
end

local ROW_BYTES = SPAN_COLUMNS * 2 * 8
local CHAR_CHUNK = 4096

local function heightValue(z)
	return math.floor(math.Clamp((z - SPAN_MIN) / SPAN_SIZE, 0, 1) * 65535 + 0.5)
end

local function writeSpan(bytes, x, slot, top, bottom)
	local at = (slot < 2 and x or SPAN_COLUMNS + x) * 8 + slot % 2 * 4 + 1
	bytes[at], bytes[at + 1] = top % 256, math.floor(top / 256)
	bytes[at + 2], bytes[at + 3] = bottom % 256, math.floor(bottom / 256)
end

local function rowString(bytes)
	local parts = {}
	for i = 1, ROW_BYTES, CHAR_CHUNK do
		parts[#parts + 1] = string.char(unpack(bytes, i, math.min(i + CHAR_CHUNK - 1, ROW_BYTES)))
	end

	return table.concat(parts)
end

local function descending(a, b)
	return a > b
end

local function columnBytes(list, count, bytes, x)
	local slot = 0
	if count > 0 then
		table.sort(list, descending)
		local prev
		for k = 1, count do
			local v = list[k]
			if v ~= prev and v % 2 == 1 and slot < SPAN_SLOTS then
				local below = list[k + 1]
				writeSpan(bytes, x, slot, heightValue((v - 1) / 8), below and heightValue((below - below % 2) / 8) or 0)
				slot = slot + 1
			end

			prev = v
		end

		for k = 1, count do
			list[k] = nil
		end
	end

	for s = slot, SPAN_SLOTS - 1 do
		writeSpan(bytes, x, s, 0, 65535)
	end
end

function cover.BakeSpans()
	local u16, i16, i32, f32 = bspdata.U16, bspdata.I16, bspdata.I32, bspdata.F32
	local f, lump = bspdata.OpenLumps()
	if not f then return nil, "cannot open maps/" .. game.GetMap() .. ".bsp" end

	local verts = lump(3)
	local texinfoL, tiLen = lump(6)
	local faces = lump(7)
	local edges = lump(12)
	local surfedges = lump(13)
	local models = lump(14)
	local dispinfo = lump(26)
	local dispverts = lump(33)
	f:Close()

	local yieldIfOverBudget = bspdata.FrameBudget()
	local flags = {}
	for i = 0, tiLen / 72 - 1 do
		flags[i] = i32(texinfoL, i * 72 + 65)
	end

	local tilesPerSide = SPAN_COLUMNS / SPAN_TILE
	local tileSize = SPAN_TILE * SPAN_COLUMN
	local tiles = {}
	local vx, vy, vertCount = {}, {}, 0
	local pFirst, pN, pSky, pOrient = {}, {}, {}, {}
	local pNx, pNy, pNz, pD = {}, {}, {}, {}
	local pMinX, pMaxX, pMinY, pMaxY = {}, {}, {}, {}
	local polys = 0

	local function bucket(id)
		local tx0 = math.max(0, math.floor((pMinX[id] - SPAN_MIN) / tileSize))
		local tx1 = math.min(tilesPerSide - 1, math.floor((pMaxX[id] - SPAN_MIN) / tileSize))
		local ty0 = math.max(0, math.floor((pMinY[id] - SPAN_MIN) / tileSize))
		local ty1 = math.min(tilesPerSide - 1, math.floor((pMaxY[id] - SPAN_MIN) / tileSize))
		for ty = ty0, ty1 do
			for tx = tx0, tx1 do
				local key = ty * tilesPerSide + tx
				local list = tiles[key]
				if not list then
					list = {}
					tiles[key] = list
				end

				list[#list + 1] = id
			end
		end
	end

	local function addPoly(n, xs, ys, zs, sky)
		local nx, ny, nz = 0, 0, 0
		local minx, maxx, miny, maxy = xs[1], xs[1], ys[1], ys[1]
		for a = 1, n do
			local b = a % n + 1
			nx = nx + (ys[a] - ys[b]) * (zs[a] + zs[b])
			ny = ny + (zs[a] - zs[b]) * (xs[a] + xs[b])
			nz = nz + (xs[a] - xs[b]) * (ys[a] + ys[b])
			minx, maxx = math.min(minx, xs[a]), math.max(maxx, xs[a])
			miny, maxy = math.min(miny, ys[a]), math.max(maxy, ys[a])
		end

		if math.abs(nz) < 0.01 * math.sqrt(nx * nx + ny * ny + nz * nz) then return end

		polys = polys + 1
		pFirst[polys], pN[polys], pSky[polys], pOrient[polys] = vertCount, n, sky and 1 or 0, nz > 0 and 1 or -1
		pNx[polys], pNy[polys], pNz[polys], pD[polys] = nx, ny, nz, nx * xs[1] + ny * ys[1] + nz * zs[1]
		pMinX[polys], pMaxX[polys], pMinY[polys], pMaxY[polys] = minx, maxx, miny, maxy
		for a = 1, n do
			vx[vertCount + a], vy[vertCount + a] = xs[a], ys[a]
		end

		vertCount = vertCount + n
		bucket(polys)
	end

	local tx, ty, tz = {}, {}, {}
	local function addTri(ax, ay, az, bx, by, bz, cx, cy, cz)
		tx[1], ty[1], tz[1], tx[2], ty[2], tz[2], tx[3], ty[3], tz[3] = ax, ay, az, bx, by, bz, cx, cy, cz
		addPoly(3, tx, ty, tz, false)
	end

	local function noAlpha()
		return 0
	end

	local firstFace, numFaces = i32(models, 41), i32(models, 45)
	local px, py, pz = {}, {}, {}
	for fi = firstFace, firstFace + numFaces - 1 do
		if fi % 256 == 0 then yieldIfOverBudget() end
		local fp = fi * 56 + 1
		local fl = flags[i16(faces, fp + 10)] or 0
		if bit.band(fl, IGNORED_FLAGS) == 0 then
			local firstedge, numedges, di = i32(faces, fp + 4), i16(faces, fp + 8), i16(faces, fp + 12)
			for e = 0, numedges - 1 do
				local se = i32(surfedges, (firstedge + e) * 4 + 1)
				local vp = u16(edges, math.abs(se) * 4 + 1 + (se < 0 and 2 or 0)) * 12 + 1
				px[e + 1], py[e + 1], pz[e + 1] = f32(verts, vp), f32(verts, vp + 4), f32(verts, vp + 8)
			end

			if di == -1 then
				addPoly(numedges, px, py, pz, bit.band(fl, SKY_FLAGS) ~= 0)
			elseif numedges == 4 then
				bspdata.Displacement(addTri, px, py, pz, dispinfo, dispverts, di, noAlpha)
				yieldIfOverBudget()
			end
		end
	end

	local function inside(id, x, y)
		local first, n, orient = pFirst[id], pN[id], pOrient[id]
		for a = 1, n do
			local b = first + a % n + 1
			local ax, ay = vx[first + a], vy[first + a]
			if ((vx[b] - ax) * (y - ay) - (vy[b] - ay) * (x - ax)) * orient < -0.001 then
				return false
			end
		end

		return true
	end

	local hits, counts = {}, {}
	for idx = 0, SPAN_TILE * SPAN_TILE - 1 do
		hits[idx], counts[idx] = {}, 0
	end

	local function rasterPoly(id, i0t, j0t)
		local i0 = math.max(i0t, math.ceil((pMinX[id] - SPAN_MIN) / SPAN_COLUMN - 0.5))
		local i1 = math.min(i0t + SPAN_TILE - 1, math.floor((pMaxX[id] - SPAN_MIN) / SPAN_COLUMN - 0.5))
		local j0 = math.max(j0t, math.ceil((pMinY[id] - SPAN_MIN) / SPAN_COLUMN - 0.5))
		local j1 = math.min(j0t + SPAN_TILE - 1, math.floor((pMaxY[id] - SPAN_MIN) / SPAN_COLUMN - 0.5))
		for j = j0, j1 do
			local y = SPAN_MIN + (j + 0.5) * SPAN_COLUMN
			for i = i0, i1 do
				local x = SPAN_MIN + (i + 0.5) * SPAN_COLUMN
				if inside(id, x, y) then
					local idx = (j - j0t) * SPAN_TILE + (i - i0t)
					local count = counts[idx] + 1
					counts[idx] = count
					hits[idx][count] = math.floor((pD[id] - pNx[id] * x - pNy[id] * y) / pNz[id] * 4 + 0.5) * 2 + pSky[id]
				end
			end
		end
	end

	local function rasterTile(tileX, tileY)
		for _, id in ipairs(tiles[tileY * tilesPerSide + tileX] or {}) do
			rasterPoly(id, tileX * SPAN_TILE, tileY * SPAN_TILE)
		end
	end

	local rows = { vtfHeader() }
	local rowBytes = {}
	for r = 1, SPAN_TILE do
		rowBytes[r] = {}
	end

	for tileY = 0, tilesPerSide - 1 do
		for tileX = 0, tilesPerSide - 1 do
			yieldIfOverBudget()
			rasterTile(tileX, tileY)
			for j = 0, SPAN_TILE - 1 do
				local bytes = rowBytes[j + 1]
				for i = 0, SPAN_TILE - 1 do
					local idx = j * SPAN_TILE + i
					columnBytes(hits[idx], counts[idx], bytes, tileX * SPAN_TILE + i)
					counts[idx] = 0
				end
			end
		end

		for r = 1, SPAN_TILE do
			rows[#rows + 1] = rowString(rowBytes[r])
		end
	end

	return table.concat(rows)
end

local function spanKey()
	local path = "maps/" .. game.GetMap() .. ".bsp"

	return string.lower(string.format("%s_%d_%d_v%d", game.GetMap(), file.Size(path, "GAME") or 0, file.Time(path, "GAME") or 0, SPAN_VERSION))
end

local function spanPath(key, ext)
	return SPAN_DIR .. "/" .. key .. "." .. ext
end

if SERVER then
	util.AddNetworkString(SPAN_NET)

	local key, blob
	local waiting, sends = {}, {}
	local bakeCo

	local function announce(ply)
		net.Start(SPAN_NET)
		net.WriteUInt(MSG_KEY, 2)
		net.WriteString(key)
		net.WriteUInt(#blob, 32)
		net.Send(ply)
		sends[ply] = 1
	end

	local function ready(compressed)
		blob = compressed
		for ply in pairs(waiting) do
			if IsValid(ply) then announce(ply) end
		end

		waiting = {}
	end

	local function think()
		if bakeCo then
			local ok, vtf, why = coroutine.resume(bakeCo)
			if not ok or coroutine.status(bakeCo) == "dead" then
				bakeCo = nil
				if ok and vtf then
					local compressed = util.Compress(vtf)
					file.CreateDir(SPAN_DIR)
					file.Write(spanPath(key, "dat"), compressed)
					ready(compressed)
				else
					ErrorNoHalt("[cover] span bake failed: " .. tostring(ok and why or vtf) .. "\n")
				end
			end
		end

		for ply, i in pairs(sends) do
			if not IsValid(ply) then
				sends[ply] = nil
			else
				local data = string.sub(blob, (i - 1) * SPAN_CHUNK + 1, i * SPAN_CHUNK)
				net.Start(SPAN_NET)
				net.WriteUInt(MSG_CHUNK, 2)
				net.WriteUInt(#data, 16)
				net.WriteData(data, #data)
				net.Send(ply)
				sends[ply] = i * SPAN_CHUNK < #blob and i + 1 or nil
			end
		end
	end

	local function connected(ply)
		if blob then
			announce(ply)
		else
			waiting[ply] = true
		end
	end

	local function start()
		key = spanKey()
		hook.Add("Think", SPAN_NET, think)
		local compressed = file.Read(spanPath(key, "dat"), "DATA")
		if compressed then
			ready(compressed)
		else
			bakeCo = coroutine.create(cover.BakeSpans)
		end
	end

	hook.Add("PlayerFullyConnected", SPAN_NET, connected)

	if game.GetWorld():IsWorld() then
		start()
		for _, ply in ipairs(player.GetHumans()) do
			connected(ply)
		end
	else
		hook.Add("Initialize", SPAN_NET, start)
	end

	return
end

local spanTexture, spanData, spanPending

local function loadSpans(key)
	local mat = CreateMaterial("ms_cover_spans_" .. key, "UnlitGeneric", { ["$basetexture"] = "../data/" .. SPAN_DIR .. "/" .. key })
	local tex = mat:GetTexture("$basetexture")
	spanTexture = tex and not tex:IsError() and tex or nil
	spanData = spanTexture and file.Read(spanPath(key, "vtf"), "DATA") or nil
end

local function spanHeight(pos)
	local lo, hi = string.byte(spanData, pos, pos + 1)

	return (hi * 256 + lo) / 65535 * SPAN_SIZE + SPAN_MIN
end

local function spanCut(x, y, top)
	local cx = math.Clamp(math.floor((x - SPAN_MIN) / SPAN_COLUMN), 0, SPAN_COLUMNS - 1)
	local cy = math.Clamp(math.floor((y - SPAN_MIN) / SPAN_COLUMN), 0, SPAN_COLUMNS - 1)
	local base = 81 + (cy * SPAN_COLUMNS * 2 + cx) * 8
	for s = 0, SPAN_SLOTS - 1 do
		local pos = s < 2 and base + s * 4 or base + SPAN_COLUMNS * 8 + (s - 2) * 4
		local spanTop, spanBottom = spanHeight(pos), spanHeight(pos + 2)
		if spanBottom <= top and top <= spanTop then
			return spanBottom
		end
	end

	return Z_MIN + Z_RANGE
end

net.Receive(SPAN_NET, function()
	local kind = net.ReadUInt(2)
	if kind == MSG_KEY then
		local key, size = net.ReadString(), net.ReadUInt(32)
		if file.Exists(spanPath(key, "vtf"), "DATA") then
			spanPending = nil
			loadSpans(key)

			return
		end

		spanPending = { key = key, size = size, parts = {}, got = 0 }
	elseif kind == MSG_CHUNK and spanPending then
		local data = net.ReadData(net.ReadUInt(16))
		spanPending.parts[#spanPending.parts + 1] = data
		spanPending.got = spanPending.got + #data
		if spanPending.got >= spanPending.size then
			local vtf = util.Decompress(table.concat(spanPending.parts))
			local key = spanPending.key
			spanPending = nil
			if not vtf then return end

			file.CreateDir(SPAN_DIR)
			file.Write(spanPath(key, "vtf"), vtf)
			loadSpans(key)
		end
	end
end)

--------------------------------------------------------------------------
-- cover map: owner[texel] = the column key written there, ground[key] = the
-- level ground's z for the ripples, traced a few per frame from a queue
--------------------------------------------------------------------------
local coverRT
local owner, ground, cuts, pending, queued = {}, {}, {}, {}, {}
local traceZ, winX, winY
local sweep, urgent = 1, true
local updatedFrame = -1
local upTrace = { mask = SOLID, start = Vector(), endpos = Vector() }
local downTrace = { mask = SOLID, start = Vector(), endpos = Vector() }
local waterTrace = { mask = WATER, start = Vector(), endpos = Vector() }
local probe = Vector()

-- both axes offset so negative columns pack and unpack cleanly
local KEY_OFFSET = 32768

local function columnKey(cx, cy)
	return (cx + KEY_OFFSET) * 65536 + cy + KEY_OFFSET
end

local function columnFromKey(key)
	local cx = math.floor(key / 65536)

	return cx - KEY_OFFSET, key - cx * 65536 - KEY_OFFSET
end

cover.ColumnKey, cover.ColumnFromKey = columnKey, columnFromKey

function cover.Listen(id, onColumn, onReset)
	cover.listeners[id] = { column = onColumn, reset = onReset }
end

function cover.Unlisten(id)
	cover.listeners[id] = nil
end

-- where the rain stops in this column: the top of the world when the sky over
-- it is blocked, else the water's surface or the first solid below it, else
-- nowhere.  A solid standing in air is what the rain lands on; one standing in
-- water is a bed the rain never reaches, and the surface over it is, so the
-- second trace only runs where the first came up wet.
local function traceColumn(cx, cy, top, bottom)
	local x, y = (cx + 0.5) * COLUMN, (cy + 0.5) * COLUMN
	upTrace.start:SetUnpacked(x, y, top)
	upTrace.endpos:SetUnpacked(x, y, top + 8192)
	local up = util.TraceLine(upTrace)
	if up.StartSolid or (up.Hit and not up.HitSky) then
		return Z_MIN + Z_RANGE, false, 1
	end

	downTrace.start:SetUnpacked(x, y, top)
	downTrace.endpos:SetUnpacked(x, y, bottom)
	local down = util.TraceLine(downTrace)
	if down.Hit then
		local hit = down.HitPos
		probe:SetUnpacked(hit.x, hit.y, hit.z + 1)
		if bit.band(util.PointContents(probe), IN_WATER) == 0 then
			return hit.z, down.HitNormal.z > SPLASH_SLOPE and hit.z + 0.4, GLOSS[down.MatType] or 1
		end
	end

	waterTrace.start:SetUnpacked(x, y, top)
	waterTrace.endpos:SetUnpacked(x, y, bottom)
	local water = util.TraceLine(waterTrace)
	-- the trace began under the surface: this whole column is water, and the
	-- rain landed on it somewhere above
	if water.StartSolid then
		return Z_MIN + Z_RANGE, false, 1
	end

	-- a water surface is always level, so the ripples ride it whatever the bed does
	if water.Hit then
		return water.HitPos.z, water.HitPos.z + 0.4, 1
	end

	if down.Hit then
		return down.HitPos.z, false, GLOSS[down.MatType] or 1
	end

	return spanData and spanCut(x, y, top) or Z_MIN, false, SEED_GLOSS
end

-- a clear inside a one texel viewport: the surface library's draws go through
-- the sRGB path and land a few values off, the ripples' seeds do not care
-- but 16 bits of height do
local function writeTexel(cx, cy, cut, gloss)
	local v = math.floor(math.Clamp((cut - Z_MIN) / Z_RANGE, 0, 1) * 65535 + 0.5)
	local hi = math.floor(v / 256)
	render.SetViewPort(cx % COLUMNS, cy % COLUMNS, 1, 1)
	render.Clear(hi, v - hi * 256, math.floor(gloss * 255 + 0.5), 255)
end

local sweepX, sweepY = {}, {}
do
	local half = COLUMNS / 2
	local cells = {}
	for oy = 0, COLUMNS - 1 do
		for ox = 0, COLUMNS - 1 do
			local dx, dy = ox - half, oy - half
			cells[#cells + 1] = { ox, oy, math.max(dx < 0 and -dx - 1 or dx, dy < 0 and -dy - 1 or dy) }
		end
	end

	table.sort(cells, function(a, b) return a[3] < b[3] end)
	for i, cell in ipairs(cells) do
		sweepX[i], sweepY[i] = cell[1], cell[2]
	end
end

local function claim(cx, cy, key)
	local texel = cx % COLUMNS * COLUMNS + cy % COLUMNS
	local prev = owner[texel]
	if prev and prev ~= key then
		ground[prev] = nil
		cuts[prev] = nil
	end

	owner[texel] = key
end

local function seedColumns(keys)
	if #keys == 0 or not spanData then return end

	local top = traceZ + TRACE_HALF
	render.PushRenderTarget(coverRT)
	for i = 1, #keys do
		local key = keys[i]
		local cx, cy = columnFromKey(key)
		claim(cx, cy, key)
		writeTexel(cx, cy, spanCut((cx + 0.5) * COLUMN, (cy + 0.5) * COLUMN, top), SEED_GLOSS)
	end

	render.SetViewPort(0, 0, COLUMNS, COLUMNS)
	render.PopRenderTarget()
end

local function enter(cx, cy, fresh, queue)
	local key = columnKey(cx, cy)
	if owner[cx % COLUMNS * COLUMNS + cy % COLUMNS] ~= key then
		fresh[#fresh + 1] = key
	elseif cuts[key] then
		return
	end

	if queue and not queued[key] then
		queued[key] = true
		pending[#pending + 1] = key
	end
end

local function enterRange(cy, x0, x1, fresh)
	for cx = x0, x1 do
		enter(cx, cy, fresh, true)
	end
end

local function enterStrips(oldX, oldY, fresh)
	local x1 = winX + COLUMNS - 1
	for cy = winY, winY + COLUMNS - 1 do
		if cy < oldY or cy >= oldY + COLUMNS then
			enterRange(cy, winX, x1, fresh)
		else
			enterRange(cy, winX, math.min(x1, oldX - 1), fresh)
			enterRange(cy, math.max(winX, oldX + COLUMNS), x1, fresh)
		end
	end
end

local function enterWindow(fresh)
	for cy = winY, winY + COLUMNS - 1 do
		for cx = winX, winX + COLUMNS - 1 do
			enter(cx, cy, fresh, false)
		end
	end
end

local function notify(cx, cy, cutChanged, groundChanged)
	for _, l in pairs(cover.listeners) do
		if l.column then
			l.column(cx, cy, cutChanged, groundChanged)
		end
	end
end

local function traceOne(cx, cy, top, bottom)
	local key = columnKey(cx, cy)
	local cut, level, gloss = traceColumn(cx, cy, top, bottom)
	claim(cx, cy, key)
	local cutChanged = cuts[key] ~= cut
	cuts[key] = cut

	local groundChanged = (ground[key] or false) ~= level
	ground[key] = level or nil

	if cutChanged or groundChanged then
		notify(cx, cy, cutChanged, groundChanged)
	end

	writeTexel(cx, cy, cut, gloss)
end

local function moveWindow(eye)
	local half = COLUMNS / 2
	local cx0, cy0 = math.floor(eye.x / COLUMN) - half, math.floor(eye.y / COLUMN) - half
	-- every column again once the eye has moved a slot up or down, a jump
	-- never does; the old heights stay in the map meanwhile
	if not traceZ or math.abs(eye.z - traceZ) > TRACE_SLOT then
		traceZ = eye.z
		sweep, urgent = 1, true
	end

	if cx0 == winX and cy0 == winY then return end

	local oldX, oldY = winX, winY
	winX, winY = cx0, cy0
	local fresh = {}
	if oldX and math.abs(cx0 - oldX) < COLUMNS and math.abs(cy0 - oldY) < COLUMNS then
		enterStrips(oldX, oldY, fresh)
	else
		pending, queued = {}, {}
		enterWindow(fresh)
		sweep, urgent = 1, true
	end

	seedColumns(fresh)
end

local function updateColumns(eye)
	moveWindow(eye)

	local top, bottom = traceZ + TRACE_HALF, traceZ - TRACE_HALF
	local players = player.GetAll()
	upTrace.filter, downTrace.filter = players, players
	local budget = (urgent or #pending > 0) and TRACES_PER_FRAME or IDLE_TRACES_PER_FRAME
	render.PushRenderTarget(coverRT)
	while budget > 0 and #pending > 0 do
		local key = table.remove(pending)
		queued[key] = nil
		local cx, cy = columnFromKey(key)
		-- only columns still in the window are worth tracing
		if cx >= winX and cx < winX + COLUMNS and cy >= winY and cy < winY + COLUMNS then
			traceOne(cx, cy, top, bottom)
			budget = budget - 1
		end
	end

	for _ = 1, budget do
		traceOne(winX + sweepX[sweep], winY + sweepY[sweep], top, bottom)
		sweep = sweep % #sweepX + 1
		if sweep == 1 then
			urgent = false
		end
	end

	render.SetViewPort(0, 0, COLUMNS, COLUMNS)
	render.PopRenderTarget()
end

-- The render targets do not exist yet while the map loads, and asking for one
-- then hands back a texture that answers IsError with false and only becomes
-- the cover map later.  A material bound to it samples black for good, so
-- every column reads a cut of Z_MIN and the rain falls through every roof.
-- The ripples come from Lua and keep obeying the traces, which is what the
-- symptom looks like: cover works on the ground and nowhere else.
-- on the first frame the targets are real, never at load
local function build()
	-- point sampled and wrapped: the shader addresses it by world column
	coverRT = coverRT or GetRenderTargetEx("ms_rain_cover_" .. COLUMNS, COLUMNS, COLUMNS, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, 1, 0, IMAGE_FORMAT_RGBA8888)
	if not shaderpack.UsableRT(coverRT, COLUMNS) then
		coverRT = nil

		return false
	end

	-- untraced columns rain everywhere
	render.PushRenderTarget(coverRT)
	render.Clear(0, 0, 0, 255)
	render.PopRenderTarget()
	owner, ground, cuts, pending, queued = {}, {}, {}, {}, {}
	traceZ, winX, winY = nil, nil, nil
	sweep, urgent = 1, true
	for _, l in pairs(cover.listeners) do
		if l.reset then
			l.reset()
		end
	end

	return true
end

-- Safe to call from several effects in one frame: only the first does the work.
function cover.Update(eye)
	if updatedFrame == FrameNumber() then return coverRT ~= nil end
	updatedFrame = FrameNumber()
	if not coverRT and not build() then return false end

	updateColumns(eye)

	return true
end

function cover.Texture()
	return coverRT
end

function cover.Spans()
	return spanTexture
end

function cover.Window()
	return winX, winY
end

function cover.Ground(cx, cy)
	return ground[columnKey(cx, cy)]
end

function cover.CutAt(x, y)
	local cx, cy = math.floor(x / COLUMN), math.floor(y / COLUMN)
	local key = columnKey(cx, cy)
	if owner[cx % COLUMNS * COLUMNS + cy % COLUMNS] ~= key then return nil end

	return cuts[key]
end
