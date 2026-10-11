local cover = shaderpack.cover or {}
shaderpack.cover = cover

local COLUMN = 24 -- cover map cell, matches the shaders
local COLUMNS = 64 -- cover map size in cells, matches the shaders
local Z_MIN, Z_RANGE = -16384, 32768 -- the cut height's 16 bit range, matches the shaders
local TRACE_SLOT = 80 -- every column is traced again when the eye moves this far in z
local TRACE_HALF = 480 -- the traces look this far above and below the eye
local TRACES_PER_FRAME = 60
local IDLE_TRACES_PER_FRAME = 24 -- the whole window again while nothing is pending, so props built or moved after the trace count
local SPLASH_SLOPE = 0.8 -- steepest ground the rain still rings on, as the surface normal's z
-- MASK_SOLID: without CONTENTS_MONSTER a trace hits brushes only and every prop is missed; players are filtered per batch
local SOLID = MASK_SOLID
-- water is not in MASK_SOLID, so a solid trace runs straight through a lake and
-- lands on its bed: the rain stopped under the water and rippled down there
local WATER = MASK_WATER
local IN_WATER = CONTENTS_WATER

cover.COLUMN, cover.COLUMNS, cover.Z_MIN, cover.Z_RANGE = COLUMN, COLUMNS, Z_MIN, Z_RANGE
cover.listeners = cover.listeners or {}

--------------------------------------------------------------------------
-- cover map: owner[texel] = the column key written there, ground[key] = the
-- level ground's z for the ripples, traced a few per frame from a queue
--------------------------------------------------------------------------
local coverRT
local owner, ground, cuts, queue, queued = {}, {}, {}, {}, {}
local traceZ, winX, winY
local idle = false -- the queue holds a refresh, not a window change
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
		return Z_MIN + Z_RANGE, false
	end

	downTrace.start:SetUnpacked(x, y, top)
	downTrace.endpos:SetUnpacked(x, y, bottom)
	local down = util.TraceLine(downTrace)
	if down.Hit then
		local hit = down.HitPos
		probe:SetUnpacked(hit.x, hit.y, hit.z + 1)
		if bit.band(util.PointContents(probe), IN_WATER) == 0 then
			return hit.z, down.HitNormal.z > SPLASH_SLOPE and hit.z + 0.4
		end
	end

	waterTrace.start:SetUnpacked(x, y, top)
	waterTrace.endpos:SetUnpacked(x, y, bottom)
	local water = util.TraceLine(waterTrace)
	-- the trace began under the surface: this whole column is water, and the
	-- rain landed on it somewhere above
	if water.StartSolid then
		return Z_MIN + Z_RANGE, false
	end

	-- a water surface is always level, so the ripples ride it whatever the bed does
	if water.Hit then
		return water.HitPos.z, water.HitPos.z + 0.4
	end

	return down.Hit and down.HitPos.z or Z_MIN, false
end

-- a clear inside a one texel viewport: the surface library's draws go through
-- the sRGB path and land a few values off, the ripples' seeds do not care
-- but 16 bits of height do
local function writeTexel(cx, cy, cut)
	local v = math.floor(math.Clamp((cut - Z_MIN) / Z_RANGE, 0, 1) * 65535 + 0.5)
	local hi = math.floor(v / 256)
	render.SetViewPort(cx % COLUMNS, cy % COLUMNS, 1, 1)
	render.Clear(hi, v - hi * 256, 0, 255)
end

-- pending columns in a queue popped from its end: the window's outer rings
-- first, the ring around the eye last, so it goes first
local function rebuildQueue()
	local half = COLUMNS / 2
	local rings = {}
	for cy = winY, winY + COLUMNS - 1 do
		for cx = winX, winX + COLUMNS - 1 do
			local key = columnKey(cx, cy)
			if queued[key] then
				local dx, dy = cx - winX - half, cy - winY - half
				local r = math.max(dx < 0 and -dx - 1 or dx, dy < 0 and -dy - 1 or dy)
				rings[r] = rings[r] or {}
				table.insert(rings[r], key)
			end
		end
	end

	queue = {}
	for r = half - 1, 0, -1 do
		for _, key in ipairs(rings[r] or {}) do
			queue[#queue + 1] = key
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

local function updateColumns(eye)
	local half = COLUMNS / 2
	local cx0, cy0 = math.floor(eye.x / COLUMN) - half, math.floor(eye.y / COLUMN) - half
	-- every column again once the eye has moved a slot up or down, a jump
	-- never does; the old heights stay in the map meanwhile
	local retrace = not traceZ or math.abs(eye.z - traceZ) > TRACE_SLOT
	if retrace or cx0 ~= winX or cy0 ~= winY then
		winX, winY = cx0, cy0
		if retrace then
			traceZ = eye.z
		end

		queued = {}
		for cy = cy0, cy0 + COLUMNS - 1 do
			for cx = cx0, cx0 + COLUMNS - 1 do
				local key = columnKey(cx, cy)
				if retrace or owner[cx % COLUMNS * COLUMNS + cy % COLUMNS] ~= key then
					queued[key] = true
				end
			end
		end

		rebuildQueue()
		idle = false
	end

	if #queue == 0 then
		for cy = winY, winY + COLUMNS - 1 do
			for cx = winX, winX + COLUMNS - 1 do
				queued[columnKey(cx, cy)] = true
			end
		end

		rebuildQueue()
		idle = true
	end

	local top, bottom = traceZ + TRACE_HALF, traceZ - TRACE_HALF
	local players = player.GetAll()
	upTrace.filter, downTrace.filter = players, players
	render.PushRenderTarget(coverRT)
	for _ = 1, idle and IDLE_TRACES_PER_FRAME or TRACES_PER_FRAME do
		local key = table.remove(queue)
		if not key then break end
		queued[key] = nil
		local cx, cy = columnFromKey(key)
		-- only columns still in the window are worth tracing
		if cx >= winX and cx < winX + COLUMNS and cy >= winY and cy < winY + COLUMNS then
			local cut, level = traceColumn(cx, cy, top, bottom)
			local texel = cx % COLUMNS * COLUMNS + cy % COLUMNS
			local prev = owner[texel]
			if prev and prev ~= key then
				ground[prev] = nil
				cuts[prev] = nil
			end

			owner[texel] = key
			local cutChanged = cuts[key] ~= cut
			cuts[key] = cut

			local groundChanged = (ground[key] or false) ~= level
			ground[key] = level or nil

			if cutChanged or groundChanged then
				notify(cx, cy, cutChanged, groundChanged)
			end

			writeTexel(cx, cy, cut)
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
	owner, ground, cuts, queue, queued = {}, {}, {}, {}, {}
	traceZ, winX, winY = nil, nil, nil
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
