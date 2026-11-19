local snow = shaderpack.snow
local cache = snow.cache or {}
snow.cache = cache

local bspdata = bspdata
local STRIDE = snow.STRIDE

local DIR = "shaderpack/snowcover"
local VERSION = 5
local COUNT_BYTES, HEADER_BYTES, CLUSTER_BYTES, SAMPLE_BYTES, VERTEX_BYTES = 4, 11, 5, 9, 17
local COORD_SCALE, COORD_OFFSET, NORMAL_SCALE = 32, 8388608, 32767.5
local YIELD_VERTS = 256
local EMPTY = "\0\0\0\0"
local ENTRY_BYTES = 8

cache.DIR, cache.EMPTY = DIR, EMPTY
cache.NET = "borealis_snow_bake"
cache.MSG_KEY, cache.MSG_CHUNK = 0, 1
cache.MAX_BLOB_BYTES = 134217728

function cache.Key()
	local map = "maps/" .. game.GetMap() .. ".bsp"

	return string.lower(string.format("%s_%d_v%d", game.GetMap(), file.Size(map, "GAME") or 0, VERSION))
end

local function stale(name)
	local map = "^" .. string.PatternSafe(game.GetMap():lower())

	return name:find(map .. "_%d+_v%d+s?$") or name:find(map .. "_%d+_%d+_%d+_%d+$")
end

function cache.Prune(key)
	local yieldIfOverBudget = bspdata.FrameBudget()
	local _, dirs = file.Find(DIR .. "/*", "DATA")
	for _, dir in ipairs(dirs or {}) do
		if dir ~= key and stale(dir) then
			local path = DIR .. "/" .. dir
			for _, name in ipairs((file.Find(path .. "/*", "DATA"))) do
				file.Delete(path .. "/" .. name)
				yieldIfOverBudget()
			end

			file.Delete(path)
		end
	end
end

function cache.ChunkPath(dir, ch)
	return dir .. "/" .. ch.cx .. "_" .. ch.cy .. ".dat"
end

local function packCoord(v)
	local n = math.floor(v * COORD_SCALE + 0.5) + COORD_OFFSET

	return n % 256, math.floor(n / 256) % 256, math.floor(n / 65536)
end

local function unpackCoord(a, b, c)
	return (a + b * 256 + c * 65536 - COORD_OFFSET) / COORD_SCALE
end

local function packNormal(v)
	local n = math.floor((v + 1) * NORMAL_SCALE + 0.5)

	return n % 256, math.floor(n / 256)
end

function cache.Encode(ch, verts, tris)
	if tris == 0 then return EMPTY end

	local char = string.char
	local z1, z2, z3 = packCoord(ch.cz)
	local r1, r2, r3 = packCoord(ch.radius)
	local clusterCount, sampleCount = #ch.clusters, #ch.samples / 3
	local parts = {
		char(tris % 256, math.floor(tris / 256) % 256, math.floor(tris / 65536) % 256, math.floor(tris / 16777216)),
		char(z1, z2, z3, r1, r2, r3, clusterCount % 256, math.floor(clusterCount / 256), sampleCount % 256, math.floor(sampleCount / 256) % 256, math.floor(sampleCount / 65536)),
	}
	for i, c in ipairs(ch.clusters) do
		local id, count = c + 2, ch.clusterTris[i]
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
		if i % YIELD_VERTS == 0 then snow.Yield() end
	end

	return util.Compress(table.concat(parts))
end

function cache.Decode(ch, raw)
	if not raw or #raw < COUNT_BYTES then return end
	if raw == EMPTY then return {}, 0 end

	local data = util.Decompress(raw)
	if not data or #data < COUNT_BYTES + HEADER_BYTES then return end

	local byte = string.byte
	local t1, t2, t3, t4, z1, z2, z3, r1, r2, r3, c1, c2, s1, s2, s3 = byte(data, 1, COUNT_BYTES + HEADER_BYTES)
	local tris = t1 + t2 * 256 + t3 * 65536 + t4 * 16777216
	local clusterCount, sampleCount = c1 + c2 * 256, s1 + s2 * 256 + s3 * 65536
	local p = COUNT_BYTES + HEADER_BYTES
	if #data ~= p + clusterCount * CLUSTER_BYTES + sampleCount * SAMPLE_BYTES + tris * 3 * VERTEX_BYTES then return end

	local clusters, clusterTris, grouped = {}, {}, 0
	for i = 1, clusterCount do
		local lo, hi, n1, n2, n3 = byte(data, p + 1, p + CLUSTER_BYTES)
		clusters[i], clusterTris[i] = lo + hi * 256 - 2, n1 + n2 * 256 + n3 * 65536
		grouped = grouped + clusterTris[i]
		p = p + CLUSTER_BYTES
	end

	if grouped ~= tris then return end

	local samples = {}
	for i = 1, sampleCount * 3, 3 do
		local xa, xb, xc, ya, yb, yc, za, zb, zc = byte(data, p + 1, p + SAMPLE_BYTES)
		samples[i], samples[i + 1], samples[i + 2] = unpackCoord(xa, xb, xc), unpackCoord(ya, yb, yc), unpackCoord(za, zb, zc)
		p = p + SAMPLE_BYTES
	end

	local verts = {}
	local o = 0
	for i = 1, tris * 3 do
		local xa, xb, xc, ya, yb, yc, za, zb, zc, n1, n2, n3, n4, l1, l2 = byte(data, p + 1, p + 15)
		local l3, cover = byte(data, p + 16, p + 17)
		verts[o + 1], verts[o + 2], verts[o + 3] = unpackCoord(xa, xb, xc), unpackCoord(ya, yb, yc), unpackCoord(za, zb, zc)
		verts[o + 4], verts[o + 5] = (n1 + n2 * 256) / NORMAL_SCALE - 1, (n3 + n4 * 256) / NORMAL_SCALE - 1
		verts[o + 6], verts[o + 7] = l1 + l2 * 256 + l3 * 65536, cover / 255
		p, o = p + VERTEX_BYTES, o + STRIDE
		if i % YIELD_VERTS == 0 then snow.Yield() end
	end

	ch.cz, ch.radius, ch.clusters, ch.clusterTris, ch.samples = unpackCoord(z1, z2, z3), unpackCoord(r1, r2, r3), clusters, clusterTris, samples

	return verts, tris
end

function cache.BlobPath(key)
	return DIR .. "/" .. key .. ".dat"
end

function cache.PruneBlobs(key)
	for _, name in ipairs((file.Find(DIR .. "/*", "DATA"))) do
		local base = name:match("^(.+)%.dat$")
		if base and base ~= key and stale(base) then
			file.Delete(DIR .. "/" .. name)
		end
	end
end

function cache.AssembleBlob(dir, list)
	local header, body = {}, {}
	local char = string.char
	for _, ch in ipairs(list) do
		local raw = file.Read(cache.ChunkPath(dir, ch), "DATA")
		if raw and raw ~= EMPTY then
			local x, y, len = ch.cx + 32768, ch.cy + 32768, #raw
			header[#header + 1] = char(x % 256, math.floor(x / 256), y % 256, math.floor(y / 256), len % 256, math.floor(len / 256) % 256, math.floor(len / 65536) % 256, math.floor(len / 16777216))
			body[#body + 1] = raw
		end

		snow.Yield()
	end

	local count = #header

	return char(count % 256, math.floor(count / 256) % 256, math.floor(count / 65536) % 256, math.floor(count / 16777216)) .. table.concat(header) .. table.concat(body)
end

function cache.OpenBlob(key, size)
	local path = cache.BlobPath(key)
	if file.Size(path, "DATA") ~= size then return end

	local f = file.Open(path, "rb", "DATA")
	if not f then return end

	local byte = string.byte
	local c1, c2, c3, c4 = byte(f:Read(COUNT_BYTES) or "", 1, 4)
	if not c4 then
		f:Close()

		return
	end

	local count = c1 + c2 * 256 + c3 * 65536 + c4 * 16777216
	if COUNT_BYTES + count * ENTRY_BYTES > size then
		f:Close()

		return
	end

	local header = count > 0 and f:Read(count * ENTRY_BYTES) or ""
	local index, list = {}, {}
	local offset = COUNT_BYTES + count * ENTRY_BYTES
	for i = 0, count - 1 do
		local x1, x2, y1, y2, l1, l2, l3, l4 = byte(header, i * ENTRY_BYTES + 1, i * ENTRY_BYTES + ENTRY_BYTES)
		local len = l1 + l2 * 256 + l3 * 65536 + l4 * 16777216
		local cx, cy = x1 + x2 * 256 - 32768, y1 + y2 * 256 - 32768
		index[snow.ChunkKey(cx, cy)] = { offset, len }
		list[#list + 1] = { cx = cx, cy = cy }
		offset = offset + len
	end

	if offset ~= size then
		f:Close()

		return
	end

	return f, index, list
end
