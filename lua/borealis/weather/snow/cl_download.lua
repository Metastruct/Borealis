local snow = shaderpack.snow
local cache = snow.cache
local download = snow.download or {}
snow.download = download

local NET, MSG_KEY, MSG_CHUNK = cache.NET, cache.MSG_KEY, cache.MSG_CHUNK

local blobFile, blobIndex
local blobPending
local onLoaded

function download.OnLoaded(fn)
	onLoaded = fn
end

local function useBlob(key, size)
	local f, index, list = cache.OpenBlob(key, size)
	if not f then return false end

	if blobFile then blobFile:Close() end
	blobFile, blobIndex = f, index
	if onLoaded then onLoaded(list) end

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

	file.CreateDir(cache.DIR)
	cache.PruneBlobs(key)
	file.Write(cache.BlobPath(key), data)
	useBlob(key, #data)
end

local function receiveFatdl()
	fatdl.Receive(NET, function(data)
		if blobPending then blobReceived(data) end
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
		if not key:find("^[%w_%-]+$") or size <= 0 or size > cache.MAX_BLOB_BYTES then return end
		if useBlob(key, size) or shaderpack.Season() ~= "winter" then return end

		blobPending = { key = key, size = size, parts = {}, got = 0 }
		net.Start(NET)
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

function download.Active()
	return blobIndex ~= nil
end

function download.Read(ch)
	local entry = blobIndex[snow.ChunkKey(ch.cx, ch.cy)]
	if not entry then return cache.EMPTY end

	blobFile:Seek(entry[1])

	return blobFile:Read(entry[2])
end
