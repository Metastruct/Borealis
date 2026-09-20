local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

if SERVER then
	if not resource.AddShader then return end

	resource.AddShader("rain_vs30")
	resource.AddShader("rain_ps30")
	resource.AddShader("rainsplash_ps30")

	return
end

-- Falling rain: static tiles of crossed streak quads built in world space
-- around the eye, so the field stays put while the streaks slide down inside
-- each quad (rain_ps30), and ripples on the ground, one quad per column of
-- level ground the rain reaches (rainsplash_ps30).
--
-- Cover is per column of the world, not per eye: a small wrapped texture
-- around the eye holds, for every COLUMN square, the height the rain stops
-- at (a roof, a bridge, the ground, or the top of the world when the sky is
-- blocked), from two traces per column that include props.  The streak
-- shader discards everything below it, so rain falls outside a doorway and
-- not inside, and stops on roofs.  The window is traced again continuously
-- at a low rate, so a roof built or moved after the trace still counts.  The
-- amount comes from tod/rain.lua.
--
-- Nothing is set between draws: with the threaded material system a draw
-- reads a material constant whenever the render thread gets to it, so a
-- constant set per tile lands on the wrong tiles.  The constants are set once
-- per frame and every mesh carries its own world position.

local RAIN_ENABLED = CreateClientConVar("cl_draw_rain", "1", true, false, "draw falling rain")
local PS, VS = "rain_ps30", "rain_vs30"
local SPLASH_PS = "rainsplash_ps30"

local TILE = 512 -- world units, the tiles' grid
local STREAKS = 450 -- crossed quad pairs per tile
local HALF_H = 560 -- half height of the field, matches the shader
local PERIOD = 80 -- the streak pattern repeats on this height: HALF_H * 2 / the shader's REPEATS
local FIELD_SLACK = 160 -- the tiles are rebuilt once the eye is this far above or below their centre, a jump never does
local HALF_W = 1.2
local WIND = { 0.16, 0.05 } -- lean of the streaks, xy per unit of height
local FADE_START, FADE_END = 560, 760
local ALPHA = 0.24
local COLOR = { 0.62, 0.66, 0.72 } -- mid grey: darker than the sky, lighter than the world
local WRAP = 5 -- seconds, the streak shader's time period

local COLUMN = 24 -- cover map cell, matches the shader
local COLUMNS = 64 -- cover map size in cells, covers the fade distance around the eye
local Z_MIN, Z_RANGE = -16384, 32768 -- the cut height's 16 bit range, matches the shader
local TRACE_SLOT = 80 -- every column is traced again when the eye moves this far in z
local TRACE_HALF = 480 -- the traces look this far above and below the eye
local TRACES_PER_FRAME = 60
local IDLE_TRACES_PER_FRAME = 24 -- the whole window again while nothing is pending, so props built or moved after the trace count
-- MASK_SOLID: without CONTENTS_MONSTER a trace hits brushes only and every prop is missed; players are filtered per batch
local SOLID = MASK_SOLID

local SPLASH_STEP = 2 -- ripples on a coarser grid than the cover map, one quad per block of columns
local SPLASH_QUAD = 3 -- ripple quad size in cells: overlapping, so spots cross block borders
local SPLASH_ALPHA = 0.5
local SPLASH_FADE_START, SPLASH_FADE_END = 420, 720 -- inside the column window
local SPLASH_WRAP = 3600 -- seconds, a multiple of the ripple shader's cycle
local SPLASH_REBUILD = 0.5 -- seconds between ripple mesh rebuilds while columns come in

local function packColor(r, g, b)
	return math.floor(math.Clamp(r, 0, 1) * 255) * 65536 + math.floor(math.Clamp(g, 0, 1) * 255) * 256 + math.floor(math.Clamp(b, 0, 1) * 255)
end

local MAT, SPLASH_MAT, coverRT, splashMesh

--------------------------------------------------------------------------
-- streak tiles: tiles[key] = { ix, iy, z, mesh }, the 3 x 3 around the eye,
-- built in world space at the field's current height
--------------------------------------------------------------------------
local tiles = {}
local fieldZ -- the tiles' centre, a multiple of PERIOD so a rebuilt tile shows the same streaks

local function tileKey(ix, iy)
	return ix * 65536 + iy
end

local function buildTile(ix, iy, fz)
	local rng = bit.band(ix * 73856093 + iy * 19349663, 0x7fffffff)
	local function rand()
		rng = (rng * 1103515245 + 12345) % 2147483648

		return rng / 2147483648
	end

	local tx, ty = ix * TILE, iy * TILE
	local wx, wy = WIND[1] * HALF_H, WIND[2] * HALF_H
	local top, bottom = fz + HALF_H, fz - HALF_H
	local m = Mesh()
	mesh.Begin(m, MATERIAL_QUADS, STREAKS * 2)
	for _ = 1, STREAKS do
		local x, y = tx + rand() * TILE, ty + rand() * TILE
		-- colour: phase, speed step (0 .. 4 of 4), brightness
		local phase, speed, bright = math.floor(rand() * 255), math.floor(rand() * 4 + 0.5) * 63, math.floor(rand() * 255)
		local ang = rand() * math.pi
		for k = 0, 1 do
			local a = ang + k * math.pi * 0.5
			local dx, dy = math.cos(a) * HALF_W, math.sin(a) * HALF_W
			-- v runs 0 at the top to 1 at the bottom, the top leans into the wind
			mesh.Position(Vector(x - dx + wx, y - dy + wy, top)) mesh.TexCoord(0, 0, 0) mesh.Color(phase, speed, bright, 255) mesh.AdvanceVertex()
			mesh.Position(Vector(x + dx + wx, y + dy + wy, top)) mesh.TexCoord(0, 1, 0) mesh.Color(phase, speed, bright, 255) mesh.AdvanceVertex()
			mesh.Position(Vector(x + dx - wx, y + dy - wy, bottom)) mesh.TexCoord(0, 1, 1) mesh.Color(phase, speed, bright, 255) mesh.AdvanceVertex()
			mesh.Position(Vector(x - dx - wx, y - dy - wy, bottom)) mesh.TexCoord(0, 0, 1) mesh.Color(phase, speed, bright, 255) mesh.AdvanceVertex()
		end
	end

	mesh.End()

	return m
end

local function dropTiles()
	for key, t in pairs(tiles) do
		t.mesh:Destroy()
		tiles[key] = nil
	end
end

-- one build per frame, the nearest missing or outdated tile first; a tile at
-- an old height still shows the same streaks until its turn
local function updateTiles(eye)
	if not fieldZ or math.abs(eye.z - fieldZ) > FIELD_SLACK then
		fieldZ = math.floor(eye.z / PERIOD + 0.5) * PERIOD
	end

	local fz = fieldZ
	local ix, iy = math.floor(eye.x / TILE), math.floor(eye.y / TILE)
	for key, t in pairs(tiles) do
		if math.abs(t.ix - ix) > 1 or math.abs(t.iy - iy) > 1 then
			t.mesh:Destroy()
			tiles[key] = nil
		end
	end

	local budget = next(tiles) == nil and 9 or 1
	for _, d in ipairs({ { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
		if budget == 0 then return end
		local tix, tiy = ix + d[1], iy + d[2]
		local key = tileKey(tix, tiy)
		local t = tiles[key]
		if not t or t.z ~= fz then
			if t then
				t.mesh:Destroy()
			end

			tiles[key] = { ix = tix, iy = tiy, z = fz, mesh = buildTile(tix, tiy, fz) }
			budget = budget - 1
		end
	end
end

--------------------------------------------------------------------------
-- cover map: owner[texel] = the column key written there, ground[key] = the
-- level ground's z for the ripples, traced a few per frame from a queue
--------------------------------------------------------------------------
local owner, ground, queue, queued = {}, {}, {}, {}
local traceZ, winX, winY
local idle = false -- the queue holds a refresh, not a window change
local ripplesDirty, nextRipple = false, 0
local upTrace = { mask = SOLID, start = Vector(), endpos = Vector() }
local downTrace = { mask = SOLID, start = Vector(), endpos = Vector() }

-- both axes offset so negative columns pack and unpack cleanly
local KEY_OFFSET = 32768

local function columnKey(cx, cy)
	return (cx + KEY_OFFSET) * 65536 + cy + KEY_OFFSET
end

local function columnFromKey(key)
	local cx = math.floor(key / 65536)

	return cx - KEY_OFFSET, key - cx * 65536 - KEY_OFFSET
end

-- where the rain stops in this column: the top of the world when the sky over
-- it is blocked, else the first surface below, else nowhere
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
	if not down.Hit then
		return Z_MIN, false
	end

	return down.HitPos.z, down.HitNormal.z > 0.9 and down.HitPos.z + 0.4
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
			end

			owner[texel] = key
			if (ground[key] or false) ~= level then
				ground[key] = level or nil
				ripplesDirty = true
			end

			writeTexel(cx, cy, cut)
		end
	end

	render.SetViewPort(0, 0, COLUMNS, COLUMNS)
	render.PopRenderTarget()
end

--------------------------------------------------------------------------
-- ripples: one quad per block of columns whose first column has level
-- ground, larger than the block and centred on it, the column's seed in the
-- vertex colour; the shader never restarts a ripple on a rebuild
--------------------------------------------------------------------------
local function dropSplashes()
	if not splashMesh then return end
	splashMesh:Destroy()
	splashMesh = nil
end

local function buildSplashes()
	local quads, count = {}, 0
	-- blocks aligned to the world, not the window, so they keep their seeds as it moves
	for cy = winY + winY % SPLASH_STEP, winY + COLUMNS - 1, SPLASH_STEP do
		for cx = winX + winX % SPLASH_STEP, winX + COLUMNS - 1, SPLASH_STEP do
			local z = ground[columnKey(cx, cy)]
			if z then
				local seed = (cx * 73856093 + cy * 19349663) % 65536
				count = count + 1
				-- overlapping quads never share a plane: no z-fighting where they cross
				quads[count] = { (cx + SPLASH_STEP * 0.5 - SPLASH_QUAD * 0.5) * COLUMN, (cy + SPLASH_STEP * 0.5 - SPLASH_QUAD * 0.5) * COLUMN, z + seed % 7 * 0.15, seed % 256, math.floor(seed / 256) }
			end
		end
	end

	if count == 0 then return nil end

	local q = COLUMN * SPLASH_QUAD
	local m = Mesh()
	mesh.Begin(m, MATERIAL_QUADS, count)
	for i = 1, count do
		local e = quads[i]
		local x, y, z, r, g = e[1], e[2], e[3], e[4], e[5]
		mesh.Position(Vector(x, y, z)) mesh.TexCoord(0, 0, 0) mesh.Color(r, g, 0, 255) mesh.AdvanceVertex()
		mesh.Position(Vector(x + q, y, z)) mesh.TexCoord(0, 1, 0) mesh.Color(r, g, 0, 255) mesh.AdvanceVertex()
		mesh.Position(Vector(x + q, y + q, z)) mesh.TexCoord(0, 1, 1) mesh.Color(r, g, 0, 255) mesh.AdvanceVertex()
		mesh.Position(Vector(x, y + q, z)) mesh.TexCoord(0, 0, 1) mesh.Color(r, g, 0, 255) mesh.AdvanceVertex()
	end

	mesh.End()

	return m
end

--------------------------------------------------------------------------
-- drawing
--------------------------------------------------------------------------
local function prepare()
	local rain = tod and tod.rain
	if not rain or rain.amount <= 0.001 then
		dropSplashes()
		dropTiles()
		return
	end

	local eye = EyePos()
	updateColumns(eye)
	updateTiles(eye)

	if ripplesDirty and RealTime() >= nextRipple then
		ripplesDirty, nextRipple = false, RealTime() + SPLASH_REBUILD
		dropSplashes()
		splashMesh = buildSplashes()
	end
end

local function draw(bDepth, _, b3DSky)
	if bDepth or b3DSky or render.GetRenderTarget() then return end
	local rain = tod and tod.rain
	if not rain or next(tiles) == nil then return end

	local k = rain.amount
	if k <= 0.001 then return end

	local eye = EyePos()
	local tonemap = render.GetToneMappingScaleLinear().x

	MAT:SetFloat("$c0_x", eye.x)
	MAT:SetFloat("$c0_y", eye.y)
	MAT:SetFloat("$c0_z", eye.z)
	MAT:SetFloat("$c0_w", CurTime() % WRAP)
	MAT:SetFloat("$c1_x", ALPHA * k * tonemap)
	render.SetMaterial(MAT)
	for _, t in pairs(tiles) do
		t.mesh:Draw()
	end

	if splashMesh then
		SPLASH_MAT:SetFloat("$c0_x", eye.x)
		SPLASH_MAT:SetFloat("$c0_y", eye.y)
		SPLASH_MAT:SetFloat("$c0_z", eye.z)
		SPLASH_MAT:SetFloat("$c0_w", CurTime() % SPLASH_WRAP)
		SPLASH_MAT:SetFloat("$c1_x", SPLASH_ALPHA * k * tonemap)
		render.SetMaterial(SPLASH_MAT)
		splashMesh:Draw()
	end
end

local function stop()
	hook.Remove("PreRender", "ms_rain")
	hook.Remove("PostDrawTranslucentRenderables", "ms_rain")
	dropSplashes()
	dropTiles()
end

-- a new material every start: a kept one from an older version of this file
-- would silently drop the constants it was not created with
local materialSerial = 0

local function material(name, pixelShader)
	materialSerial = materialSerial + 1

	return CreateMaterial(name .. "_" .. os.time() .. "_" .. materialSerial, "screenspace_general", {
		["$pixshader"] = pixelShader,
		["$vertexshader"] = VS,
		["$basetexture"] = "",
		["$linearread_basetexture"] = 1, -- the cover map is data
		["$ignorez"] = 0,
		["$depthtest"] = 1,
		["$vertexcolor"] = 1,
		["$vertextransform"] = 1,
		["$additive"] = 0,
		["$alpha_blend"] = 1,
		["$linearwrite"] = 0,
		["$nocull"] = 1,
		["<dx90"] = { ["$no_draw"] = 1 },
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = FADE_START, ["$c1_z"] = FADE_END, ["$c1_w"] = packColor(unpack(COLOR)),
	})
end

local function start()
	stop()
	-- point sampled and wrapped: the shader addresses it by world column
	coverRT = coverRT or GetRenderTargetEx("ms_rain_cover_" .. COLUMNS, COLUMNS, COLUMNS, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, 1, 0, IMAGE_FORMAT_RGBA8888)
	-- untraced columns rain everywhere
	render.PushRenderTarget(coverRT)
	render.Clear(0, 0, 0, 255)
	render.PopRenderTarget()
	owner, ground, queue, queued = {}, {}, {}, {}
	traceZ, winX, winY, fieldZ = nil, nil, nil, nil
	MAT = material("ms_rain", PS)
	MAT:SetTexture("$basetexture", coverRT)
	SPLASH_MAT = material("ms_rainsplash", SPLASH_PS)
	SPLASH_MAT:SetFloat("$c1_y", SPLASH_FADE_START)
	SPLASH_MAT:SetFloat("$c1_z", SPLASH_FADE_END)
	hook.Add("PreRender", "ms_rain", prepare)
	hook.Add("PostDrawTranslucentRenderables", "ms_rain", draw)
end

local function shadersAvailable()
	for _, name in ipairs({ PS, VS, SPLASH_PS }) do
		if not file.Exists("shaders/fxc/" .. name .. ".vcs", "GAME") then return false end
	end

	return true
end

local function apply()
	if not RAIN_ENABLED:GetBool() then
		stop()
		return
	end

	if shadersAvailable() then
		start()
	elseif HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
		hook.Add("ShaderMounted", "ms_rain", function()
			hook.Remove("ShaderMounted", "ms_rain")
			if RAIN_ENABLED:GetBool() and shadersAvailable() then
				start()
			end
		end)
	end
end

cvars.RemoveChangeCallback("cl_draw_rain", "ms_rain")
cvars.AddChangeCallback("cl_draw_rain", apply, "ms_rain")
hook.Remove("ShaderMounted", "ms_rain")
apply()
