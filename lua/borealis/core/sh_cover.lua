local cover = shaderpack.cover or {}
shaderpack.cover = cover

local bspdata = bspdata

local COLUMN = 24
local COLUMNS = 64
local Z_MIN, Z_RANGE = -16384, 32768
local TRACE_SLOT = 80
local TRACE_HALF = 480
local TRACES_PER_FRAME = 60
local IDLE_TRACES_PER_FRAME = 24
local PENDING_TIME = 0.002
local SPLASH_SLOPE = 0.8
local SPAN_GLOSS = 0.7
local SOLID = MASK_SOLID
local WATER = MASK_WATER
local IN_WATER = CONTENTS_WATER
local SHORE_DEPTH = 8
local EXIT_INSET = 2
local SPAN_OPEN_MARGIN, SPAN_COLUMN_OFFSET, SPAN_MIN_NORMAL = 16, 24, 0.1
local GLOSS = {
	[MAT_GRASS] = 0.05,
	[MAT_FOLIAGE] = 0.05,
	[MAT_DIRT] = 0.3,
	[MAT_SNOW] = 0.3,
	[MAT_SAND] = 0.35,
	[MAT_WOOD] = 0.6,
	[MAT_GRATE] = 0.6,
}

local SPAN_VERSION = 5
local SPAN_MIN, SPAN_SIZE = Z_MIN, Z_RANGE
local SPAN_COLUMNS = 1024
local SPAN_COLUMN = SPAN_SIZE / SPAN_COLUMNS
local SPAN_SLOTS = 4
local SPAN_TILE = 64
local SPAN_TRACE_INSET = 2
local SPAN_DIR = "shaderpack/cover"
local SPAN_NET = "borealis_cover_spans"
local SPAN_CHUNK = 32000
local SPAN_RATE = 131072
local SPAN_VTF_FLAGS = 0x1 + 0x4 + 0x8 + 0x100 + 0x200
local SPAN_VTF_FORMAT = 25
local SKY_FLAGS = bit.bor(SURF_SKY, SURF_SKY2D)
local IGNORED_FLAGS = bit.bor(SURF_TRIGGER, SURF_HINT, SURF_SKIP)
local MSG_KEY, MSG_CHUNK = 0, 1
local EXPOSURE_PS, EXPOSURE_VS = "borealis_coverexposure_ps30", "borealis_passthrough_vs30"
local EXPOSURE_SIZE, EXPOSURE_EXTENT = 256, 4096
local EXPOSURE_STEP = 256
local EXPOSURE_EVERY = 4
local PACK_PS = "borealis_spanpack_ps30"
local PACK_RT_FLAGS = 0x1 + 0x4 + 0x8
local PACK_BYTES_FORMAT = 0
local PACK_BYTES_FLAGS = SPAN_VTF_FLAGS + 0x2000

cover.COLUMN, cover.COLUMNS, cover.Z_MIN, cover.Z_RANGE = COLUMN, COLUMNS, Z_MIN, Z_RANGE
cover.EXPOSURE_SHADERS = { EXPOSURE_PS, EXPOSURE_VS }
cover.PACK_SHADERS = { PACK_PS, EXPOSURE_VS }
cover.GLOSS = GLOSS
cover.listeners = cover.listeners or {}

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

local spanTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector() }

local function openBottom(wx, wy, top, bottom)
	local from = top - SPAN_TRACE_INSET
	if from <= bottom then return bottom end

	spanTrace.start:SetUnpacked(wx, wy, from)
	spanTrace.endpos:SetUnpacked(wx, wy, bottom)
	local tr = util.TraceLine(spanTrace)
	if tr.StartSolid then
		local exit = from - tr.FractionLeftSolid * (from - bottom) - 1
		spanTrace.start:SetUnpacked(wx, wy, exit)
		spanTrace.endpos:SetUnpacked(wx, wy, from)
		if not util.TraceLine(spanTrace).HitSky then return end

		spanTrace.endpos:SetUnpacked(wx, wy, bottom)
		tr = util.TraceLine(spanTrace)
	end

	return tr.Hit and math.max(tr.HitPos.z, bottom) or bottom
end

local function columnBytes(list, count, bytes, x, wx, wy)
	local slot = 0
	if count > 0 then
		table.sort(list, descending)
		local prev
		for k = 1, count do
			local v = list[k]
			if v ~= prev and v % 2 == 1 and slot < SPAN_SLOTS then
				local m = k + 1
				while list[m] == v do
					m = m + 1
				end

				local below = list[m]
				local top = (v - 1) / 8
				local bottom = openBottom(wx, wy, top, below and (below - below % 2) / 8 or SPAN_MIN)
				if bottom then
					writeSpan(bytes, x, slot, heightValue(top), heightValue(bottom))
					slot = slot + 1
				end
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

local function openColumnBytes(list, count, bytes, x)
	for k = 1, count do
		list[k] = nil
	end

	writeSpan(bytes, x, 0, 65535, 0)
	for s = 1, SPAN_SLOTS - 1 do
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

	local rows = { shaderpack.VTFHeader(SPAN_COLUMNS * 2, SPAN_COLUMNS, SPAN_VTF_FORMAT, SPAN_VTF_FLAGS) }
	local rowBytes = {}
	for r = 1, SPAN_TILE do
		rowBytes[r] = {}
	end

	local world = bspdata.SkyCamera()
	local function beyondWorld(x, y)
		return world ~= nil and (x < world.x0 or x > world.x1 or y < world.y0 or y > world.y1)
	end

	for tileY = 0, tilesPerSide - 1 do
		for tileX = 0, tilesPerSide - 1 do
			yieldIfOverBudget()
			rasterTile(tileX, tileY)
			for j = 0, SPAN_TILE - 1 do
				local bytes = rowBytes[j + 1]
				local wy = SPAN_MIN + (tileY * SPAN_TILE + j + 0.5) * SPAN_COLUMN
				for i = 0, SPAN_TILE - 1 do
					local idx = j * SPAN_TILE + i
					local column = tileX * SPAN_TILE + i
					local wx = SPAN_MIN + (column + 0.5) * SPAN_COLUMN
					if beyondWorld(wx, wy) then
						openColumnBytes(hits[idx], counts[idx], bytes, column)
					else
						columnBytes(hits[idx], counts[idx], bytes, column, wx, wy)
					end
					counts[idx] = 0
				end

				yieldIfOverBudget()
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
	shaderpack.AddResources(cover.EXPOSURE_SHADERS)
	shaderpack.AddResources(cover.PACK_SHADERS)

	local key, compressedSpans
	local waiting, sends = {}, {}
	local bakeCo
	local downloadUrl = GetConVar("sv_downloadurl")

	local function announce(ply)
		net.Start(SPAN_NET)
		net.WriteUInt(MSG_KEY, 2)
		net.WriteString(key)
		net.WriteUInt(#compressedSpans, 32)
		net.Send(ply)
		if fatdl and downloadUrl:GetString() ~= "" then
			fatdl.Send(SPAN_NET, ply, compressedSpans)
		else
			sends[ply] = { offset = 0, at = 0 }
		end
	end

	local function ready(compressed)
		compressedSpans = compressed
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

		local now = RealTime()
		for ply, send in pairs(sends) do
			if not IsValid(ply) then
				sends[ply] = nil
			elseif now >= send.at then
				local data = string.sub(compressedSpans, send.offset + 1, send.offset + SPAN_CHUNK)
				net.Start(SPAN_NET)
				net.WriteUInt(MSG_CHUNK, 2)
				net.WriteUInt(#data, 16)
				net.WriteData(data, #data)
				net.Send(ply)
				send.offset = send.offset + #data
				send.at = now + #data / SPAN_RATE
				if send.offset >= #compressedSpans then
					sends[ply] = nil
				end
			end
		end
	end

	local function connected(ply)
		if compressedSpans then
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

	shaderpack.OnPlayerReady(SPAN_NET, connected)

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
local levels, levelFrame, levelResult = {}, -1, nil
local searchCell, searchTop
local TOGL = not system.IsWindows()
local SPAN_PACK = SPAN_NET .. "_pack"

local function packSpans(key)
	local packedKey = key .. "_rgba8"
	if not file.Exists(spanPath(packedKey, "vtf"), "DATA") then
		file.Write(spanPath(packedKey, "vtf"), shaderpack.VTFHeader(SPAN_COLUMNS * 4, SPAN_COLUMNS, PACK_BYTES_FORMAT, PACK_BYTES_FLAGS) .. string.sub(spanData, 81))
	end

	shaderpack.WhenMounted(SPAN_PACK, cover.PACK_SHADERS, function()
		hook.Add("PostRender", SPAN_PACK, function()
			hook.Remove("PostRender", SPAN_PACK)
			if cover.spanKey ~= key then return end

			local rt = GetRenderTargetEx("borealis_cover_spans_packed", SPAN_COLUMNS * 2, SPAN_COLUMNS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, PACK_RT_FLAGS, 0, IMAGE_FORMAT_RGBA16161616)
			if not shaderpack.UsableRT(rt, SPAN_COLUMNS * 2, SPAN_COLUMNS) then return end

			local mat = CreateShaderMaterial("borealis_cover_spanpack_" .. packedKey, {
				["$pixshader"] = PACK_PS,
				["$vertexshader"] = EXPOSURE_VS,
				["$texture1"] = "../data/" .. SPAN_DIR .. "/" .. packedKey,
				["$linearread_texture1"] = 1,
				["$alpha_blend"] = 0,
				["$additive"] = 0,
			})

			render.PushRenderTarget(rt)
			render.OverrideAlphaWriteEnable(true, true)
			render.SetMaterial(mat)
			render.DrawScreenQuad()
			render.OverrideAlphaWriteEnable(false)
			render.PopRenderTarget()
			spanTexture = rt
		end)
	end)
end

local function loadSpans(key)
	if TOGL then
		spanTexture = nil
		spanData = file.Read(spanPath(key, "vtf"), "DATA")
	else
		local mat = CreateMaterial("borealis_cover_spans_" .. key, "UnlitGeneric", { ["$basetexture"] = "../data/" .. SPAN_DIR .. "/" .. key })
		local tex = mat:GetTexture("$basetexture")
		spanTexture = tex and not tex:IsError() and tex or nil
		spanData = spanTexture and file.Read(spanPath(key, "vtf"), "DATA") or nil
	end

	levels, levelFrame = {}, -1
	searchCell, searchTop = nil, nil
	cover.spanKey = spanData and key or nil
	if TOGL and spanData then packSpans(key) end
end

if cover.spanKey then
	loadSpans(cover.spanKey)
end

local function spanHeight(pos)
	local lo, hi = string.byte(spanData, pos, pos + 1)

	return (hi * 256 + lo) / 65535 * SPAN_SIZE + SPAN_MIN
end

local function spanBase(x, y)
	local cx = math.Clamp(math.floor((x - SPAN_MIN) / SPAN_COLUMN), 0, SPAN_COLUMNS - 1)
	local cy = math.Clamp(math.floor((y - SPAN_MIN) / SPAN_COLUMN), 0, SPAN_COLUMNS - 1)

	return 81 + (cy * SPAN_COLUMNS * 2 + cx) * 8
end

local function spanSlot(base, s)
	local pos = s < 2 and base + s * 4 or base + SPAN_COLUMNS * 8 + (s - 2) * 4

	return spanHeight(pos), spanHeight(pos + 2)
end

local function spanCoverZ(x, y, top)
	local base = spanBase(x, y)
	for s = 0, SPAN_SLOTS - 1 do
		local spanTop, spanBottom = spanSlot(base, s)
		if spanBottom <= top and top <= spanTop then
			return spanBottom
		end
	end

	return Z_MIN + Z_RANGE
end

local function spanOpen(x, y, z)
	local base = spanBase(x, y)
	for s = 0, SPAN_SLOTS - 1 do
		local spanTop, spanBottom = spanSlot(base, s)
		if spanBottom <= z and z <= spanTop then
			return true
		end
	end

	return false
end

local LEVEL_MARGIN_BELOW, LEVEL_MARGIN_ABOVE = 1000, 64
local LEVEL_TOLERANCE = 64
local LEVEL_SEARCH_STEP, LEVEL_SEARCH_RINGS, LEVEL_SEARCH_CELL = 64, 16, 256
local LEVEL_GROUND_TOLERANCE = 32
local airborneLevel = {}

local function skyAbove(x, y, z)
	local base = spanBase(x, y)
	local best, bestBottom
	for s = 0, SPAN_SLOTS - 1 do
		local top, bottom = spanSlot(base, s)
		if bottom <= top and top >= z and (not best or top < best) then
			best, bestBottom = top, bottom
		end
	end

	return best, bestBottom
end

local function skyReachable(x, y, eye)
	local top, bottom = skyAbove(x, y, eye.z - LEVEL_MARGIN_ABOVE)
	if top and eye.z >= bottom - LEVEL_MARGIN_BELOW then return top end
end

local function skyNear(eye)
	local top = skyReachable(eye.x, eye.y, eye)
	if top then return top end

	local cell = math.floor(eye.x / LEVEL_SEARCH_CELL) .. " " .. math.floor(eye.y / LEVEL_SEARCH_CELL) .. " " .. math.floor(eye.z / LEVEL_SEARCH_STEP)
	if cell == searchCell then return searchTop end
	searchCell, searchTop = cell, nil

	for r = 1, LEVEL_SEARCH_RINGS do
		local bestDist
		for i = -r, r do
			for j = -r, r, (i == -r or i == r) and 1 or 2 * r do
				local found = skyReachable(eye.x + i * LEVEL_SEARCH_STEP, eye.y + j * LEVEL_SEARCH_STEP, eye)
				local dist = i * i + j * j
				if found and (not bestDist or dist < bestDist) then
					searchTop, bestDist = found, dist
				end
			end
		end

		if searchTop then break end
	end

	return searchTop
end

local function resolveLevel(eye)
	local top = skyNear(eye)
	if not top then return end

	local key = math.floor(top / LEVEL_TOLERANCE + 0.5)
	if levels[key] then return levels[key] end

	local down = util.TraceLine({ start = eye, endpos = eye - Vector(0, 0, Z_RANGE), mask = MASK_SOLID_BRUSHONLY })
	local floor = down.Hit and down.HitPos.z or eye.z
	local ply = LocalPlayer()
	if IsValid(ply) and ply:IsOnGround() and math.abs(floor - ply:GetPos().z) <= LEVEL_GROUND_TOLERANCE then
		levels[key] = { floor = floor, ceiling = top }

		return levels[key]
	end

	airborneLevel.floor, airborneLevel.ceiling = floor, top

	return airborneLevel
end

function cover.SkyLevel()
	if not spanData then return end

	local frame = FrameNumber()
	if frame == levelFrame then return levelResult end
	levelFrame = frame

	local eye = render.GetViewSetup().origin
	local lvl = resolveLevel(eye)
	levelResult = lvl and eye.z >= lvl.floor - LEVEL_MARGIN_BELOW and lvl or nil

	return levelResult
end

local function spanReceived(compressed)
	local vtf = util.Decompress(compressed)
	local key = spanPending.key
	spanPending = nil
	if not vtf then return end

	file.CreateDir(SPAN_DIR)
	file.Write(spanPath(key, "vtf"), vtf)
	loadSpans(key)
end

local function receiveFatdl()
	fatdl.Receive(SPAN_NET, function(compressed)
		if spanPending then spanReceived(compressed) end
	end)
end

if fatdl then
	receiveFatdl()
else
	hook.Add("Initialize", SPAN_NET, function()
		if fatdl then receiveFatdl() end
	end)
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
			spanReceived(table.concat(spanPending.parts))
		end
	end
end)

local coverRT
local texelColumn, ground, coverZs, pending, queued = {}, {}, {}, {}, {}
local traceZ, winX, winY
local sweepIndex, firstSweep = 1, true
local updatedFrame = -1
local upTrace = { mask = SOLID, start = Vector(), endpos = Vector(), output = {} }
local downTrace = { mask = SOLID, start = Vector(), endpos = Vector(), output = {} }
local waterTrace = { mask = WATER, start = Vector(), endpos = Vector(), output = {} }
local players, playerCount = {}, -1
local contentsPos = Vector()

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

local function solidExit(x, y, top, bottom)
	downTrace.start:SetUnpacked(x, y, top)
	downTrace.endpos:SetUnpacked(x, y, bottom)
	local down = bspdata.TraceLine(downTrace)
	if not down.StartSolid then return top end
	if down.AllSolid then return nil end

	return top + (bottom - top) * down.FractionLeftSolid - EXIT_INSET
end

local function traceOpenColumn(cx, cy, top, bottom)
	local x, y = (cx + 0.5) * COLUMN, (cy + 0.5) * COLUMN
	upTrace.start:SetUnpacked(x, y, top)
	upTrace.endpos:SetUnpacked(x, y, top + 8192)
	local up = bspdata.TraceLine(upTrace)
	if up.StartSolid then
		top = solidExit(x, y, top, bottom)
		if not top or top <= bottom then
			return Z_MIN + Z_RANGE, false, 1, false
		end

		upTrace.start:SetUnpacked(x, y, top)
		upTrace.endpos:SetUnpacked(x, y, top + 8192)
		up = bspdata.TraceLine(upTrace)
	end

	if up.StartSolid or (up.Hit and not up.HitSky) then
		return Z_MIN + Z_RANGE, false, 1, false
	end

	downTrace.start:SetUnpacked(x, y, top)
	downTrace.endpos:SetUnpacked(x, y, bottom)
	local down = bspdata.TraceLine(downTrace)
	if down.Hit then
		local hit = down.HitPos
		contentsPos:SetUnpacked(hit.x, hit.y, hit.z + 1)
		if bit.band(bspdata.PointContents(contentsPos), IN_WATER) == 0 then
			local level = false
			contentsPos.z = hit.z - SHORE_DEPTH
			if bit.band(bspdata.PointContents(contentsPos), IN_WATER) ~= 0 then
				waterTrace.start:SetUnpacked(x, y, hit.z + 1)
				waterTrace.endpos:Set(contentsPos)
				local shore = bspdata.TraceLine(waterTrace)
				level = shore.Hit and not shore.StartSolid and shore.HitPos.z
			end

			return hit.z, down.HitNormal.z > SPLASH_SLOPE and hit.z + 0.4, GLOSS[down.MatType] or 1, level, down.HitNormal.z
		end
	end

	waterTrace.start:SetUnpacked(x, y, top)
	waterTrace.endpos:SetUnpacked(x, y, bottom)
	local water = bspdata.TraceLine(waterTrace)
	if water.StartSolid then
		return Z_MIN + Z_RANGE, false, 1, false
	end

	if water.Hit then
		return water.HitPos.z, water.HitPos.z + 0.4, down.Hit and GLOSS[down.MatType] or 1, water.HitPos.z
	end

	if down.Hit then
		return down.HitPos.z, false, GLOSS[down.MatType] or 1, false, down.HitNormal.z
	end

	return spanData and spanCoverZ(x, y, top) or Z_MIN, false, SPAN_GLOSS, false
end

local function spanCeiling(x, y, top, bottom)
	local mid, best = (top + bottom) * 0.5
	local base = spanBase(x, y)
	for s = 0, SPAN_SLOTS - 1 do
		local spanTop, spanBottom = spanSlot(base, s)
		if spanBottom <= spanTop and spanTop >= mid and spanTop < top and (not best or spanTop < best) then
			best = spanTop
		end
	end

	return best and best - EXIT_INSET or top
end

local function traceColumn(cx, cy, top, bottom)
	if spanData then
		top = spanCeiling((cx + 0.5) * COLUMN, (cy + 0.5) * COLUMN, top, bottom)
	end

	local coverZ, level, gloss, waterLevel, normalZ = traceOpenColumn(cx, cy, top, bottom)
	if spanData and coverZ < Z_MIN + Z_RANGE then
		local nz = math.Clamp(normalZ or 1, SPAN_MIN_NORMAL, 1)
		local margin = SPAN_OPEN_MARGIN + SPAN_COLUMN_OFFSET * math.sqrt(1 - nz * nz) / nz
		if not spanOpen((cx + 0.5) * COLUMN, (cy + 0.5) * COLUMN, coverZ + margin) then
			return Z_MIN + Z_RANGE, false, 1, false
		end
	end

	return coverZ, level, gloss, waterLevel
end

local function writeTexel(cx, cy, coverZ, gloss, level)
	local v = math.floor(math.Clamp((coverZ - Z_MIN) / Z_RANGE, 0, 1) * 65535 + 0.5)
	local hi = math.floor(v / 256)
	render.SetViewPort(cx % COLUMNS, cy % COLUMNS, 1, 1)
	render.Clear(hi, v - hi * 256, math.floor(gloss * 255 + 0.5), level and math.floor(math.Clamp((coverZ - level) / SHORE_DEPTH, 0, 1) * 254 + 0.5) or 255)
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

local function assignTexel(cx, cy, key)
	local texel = cx % COLUMNS * COLUMNS + cy % COLUMNS
	local prev = texelColumn[texel]
	if prev and prev ~= key then
		ground[prev] = nil
		coverZs[prev] = nil
	end

	texelColumn[texel] = key
end

local function fillFromSpans(keys)
	if #keys == 0 or not spanData then return end

	local top = traceZ + TRACE_HALF
	render.PushRenderTarget(coverRT)
	for i = 1, #keys do
		local key = keys[i]
		local cx, cy = columnFromKey(key)
		assignTexel(cx, cy, key)
		writeTexel(cx, cy, spanCoverZ((cx + 0.5) * COLUMN, (cy + 0.5) * COLUMN, top), SPAN_GLOSS)
	end

	render.SetViewPort(0, 0, COLUMNS, COLUMNS)
	render.PopRenderTarget()
end

local function enter(cx, cy, entered, queue)
	local key = columnKey(cx, cy)
	if texelColumn[cx % COLUMNS * COLUMNS + cy % COLUMNS] ~= key then
		entered[#entered + 1] = key
	elseif coverZs[key] then
		return
	end

	if queue and not queued[key] then
		queued[key] = true
		pending[#pending + 1] = key
	end
end

local function enterRange(cy, x0, x1, entered)
	for cx = x0, x1 do
		enter(cx, cy, entered, true)
	end
end

local function enterStrips(oldX, oldY, entered)
	local x1 = winX + COLUMNS - 1
	for cy = winY, winY + COLUMNS - 1 do
		if cy < oldY or cy >= oldY + COLUMNS then
			enterRange(cy, winX, x1, entered)
		else
			enterRange(cy, winX, math.min(x1, oldX - 1), entered)
			enterRange(cy, math.max(winX, oldX + COLUMNS), x1, entered)
		end
	end
end

local function enterWindow(entered)
	for cy = winY, winY + COLUMNS - 1 do
		for cx = winX, winX + COLUMNS - 1 do
			enter(cx, cy, entered, false)
		end
	end
end

local function notify(cx, cy, coverChanged, groundChanged)
	for _, l in pairs(cover.listeners) do
		if l.column then
			l.column(cx, cy, coverChanged, groundChanged)
		end
	end
end

local function traceOne(cx, cy, top, bottom)
	local key = columnKey(cx, cy)
	local coverZ, level, gloss, waterLevel = traceColumn(cx, cy, top, bottom)
	assignTexel(cx, cy, key)
	local coverChanged = coverZs[key] ~= coverZ
	coverZs[key] = coverZ

	local groundChanged = (ground[key] or false) ~= level
	ground[key] = level or nil

	if coverChanged or groundChanged then
		notify(cx, cy, coverChanged, groundChanged)
	end

	writeTexel(cx, cy, coverZ, gloss, waterLevel)
end

local function moveWindow(eye)
	local half = COLUMNS / 2
	local cx0, cy0 = math.floor(eye.x / COLUMN) - half, math.floor(eye.y / COLUMN) - half
	if not traceZ or math.abs(eye.z - traceZ) > TRACE_SLOT then
		traceZ = eye.z
		sweepIndex, firstSweep = 1, true
	end

	if cx0 == winX and cy0 == winY then return end

	local oldX, oldY = winX, winY
	winX, winY = cx0, cy0
	local entered = {}
	if oldX and math.abs(cx0 - oldX) < COLUMNS and math.abs(cy0 - oldY) < COLUMNS then
		enterStrips(oldX, oldY, entered)
	else
		pending, queued = {}, {}
		enterWindow(entered)
		sweepIndex, firstSweep = 1, true
	end

	fillFromSpans(entered)
end

local function updateColumns(eye)
	moveWindow(eye)

	local top, bottom = traceZ + TRACE_HALF, traceZ - TRACE_HALF
	if player.GetCount() ~= playerCount then
		players, playerCount = player.GetAll(), player.GetCount()
		upTrace.filter, downTrace.filter = players, players
	end
	local budget = (firstSweep or #pending > 0) and TRACES_PER_FRAME or IDLE_TRACES_PER_FRAME
	local deadline = SysTime() + PENDING_TIME
	render.PushRenderTarget(coverRT)
	while #pending > 0 and (budget > 0 or SysTime() < deadline) do
		local key = table.remove(pending)
		queued[key] = nil
		local cx, cy = columnFromKey(key)
		if cx >= winX and cx < winX + COLUMNS and cy >= winY and cy < winY + COLUMNS then
			traceOne(cx, cy, top, bottom)
			budget = budget - 1
		end
	end

	for _ = 1, budget do
		traceOne(winX + sweepX[sweepIndex], winY + sweepY[sweepIndex], top, bottom)
		sweepIndex = sweepIndex % #sweepX + 1
		if sweepIndex == 1 then
			firstSweep = false
		end
	end

	render.SetViewPort(0, 0, COLUMNS, COLUMNS)
	render.PopRenderTarget()
end

local function build()
	coverRT = coverRT or GetRenderTargetEx("borealis_rain_cover_" .. COLUMNS, COLUMNS, COLUMNS, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, 1, 0, IMAGE_FORMAT_RGBA8888)
	if not shaderpack.UsableRT(coverRT, COLUMNS) then
		coverRT = nil

		return false
	end

	render.PushRenderTarget(coverRT)
	render.Clear(0, 0, 0, 255)
	render.PopRenderTarget()
	texelColumn, ground, coverZs, pending, queued = {}, {}, {}, {}, {}
	traceZ, winX, winY = nil, nil, nil
	sweepIndex, firstSweep = 1, true
	for _, l in pairs(cover.listeners) do
		if l.reset then
			l.reset()
		end
	end

	return true
end

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

function cover.HeightAt(x, y)
	local cx, cy = math.floor(x / COLUMN), math.floor(y / COLUMN)
	local key = columnKey(cx, cy)
	if texelColumn[cx % COLUMNS * COLUMNS + cy % COLUMNS] ~= key then return nil end

	return coverZs[key]
end

local RASTER_SIZE, RASTER_HALF = 320, 640
local RASTER_SNAP, RASTER_RECENTRE = 128, 128
local RASTER_HEIGHT, RASTER_DEPTH, RASTER_FLOOR = 40000, 16384, 64
local RASTER_TILE, RASTER_TILE_MARGIN, RASTER_TILE_KEEP = 1024, 256, 256
local RASTER_CHUNK, RASTER_LOD, RASTER_FLAT, RASTER_MIN_PROP = 4096, 2, 0.02, 16
local RASTER_SKIP = bit.bor(SURF_SKY, SURF_SKY2D, SURF_NODRAW, SURF_TRIGGER, SURF_HINT, SURF_SKIP)
local RASTER_SCAN_INTERVAL = 0.25
local RASTER_MOVE, RASTER_TURN = 32, 15
local RASTER_SHIFT, RASTER_SHIFT_TURN = 4, 2
local RASTER_RT_FLAGS, RASTER_FORMAT = 1 + 4 + 8, 27
local RASTER_IDLE = 30

local raster = {
	tiles = {}, queue = {}, models = {}, casters = {}, state = {},
	staticDirty = false, dirty = false, ready = false, idle = false,
	nextScan = 0, frame = -1, used = 0,
}
local rasterVector = Vector()
local rasterView = {
	type = "3D", origin = Vector(), angles = Angle(90, 90, 0),
	znear = RASTER_HEIGHT, zfar = RASTER_HEIGHT + RASTER_DEPTH,
	fov = 2 * math.deg(math.atan(RASTER_HALF / RASTER_HEIGHT)), aspect = 1,
	x = 0, y = 0, w = RASTER_SIZE, h = RASTER_SIZE,
}

local function rasterSurface(name)
	if name:lower():find("^tools/") or Material(name):GetShader():lower():find("water", 1, true) then return end

	return 1
end

local function tileKey(tx, ty)
	return tx .. ":" .. ty
end

local function appendTri(out, ax, ay, az, bx, by, bz, cx, cy, cz)
	local ux, uy, uz = bx - ax, by - ay, bz - az
	local vx, vy, vz = cx - ax, cy - ay, cz - az
	local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
	local len = math.sqrt(nx * nx + ny * ny + nz * nz)
	if len < 1e-6 or math.abs(nz) < RASTER_FLAT * len then return end

	local n = #out
	out[n + 1], out[n + 2], out[n + 3] = ax, ay, az
	out[n + 4], out[n + 5], out[n + 6] = bx, by, bz
	out[n + 7], out[n + 8], out[n + 9] = cx, cy, cz
end

local function modelTriangles(model)
	local flat = raster.models[model]
	if flat then return flat end

	flat = {}
	local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
	for _, sub in ipairs(util.GetModelMeshes(model, RASTER_LOD) or {}) do
		for _, v in ipairs(sub.triangles) do
			local p, n = v.pos, #flat
			local x, y, z = p.x, p.y, p.z
			flat[n + 1], flat[n + 2], flat[n + 3] = x, y, z
			x0, y0, z0 = math.min(x0, x), math.min(y0, y), math.min(z0, z)
			x1, y1, z1 = math.max(x1, x), math.max(y1, y), math.max(z1, z)
		end
	end

	local sx, sy, sz = x1 - x0, y1 - y0, z1 - z0
	flat.size = #flat >= 9 and math.max(math.min(sx, sy), math.min(sx, sz), math.min(sy, sz)) or 0
	raster.models[model] = flat

	return flat
end

local function appendProp(out, prop)
	local flat = modelTriangles(prop.model)
	local s = prop.scale or 1
	if flat.size * s < RASTER_MIN_PROP then return end

	local o = prop.origin
	local f, r, u = prop.angles:Forward(), prop.angles:Right(), prop.angles:Up()
	local fx, fy, fz = f.x * s, f.y * s, f.z * s
	local lx, ly, lz = -r.x * s, -r.y * s, -r.z * s
	local ux, uy, uz = u.x * s, u.y * s, u.z * s
	local ox, oy, oz = o.x, o.y, o.z
	for i = 1, #flat - 8, 9 do
		local ax, ay, az = flat[i], flat[i + 1], flat[i + 2]
		local bx, by, bz = flat[i + 3], flat[i + 4], flat[i + 5]
		local cx, cy, cz = flat[i + 6], flat[i + 7], flat[i + 8]
		appendTri(out,
			ox + fx * ax + lx * ay + ux * az, oy + fy * ax + ly * ay + uy * az, oz + fz * ax + lz * ay + uz * az,
			ox + fx * bx + lx * by + ux * bz, oy + fy * bx + ly * by + uy * bz, oz + fz * bx + lz * by + uz * bz,
			ox + fx * cx + lx * cy + ux * cz, oy + fy * cx + ly * cy + uy * cz, oz + fz * cx + lz * cy + uz * cz)
	end
end

local function buildMeshes(out, yieldIfOverBudget)
	local meshes = {}
	local total = #out / 9
	for first = 0, total - 1, RASTER_CHUNK do
		local count = math.min(RASTER_CHUNK, total - first)
		local m = Mesh(raster.depth)
		mesh.Begin(m, MATERIAL_TRIANGLES, count)
		for i = first * 9 + 1, (first + count) * 9, 3 do
			rasterVector:SetUnpacked(out[i], out[i + 1], out[i + 2])
			mesh.Position(rasterVector)
			mesh.AdvanceVertex()
		end
		mesh.End()
		meshes[#meshes + 1] = m
		yieldIfOverBudget()
	end

	return meshes
end

local function destroyMeshes(meshes)
	for _, m in ipairs(meshes) do
		m:Destroy()
	end
end

local function buildTile(key, yieldIfOverBudget)
	local out = {}
	local world = raster.world[key]
	if world then
		for i = 1, #world do
			out[i] = world[i]
		end
	end

	yieldIfOverBudget()
	for _, prop in ipairs(raster.props[key] or {}) do
		appendProp(out, prop)
		yieldIfOverBudget()
	end

	return buildMeshes(out, yieldIfOverBudget)
end

local function loadRaster()
	local yieldIfOverBudget = bspdata.FrameBudget()
	local grid = bspdata.Triangles(rasterSurface, -1, true, RASTER_SKIP)
	if not grid then return end

	local props = {}
	for _, prop in ipairs(bspdata.StaticProps()) do
		local key = tileKey(math.floor(prop.origin.x / RASTER_TILE), math.floor(prop.origin.y / RASTER_TILE))
		local list = props[key] or {}
		props[key] = list
		list[#list + 1] = prop
	end

	grid = bspdata.RemoveSkybox(grid)
	local world = {}
	for key, cell in pairs(grid) do
		local flat = {}
		for _, t in ipairs(cell) do
			appendTri(flat, t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9])
		end

		if #flat > 0 then world[key] = flat end
		grid[key] = nil
		yieldIfOverBudget()
	end

	raster.world, raster.props = world, props
	raster.staticDirty = true
	while true do
		local key = table.remove(raster.queue, 1)
		if key then
			if raster.tiles[key] == false then
				local meshes = buildTile(key, yieldIfOverBudget)
				if raster.tiles[key] == false then
					raster.tiles[key] = meshes
					raster.staticDirty = true
				else
					destroyMeshes(meshes)
				end
			end
		else
			raster.idle = true
			coroutine.yield()
			raster.idle = false
		end
	end
end

local function tileRange(margin)
	local reach = RASTER_HALF + RASTER_TILE_MARGIN + margin

	return math.floor((raster.x - reach) / RASTER_TILE), math.floor((raster.y - reach) / RASTER_TILE),
		math.floor((raster.x + reach) / RASTER_TILE), math.floor((raster.y + reach) / RASTER_TILE)
end

local function requestTiles()
	local tx0, ty0, tx1, ty1 = tileRange(RASTER_TILE_KEEP)
	for key, meshes in pairs(raster.tiles) do
		local tx, ty = key:match("^(%-?%d+):(%-?%d+)$")
		tx, ty = tonumber(tx), tonumber(ty)
		if tx < tx0 or tx > tx1 or ty < ty0 or ty > ty1 then
			if meshes then destroyMeshes(meshes) end
			raster.tiles[key] = nil
		end
	end

	tx0, ty0, tx1, ty1 = tileRange(0)
	local cx, cy = raster.x / RASTER_TILE - 0.5, raster.y / RASTER_TILE - 0.5
	local wanted = {}
	for ty = ty0, ty1 do
		for tx = tx0, tx1 do
			local key = tileKey(tx, ty)
			if raster.tiles[key] == nil then
				raster.tiles[key] = false
				wanted[#wanted + 1] = { key, (tx - cx) ^ 2 + (ty - cy) ^ 2 }
			end
		end
	end

	table.sort(wanted, function(a, b) return a[2] < b[2] end)
	for _, w in ipairs(wanted) do
		raster.queue[#raster.queue + 1] = w[1]
	end
end

local function tilesComplete()
	local tx0, ty0, tx1, ty1 = tileRange(0)
	for ty = ty0, ty1 do
		for tx = tx0, tx1 do
			if not raster.tiles[tileKey(tx, ty)] then return false end
		end
	end

	return true
end

local function buildRaster()
	local static = GetRenderTargetEx("borealis_cover_raster_static_" .. RASTER_SIZE, RASTER_SIZE, RASTER_SIZE, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, RASTER_RT_FLAGS, 0, RASTER_FORMAT)
	local combined = GetRenderTargetEx("borealis_cover_raster_" .. RASTER_SIZE, RASTER_SIZE, RASTER_SIZE, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, RASTER_RT_FLAGS, 0, RASTER_FORMAT)
	if not shaderpack.UsableRT(static, RASTER_SIZE) or not shaderpack.UsableRT(combined, RASTER_SIZE) then return false end

	raster.staticRT, raster.rt = static, combined
	raster.depth = CreateMaterial("borealis_cover_raster_depth", "DepthWrite", { ["$color_depth"] = 1, ["$nocull"] = 1 })
	raster.copy = CreateMaterial("borealis_cover_raster_copy", "UnlitGeneric", { ["$basetexture"] = static:GetName(), ["$ignorez"] = 1 })
	raster.copy:SetTexture("$basetexture", static)

	return true
end

local function startCapture(rt)
	render.PushRenderTarget(rt)
	rasterView.origin:SetUnpacked(raster.x, raster.y, raster.cut + RASTER_HEIGHT)
	cam.Start(rasterView)
	cam.IgnoreZ(true)
	render.ClearDepth()
end

local function endCapture()
	cam.IgnoreZ(false)
	cam.End3D()
	render.PopRenderTarget()
end

local function drawStatic()
	startCapture(raster.staticRT)
	render.SetMaterial(raster.depth)
	local z, e = raster.cut - RASTER_DEPTH + RASTER_FLOOR, RASTER_HALF * 2
	mesh.Begin(MATERIAL_QUADS, 1)
	rasterVector:SetUnpacked(raster.x - e, raster.y - e, z) mesh.Position(rasterVector) mesh.AdvanceVertex()
	rasterVector:SetUnpacked(raster.x + e, raster.y - e, z) mesh.Position(rasterVector) mesh.AdvanceVertex()
	rasterVector:SetUnpacked(raster.x + e, raster.y + e, z) mesh.Position(rasterVector) mesh.AdvanceVertex()
	rasterVector:SetUnpacked(raster.x - e, raster.y + e, z) mesh.Position(rasterVector) mesh.AdvanceVertex()
	mesh.End()

	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MIN)
	local tx0, ty0, tx1, ty1 = tileRange(0)
	for ty = ty0, ty1 do
		for tx = tx0, tx1 do
			for _, m in ipairs(raster.tiles[tileKey(tx, ty)] or {}) do
				m:Draw()
			end
		end
	end
	render.OverrideBlend(false)
	endCapture()
end

local function compose()
	render.PushRenderTarget(raster.rt)
	render.SetMaterial(raster.copy)
	render.DrawScreenQuad()
	render.PopRenderTarget()
	if #raster.casters == 0 then return end

	startCapture(raster.rt)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MIN)
	render.MaterialOverride(raster.depth)
	render.BrushMaterialOverride(raster.depth)
	for _, e in ipairs(raster.casters) do
		local s = raster.state[e]
		if IsValid(e) and s then
			s.drawnPos, s.drawnAng = e:GetPos(), e:GetAngles()
			e:DrawModel()
		end
	end
	render.BrushMaterialOverride()
	render.MaterialOverride()
	render.OverrideBlend(false)
	endCapture()
end

local function castsCover(e)
	if not IsValid(e) or e:EntIndex() <= 0 or e:IsDormant() or e:GetNoDraw() then return false end
	if e:IsPlayer() or e:IsWeapon() then return false end

	local model = e:GetModel()
	if not model or (model:sub(1, 1) ~= "*" and model:sub(-4):lower() ~= ".mdl") then return false end

	local parent = e:GetParent()
	if IsValid(parent) and parent:IsPlayer() then return false end

	local class = e:GetClass()

	return class ~= "viewmodel" and class ~= "predicted_viewmodel" and class ~= "gmod_hands"
end

local function far(p, a, lp, la, dist, turn)
	return p:DistToSqr(lp) > dist * dist
		or math.abs(math.AngleDifference(a.p, la.p)) > turn
		or math.abs(math.AngleDifference(a.y, la.y)) > turn
		or math.abs(math.AngleDifference(a.r, la.r)) > turn
end

local scanMin, scanMax = Vector(), Vector()

local function scanCasters()
	scanMin:SetUnpacked(raster.x - RASTER_HALF, raster.y - RASTER_HALF, raster.cut - RASTER_DEPTH)
	scanMax:SetUnpacked(raster.x + RASTER_HALF, raster.y + RASTER_HALF, raster.cut)
	local old, state, found = {}, {}, {}
	for _, e in ipairs(raster.casters) do
		old[e] = true
	end

	local changed = false
	local now = RealTime()
	for _, e in ipairs(ents.FindInBox(scanMin, scanMax)) do
		if castsCover(e) then
			local p, a = e:GetPos(), e:GetAngles()
			local s = raster.state[e]
			if not s then
				s = { pos = p, ang = a, time = now }
			elseif now - s.time >= RASTER_SCAN_INTERVAL then
				s.still = not far(p, a, s.pos, s.ang, RASTER_MOVE, RASTER_TURN)
				s.pos, s.ang, s.time = p, a, now
				if s.still and s.drawnPos and far(p, a, s.drawnPos, s.drawnAng, RASTER_SHIFT, RASTER_SHIFT_TURN) then
					changed = true
				end
			end

			state[e] = s
			if s.still then
				found[#found + 1] = e
				if not old[e] then changed = true end
				old[e] = nil
			end
		end
	end

	raster.state, raster.casters = state, found
	if changed or next(old) ~= nil then raster.dirty = true end
end

cover.rasterListeners = cover.rasterListeners or {}

function cover.ListenRaster(id, onMoved)
	cover.rasterListeners[id] = onMoved
end

function cover.UnlistenRaster(id)
	cover.rasterListeners[id] = nil
end

local function dropMoving()
	local kept, moving = {}, nil
	for _, e in ipairs(raster.casters) do
		local s = raster.state[e]
		if IsValid(e) and s and not (s.drawnPos and far(e:GetPos(), e:GetAngles(), s.drawnPos, s.drawnAng, RASTER_MOVE, RASTER_TURN)) then
			kept[#kept + 1] = e
		elseif s then
			if IsValid(e) and s.drawnPos then
				moving = moving or {}
				moving[#moving + 1] = e
			end

			s.still, s.drawnPos, s.drawnAng = false, nil, nil
		end
	end

	if #kept ~= #raster.casters then
		raster.casters, raster.dirty = kept, true
	end

	if not moving then return end

	for _, e in ipairs(moving) do
		for _, onMoved in pairs(cover.rasterListeners) do
			ProtectedCall(onMoved, e)
		end
	end
end

function cover.UpdateRaster(eye)
	local frame = FrameNumber()
	if raster.frame == frame then return end
	raster.frame, raster.used = frame, RealTime()
	if not raster.rt and not buildRaster() then return end

	if raster.loader == nil then raster.loader = coroutine.create(loadRaster) end
	if raster.loader and coroutine.status(raster.loader) ~= "dead" then
		local ok, err = coroutine.resume(raster.loader)
		if not ok then
			ErrorNoHalt("[cover] raster load failed: " .. tostring(err) .. "\n")
			raster.loader = false
		end
	end
	if not raster.world then return end

	local level = cover.SkyLevel()
	local cut = level and level.ceiling or (traceZ or eye.z) + TRACE_HALF
	local x, y = raster.x, raster.y
	if not x or math.abs(eye.x - x) > RASTER_RECENTRE or math.abs(eye.y - y) > RASTER_RECENTRE then
		x, y = math.Round(eye.x / RASTER_SNAP) * RASTER_SNAP, math.Round(eye.y / RASTER_SNAP) * RASTER_SNAP
	end

	if x ~= raster.x or y ~= raster.y or cut ~= raster.cut then
		raster.x, raster.y, raster.cut = x, y, cut
		raster.ready, raster.staticDirty, raster.nextScan = false, true, 0
		requestTiles()
	end

	local now = RealTime()
	if now >= raster.nextScan then
		raster.nextScan = now + RASTER_SCAN_INTERVAL
		scanCasters()
	end

	if raster.staticDirty then
		raster.staticDirty, raster.dirty = false, true
		drawStatic()
	end

	dropMoving()
	if raster.dirty then
		raster.dirty = false
		compose()
		raster.ready = tilesComplete()
	end
end

function cover.RasterConstants(m)
	if not raster.ready then
		m:SetUnpacked(0, 0, 0, 0, 0, 0, RASTER_SIZE, 0, 0, 0, 0, 0, 0, 0, 0, 0)

		return
	end

	m:SetUnpacked(raster.x, raster.y, raster.cut + RASTER_HEIGHT, RASTER_HEIGHT / RASTER_HALF, raster.cut, 1, RASTER_SIZE, 0, 0, 0, 0, 0, 0, 0, 0, 0)

	return raster.rt
end

local function releaseRaster()
	for _, meshes in pairs(raster.tiles) do
		if meshes then destroyMeshes(meshes) end
	end

	raster.tiles, raster.queue = {}, {}
	local loader = raster.loader
	if loader and not raster.idle and coroutine.status(loader) ~= "dead"
		and coroutine.resume(loader) and coroutine.status(loader) ~= "dead" and not raster.idle then return end

	raster.loader, raster.idle = nil, false
	raster.world, raster.props, raster.models, raster.casters, raster.state = nil, nil, {}, {}, {}
	raster.x, raster.y, raster.cut = nil, nil, nil
	raster.ready, raster.staticDirty, raster.dirty = false, false, false
end

hook.Add("Think", "borealis_cover_raster", function()
	if raster.loader ~= nil and RealTime() - raster.used > RASTER_IDLE then releaseRaster() end
end)
hook.Add("OnEntityCreated", "borealis_cover_raster", function() raster.nextScan = 0 end)
hook.Add("EntityRemoved", "borealis_cover_raster", function() raster.nextScan = 0 end)

local exposureRT, exposureMat
local exposureFrame, exposureReady = -1, false
local exposureX, exposureY, exposureZ = 0, 0, 0
local exposureSerial = 0

local function buildExposure()
	exposureRT = GetRenderTargetEx("borealis_cover_exposure_" .. EXPOSURE_SIZE, EXPOSURE_SIZE, EXPOSURE_SIZE, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 12, 0, IMAGE_FORMAT_RGBA16161616F)
	if not shaderpack.UsableRT(exposureRT, EXPOSURE_SIZE, EXPOSURE_SIZE) then
		exposureRT = nil

		return false
	end

	exposureSerial = exposureSerial + 1
	exposureMat = CreateShaderMaterial("borealis_cover_exposure_" .. os.time() .. "_" .. exposureSerial, {
		["$pixshader"] = EXPOSURE_PS,
		["$vertexshader"] = EXPOSURE_VS,
		["$linearread_texture2"] = 1,
		["$alpha_blend"] = 0,
		["$additive"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = EXPOSURE_EXTENT, ["$c0_w"] = EXPOSURE_SIZE,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
	})
	exposureReady = false

	return true
end

function cover.UpdateExposure(eye)
	local frame = FrameNumber()
	if frame == exposureFrame then return end
	exposureFrame = frame
	if not spanTexture or not shaderpack.Available(cover.EXPOSURE_SHADERS) then return end
	if not exposureMat and not buildExposure() then return end
	if exposureReady and frame % EXPOSURE_EVERY ~= 0 then return end

	local texel = EXPOSURE_EXTENT / EXPOSURE_SIZE
	exposureX = math.Round(eye.x / texel) * texel
	exposureY = math.Round(eye.y / texel) * texel
	exposureZ = (math.floor(eye.z / EXPOSURE_STEP) - 1) * EXPOSURE_STEP

	exposureMat:SetTexture("$texture2", spanTexture)
	shaderpack.SetConstant(exposureMat, "$c0", exposureX, exposureY)
	shaderpack.SetConstant(exposureMat, "$c1", exposureZ)

	render.PushRenderTarget(exposureRT)
	render.OverrideAlphaWriteEnable(true, true)
	render.SetMaterial(exposureMat)
	render.DrawScreenQuad()
	render.OverrideAlphaWriteEnable(false)
	render.PopRenderTarget()
	exposureReady = true
end

function cover.Exposure()
	if not exposureReady then return end

	return exposureRT, exposureX, exposureY, 1 / EXPOSURE_EXTENT, exposureZ
end
