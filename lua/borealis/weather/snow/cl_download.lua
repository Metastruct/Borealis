local snow = shaderpack.snow
local cache = snow.cache
local download = snow.download or {}
snow.download = download

local NET, MSG_KEY, MSG_CHUNK = cache.NET, cache.MSG_KEY, cache.MSG_CHUNK

local bakeFile, bakeIndex
local pendingBake
local onLoaded

function download.OnLoaded(fn)
	onLoaded = fn
end

local function openBake(key, size)
	local f, index, list = cache.OpenBake(key, size)
	if not f then return false end

	if bakeFile then bakeFile:Close() end
	bakeFile, bakeIndex = f, index
	if onLoaded then onLoaded(list) end

	return true
end

local function saveBake(data)
	local key, size = pendingBake.key, pendingBake.size
	pendingBake = nil
	if #data ~= size then return end

	if bakeFile then
		bakeFile:Close()
		bakeFile, bakeIndex = nil, nil
	end

	file.CreateDir(cache.DIR)
	cache.PruneBakes(key)
	file.Write(cache.BakePath(key), data)
	openBake(key, #data)
end

local function receiveFatdl()
	fatdl.Receive(NET, function(data)
		if pendingBake then saveBake(data) end
	end)
end

if fatdl then
	receiveFatdl()
else
	hook.Add("Initialize", NET, function()
		if fatdl then receiveFatdl() end
	end)
end

net.Receive(NET, function()
	local kind = net.ReadUInt(2)
	if kind == MSG_KEY then
		local key, size = net.ReadString(), net.ReadUInt(32)
		if not key:find("^[%w_%-]+$") or size <= 0 or size > cache.MAX_BAKE_BYTES then return end
		if openBake(key, size) or shaderpack.Season() ~= "winter" then return end

		pendingBake = { key = key, size = size, parts = {}, got = 0 }
		net.Start(NET)
		net.SendToServer()
	elseif kind == MSG_CHUNK and pendingBake then
		local data = net.ReadData(net.ReadUInt(16))
		pendingBake.parts[#pendingBake.parts + 1] = data
		pendingBake.got = pendingBake.got + #data
		if pendingBake.got >= pendingBake.size then
			saveBake(table.concat(pendingBake.parts))
		end
	end
end)

function download.Active()
	return bakeIndex ~= nil
end

function download.Read(ch)
	local range = bakeIndex[snow.ChunkKey(ch.cx, ch.cy)]
	if not range then return cache.EMPTY end

	bakeFile:Seek(range[1])

	return bakeFile:Read(range[2])
end
