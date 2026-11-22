local snow = shaderpack.snow
local bspdata = bspdata
local geometry, meshBuilder, cache = snow.geometry, snow.meshBuilder, snow.cache

local CHUNK = snow.CHUNK
local NET, MSG_KEY, MSG_CHUNK = cache.NET, cache.MSG_KEY, cache.MSG_CHUNK
local EMPTY_MS, PLAYERS_TICK_SHARE = 20, 0.5
local MEMORY_MB = 900
local SEND_BYTES, SEND_RATE = 32000, 131072
local MAX_SENDS, REQUEST_COOLDOWN = 4, 600

util.AddNetworkString(NET)

local BAKE_ON_LISTEN = CreateConVar("borealis_snow_bake_listen", "0", FCVAR_ARCHIVE, "server: bake snow chunks on listen servers too, where the bake shares a process with the game")
local key, cacheDir, bakeData, bakeCo, hibernateValue, fatId
local waiting, sends, served, announced = {}, {}, {}, {}
local sendQueue, sendCount = {}, 0
local fatOwner = {}
local downloadUrl = GetConVar("sv_downloadurl")

local function announce(ply)
	announced[ply] = true
	net.Start(NET)
	net.WriteUInt(MSG_KEY, 2)
	net.WriteString(key)
	net.WriteUInt(#bakeData, 32)
	net.Send(ply)
end

local function publishBake(data)
	bakeData = data
	if fatdl and downloadUrl:GetString() ~= "" then
		fatId = fatdl.Write(NET, data, nil, { fatOwner })
	end

	for ply in pairs(waiting) do
		if IsValid(ply) then announce(ply) end
	end

	waiting = {}
end

local function chunkList()
	local seen, list = {}, {}
	local bx0, by0, bx1, by1 = snow.BandChunks()
	for _, cell in pairs(geometry.Triangles()) do
		for _, t in ipairs(cell) do
			if t.vn then
				for cy = math.max(math.floor(t[14] / CHUNK), by0), math.min(math.floor(t[16] / CHUNK), by1) do
					for cx = math.max(math.floor(t[13] / CHUNK), bx0), math.min(math.floor(t[15] / CHUNK), bx1) do
						local k = snow.ChunkKey(cx, cy)
						if not seen[k] then
							seen[k] = true
							list[#list + 1] = { cx = cx, cy = cy }
						end
					end
				end
			end
		end

		snow.Yield()
	end

	return list
end

local function bake()
	file.CreateDir(cacheDir)
	cache.Prune(key)
	cache.PruneBakes(key)

	local vis, why = bspdata.WaitVis()
	if not vis then return nil, why end

	local ok
	ok, why = geometry.Load()
	if not ok then return nil, why end

	local list = chunkList()
	for _, ch in ipairs(list) do
		local path = cache.ChunkPath(cacheDir, ch)
		if file.Size(path, "DATA") <= 0 then
			local verts, tris = meshBuilder.Build(ch)
			file.Write(path, cache.Encode(ch, verts, tris))
		end

		snow.Yield()
	end

	local data = cache.AssembleBake(cacheDir, list)
	file.Write(cache.BakePath(key), data)
	for _, ch in ipairs(list) do
		file.Delete(cache.ChunkPath(cacheDir, ch))
		snow.Yield()
	end

	file.Delete(cacheDir)
	geometry.Clear()
	bspdata.vis = nil

	return data
end

local lastBake = 0

local function think()
	if bakeCo and SysTime() - lastBake >= engine.TickInterval() and collectgarbage("count") / 1024 < MEMORY_MB then
		snow.SetBakeBudget(player.GetCount() == 0 and EMPTY_MS or engine.TickInterval() * 1000 * PLAYERS_TICK_SHARE)
		local ok, data, why = coroutine.resume(bakeCo)
		lastBake = SysTime()
		if not ok or coroutine.status(bakeCo) == "dead" then
			bakeCo = nil
			RunConsoleCommand("sv_hibernate_think", hibernateValue)
			if ok and data then
				publishBake(data)
			else
				ErrorNoHalt("[snow] bake failed: " .. tostring(ok and why or data) .. "\n")
			end
		end
	end

	while sendCount < MAX_SENDS and #sendQueue > 0 do
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
			local data = string.sub(bakeData, send.offset + 1, send.offset + SEND_BYTES)
			net.Start(NET)
			net.WriteUInt(MSG_CHUNK, 2)
			net.WriteUInt(#data, 16)
			net.WriteData(data, #data)
			net.Send(ply)
			send.offset = send.offset + #data
			send.at = now + #data / SEND_RATE
			if send.offset >= #bakeData then
				sends[ply] = nil
				sendCount = sendCount - 1
			end
		end
	end
end

net.Receive(NET, function(_, ply)
	if not bakeData or not announced[ply] or not ply:IsFullyAuthenticated() then return end

	announced[ply] = nil
	local id, now = ply:SteamID64(), RealTime()
	if (served[id] or 0) > now then return end

	for other, expiry in pairs(served) do
		if expiry <= now then served[other] = nil end
	end

	served[id] = now + REQUEST_COOLDOWN
	if fatId then
		fatdl.Send(NET, ply, nil, fatId)
	else
		sendQueue[#sendQueue + 1] = ply
	end
end)

hook.Add("PlayerDisconnected", NET, function(ply)
	announced[ply], waiting[ply] = nil, nil
	for i = #sendQueue, 1, -1 do
		if sendQueue[i] == ply then table.remove(sendQueue, i) end
	end
end)

local function connected(ply)
	if bakeData then
		announce(ply)
	elseif key then
		waiting[ply] = true
	end
end

local function start()
	if shaderpack.Season() ~= "winter" then return end

	key = cache.Key()
	if not key then return end

	cacheDir = cache.DIR .. "/" .. key
	hook.Add("Think", NET, think)
	local data = file.Read(cache.BakePath(key), "DATA")
	if data then
		publishBake(data)
	elseif game.IsDedicated() or BAKE_ON_LISTEN:GetBool() then
		hibernateValue = GetConVar("sv_hibernate_think"):GetString()
		RunConsoleCommand("sv_hibernate_think", "1")
		bakeCo = coroutine.create(bake)
	end
end

shaderpack.OnPlayerReady(NET, connected)

if game.GetWorld():IsWorld() then
	start()
	for _, ply in ipairs(player.GetHumans()) do
		connected(ply)
	end
else
	hook.Add("Initialize", NET, start)
end
