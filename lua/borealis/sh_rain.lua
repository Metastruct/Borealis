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
-- The ripples are shaded, not drawn: each one is a height field and the quad
-- shows the wet ground's mirror of the sky bent by its slopes, so they need
-- the horizon's colour and the light's direction every frame.
--
-- Nothing is set between draws: with the threaded material system a draw
-- reads a material constant whenever the render thread gets to it, so a
-- constant set per tile lands on the wrong tiles.  The constants are set once
-- per frame and every mesh carries its own world position.

local RAIN_ENABLED = CreateClientConVar("cl_draw_rain", "1", true, false, "draw falling rain")
local PS, VS = "rain_ps30", "rain_vs30"
local SPLASH_PS = "rainsplash_ps30"

local TILE = 512 -- world units, the tiles' grid
local STREAKS = 1100 -- crossed quad pairs per tile at full rain
local DENSITY_STEPS = 4 -- levels of streak count between nothing and full rain
local HALF_H = 560 -- half height of the field, matches the shader
local PERIOD = 80 -- world units between drop slots, matches the shader
local FIELD_SLACK = 160 -- the tiles are rebuilt once the eye is this far above or below their centre, a jump never does
local HALF_W = 2.6 -- half width of a strip: the drops scatter across it, so a wide one does not read as a line
local CROSS_SPREAD = 24 -- how far the second plane of a cross sits from the first, so a pair is two streaks and not one column
local WIND = { 0.16, 0.05 } -- lean of the streaks, xy per unit of height
local FADE_START, FADE_END = 560, 760
local ALPHA = 0.24
local COLOR_BODY = 0.5 -- a streak's body as a share of the sky behind it: rain reads dark against daylight
local COLOR_HEAD = 1.5 -- and its head, which is what shows against the world instead
local COLOR_HEAD_FLOOR = 0.22 -- the head never goes under this, or night rain has nothing left
local WRAP = 20 -- seconds, the streak shader's time period: every speed in it moves a whole number of slot hash periods over this

local COLUMN = 24 -- cover map cell, matches the shader
local COLUMNS = 64 -- cover map size in cells, covers the fade distance around the eye
local Z_MIN, Z_RANGE = -16384, 32768 -- the cut height's 16 bit range, matches the shader
local TRACE_SLOT = 80 -- every column is traced again when the eye moves this far in z
local TRACE_HALF = 480 -- the traces look this far above and below the eye
local TRACES_PER_FRAME = 60
local IDLE_TRACES_PER_FRAME = 24 -- the whole window again while nothing is pending, so props built or moved after the trace count
-- MASK_SOLID: without CONTENTS_MONSTER a trace hits brushes only and every prop is missed; players are filtered per batch
local SOLID = MASK_SOLID
-- water is not in MASK_SOLID, so a solid trace runs straight through a lake and
-- lands on its bed: the rain stopped under the water and rippled down there
local WATER = MASK_WATER
local IN_WATER = CONTENTS_WATER

local SPLASH_STEP = 2 -- ripples on a coarser grid than the cover map, one quad per block of columns
local SPLASH_QUAD = 3 -- ripple quad size in cells: overlapping, so spots cross block borders
local SPLASH_ALPHA = 0.5
local SPLASH_FADE_START, SPLASH_FADE_END = 420, 720 -- inside the column window
local SPLASH_WRAP = 64 -- seconds, a multiple of every ripple rate's cycle and of the shader's cycle hash period
local SPLASH_SKY = 1.35 -- how much of the horizon's colour the wet ground mirrors
local SPLASH_GREY = 0.45 -- and how far toward its own brightness that colour is pulled: the sky over the horizon is paler than the fog at it
local SPLASH_OVERCAST = 0.85 -- how far a closed sky drains the glints off the ripples
local SPLASH_REBUILD = 0.5 -- seconds between ripple mesh rebuilds while columns come in
local SPLASH_SLOPE = 0.8 -- steepest ground the rain still rings on, as the surface normal's z
local SPLASH_FLAT = 10 -- how far a corner may sit off the plane through the other three before the quad is dropped
local SPLASH_NSCALE = 0.75 -- the normal's xy range in the vertex colour, matches the shader
-- the columns under a quad's first and last corner, from the block it sits on
local SPLASH_C0 = math.floor((SPLASH_STEP - SPLASH_QUAD) * 0.5)
local SPLASH_C1 = SPLASH_C0 + SPLASH_QUAD

local function packColor(r, g, b)
	return math.floor(math.Clamp(r, 0, 1) * 255) * 65536 + math.floor(math.Clamp(g, 0, 1) * 255) * 256 + math.floor(math.Clamp(b, 0, 1) * 255)
end

local MAT, SPLASH_MAT, coverRT, splashMesh
local build -- the cover map and the materials, once the render targets are real

local UP = Vector(0, 0, 1)
local DIM = { 0.12, 0.13, 0.16 } -- no procsky: a dull light, the glints barely show
local skyCol, lightCol = { 0, 0, 0 }, { 0, 0, 0 }
local bodyCol, headCol = { 0, 0, 0 }, { 0, 0, 0 }

-- a fixed grey held its own at dusk and vanished at noon: both streak colours
-- follow the hour's own sky instead, so the contrast survives the whole day
local function streakColor()
	local r, g, b = render.GetFogColor()
	bodyCol[1], bodyCol[2], bodyCol[3] = r / 255 * COLOR_BODY, g / 255 * COLOR_BODY, b / 255 * COLOR_BODY
	headCol[1] = math.max(r / 255 * COLOR_HEAD, COLOR_HEAD_FLOOR)
	headCol[2] = math.max(g / 255 * COLOR_HEAD, COLOR_HEAD_FLOOR)
	headCol[3] = math.max(b / 255 * COLOR_HEAD, COLOR_HEAD_FLOOR)

	return bodyCol, headCol
end

-- what the wet ground mirrors and what glints off it: the horizon's own colour,
-- which tod already matches to the hour, and the sun or moon behind the cloud
local function wetLight()
	local r, g, b = render.GetFogColor()
	local lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
	skyCol[1] = Lerp(SPLASH_GREY, r / 255, lum) * SPLASH_SKY
	skyCol[2] = Lerp(SPLASH_GREY, g / 255, lum) * SPLASH_SKY
	skyCol[3] = Lerp(SPLASH_GREY, b / 255, lum) * SPLASH_SKY
	if not procsky or not procsky.GetCloudLighting then
		return UP, skyCol, DIM
	end

	local dir, light = procsky.GetCloudLighting()
	local k = 1 - SPLASH_OVERCAST * (procsky.GetOvercast and procsky.GetOvercast() or 0)
	lightCol[1], lightCol[2], lightCol[3] = light[1] * k, light[2] * k, light[3] * k

	return dir, skyCol, lightCol
end

--------------------------------------------------------------------------
-- streak tiles: tiles[key] = { ix, iy, z, mesh }, the 3 x 3 around the eye,
-- built in world space at the field's current height
--------------------------------------------------------------------------
local tiles = {}
local fieldZ -- the tiles' centre, snapped to PERIOD; the drops hang off world height, so a rebuild never moves them

local function densityLevel(amount)
	return math.Clamp(math.ceil(amount * DENSITY_STEPS), 1, DENSITY_STEPS)
end

local function tileKey(ix, iy)
	return ix * 65536 + iy
end

local function buildTile(ix, iy, fz, level)
	local count = math.floor(STREAKS * level / DENSITY_STEPS)
	-- the tile's own level rides along in the vertex alpha, so a tile still at
	-- the old one draws at its own weight instead of the whole field jumping
	local weight = math.floor(255 * level / DENSITY_STEPS)
	local rng = bit.band(ix * 73856093 + iy * 19349663, 0x7fffffff)
	local function rand()
		rng = (rng * 1103515245 + 12345) % 2147483648

		return rng / 2147483648
	end

	local tx, ty = ix * TILE, iy * TILE
	local top, bottom = fz + HALF_H, fz - HALF_H
	local m = Mesh()
	mesh.Begin(m, MATERIAL_QUADS, count * 2)
	for _ = 1, count do
		local cx, cy = tx + rand() * TILE, ty + rand() * TILE
		local ox, oy = (rand() - 0.5) * CROSS_SPREAD, (rand() - 0.5) * CROSS_SPREAD
		-- each streak leans its own amount and a little across the wind, so the
		-- field is not one comb of parallel lines
		local lean, swing = 0.65 + rand() * 0.8, (rand() - 0.5) * 0.5
		local wx = (WIND[1] * lean - WIND[2] * swing) * HALF_H
		local wy = (WIND[2] * lean + WIND[1] * swing) * HALF_H
		local ang = rand() * math.pi
		for k = 0, 1 do
			-- colour: phase, speed step (0 .. 4 of 4), brightness, drawn again
			-- for the second plane so the cross does not show the same drops twice
			local phase, speed, bright = math.floor(rand() * 255), math.floor(rand() * 4 + 0.5) * 63, math.floor(rand() * 255)
			local a = ang + k * math.pi * 0.5
			-- the two planes hold a point each instead of crossing on one: a
			-- cross puts every lane of both into the same column of air
			local x, y = cx + ox * k, cy + oy * k
			local dx, dy = math.cos(a) * HALF_W, math.sin(a) * HALF_W
			-- the top leans into the wind; the shader reads u across the strip
			-- and takes the drops' height from the world, not from v
			mesh.Position(Vector(x - dx + wx, y - dy + wy, top)) mesh.TexCoord(0, 0, 0) mesh.Color(phase, speed, bright, weight) mesh.AdvanceVertex()
			mesh.Position(Vector(x + dx + wx, y + dy + wy, top)) mesh.TexCoord(0, 1, 0) mesh.Color(phase, speed, bright, weight) mesh.AdvanceVertex()
			mesh.Position(Vector(x + dx - wx, y + dy - wy, bottom)) mesh.TexCoord(0, 1, 1) mesh.Color(phase, speed, bright, weight) mesh.AdvanceVertex()
			mesh.Position(Vector(x - dx - wx, y - dy - wy, bottom)) mesh.TexCoord(0, 0, 1) mesh.Color(phase, speed, bright, weight) mesh.AdvanceVertex()
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
-- an old height or density still draws until its turn, so a step in the amount
-- costs one tile a frame instead of rebuilding the whole field at once
local function updateTiles(eye, level)
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
		if not t or t.z ~= fz or t.level ~= level then
			if t then
				t.mesh:Destroy()
			end

			tiles[key] = { ix = tix, iy = tiy, z = fz, level = level, mesh = buildTile(tix, tiy, fz, level) }
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
local submerged = false -- the eye is under a surface: there is no rain to see from down there
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
-- ripples: one quad per block of columns, larger than the block and centred
-- on it, the column's seed in the vertex colour; the shader never restarts a
-- ripple on a rebuild.  The quad takes its four corner heights from the
-- columns under those corners, so it lies in the ground instead of cutting
-- through it, and carries that plane's normal for the shader's sheen.
--------------------------------------------------------------------------
local function packNormal(v)
	return math.floor(math.Clamp(v / SPLASH_NSCALE * 0.5 + 0.5, 0, 1) * 255 + 0.5)
end

local function dropSplashes()
	if not splashMesh then return end
	splashMesh:Destroy()
	splashMesh = nil
end

local function buildSplashes()
	local quads, count = {}, 0
	local q = COLUMN * SPLASH_QUAD
	-- blocks aligned to the world, not the window, so they keep their seeds as it moves
	for cy = winY + winY % SPLASH_STEP, winY + COLUMNS - 1, SPLASH_STEP do
		for cx = winX + winX % SPLASH_STEP, winX + COLUMNS - 1, SPLASH_STEP do
			-- the columns under the quad's own corners, which are its corner
			-- heights; one missing means the quad reaches out past an edge
			local z00 = ground[columnKey(cx + SPLASH_C0, cy + SPLASH_C0)]
			local z10 = ground[columnKey(cx + SPLASH_C1, cy + SPLASH_C0)]
			local z11 = ground[columnKey(cx + SPLASH_C1, cy + SPLASH_C1)]
			local z01 = ground[columnKey(cx + SPLASH_C0, cy + SPLASH_C1)]
			-- and a corner off the plane through the other three is a step, a
			-- ridge or a hole: nothing one flat quad can lie on
			if z00 and z10 and z11 and z01 and math.abs(z00 - z10 + z11 - z01) * 0.5 <= SPLASH_FLAT then
				local seed = (cx * 73856093 + cy * 19349663) % 65536
				local dzdx, dzdy = (z10 - z00 + z11 - z01) * 0.5 / q, (z01 - z00 + z11 - z10) * 0.5 / q
				local nz = 1 / math.sqrt(dzdx * dzdx + dzdy * dzdy + 1)
				-- overlapping quads never share a plane: no z-fighting where they cross
				local lift = seed % 7 * 0.15
				count = count + 1
				quads[count] = { (cx + SPLASH_C0 + 0.5) * COLUMN, (cy + SPLASH_C0 + 0.5) * COLUMN,
					z00 + lift, z10 + lift, z11 + lift, z01 + lift,
					seed % 256, math.floor(seed / 256), packNormal(-dzdx * nz), packNormal(-dzdy * nz) }
			end
		end
	end

	if count == 0 then return nil end

	local m = Mesh()
	mesh.Begin(m, MATERIAL_QUADS, count)
	for i = 1, count do
		local e = quads[i]
		local x, y, r, g, nx, ny = e[1], e[2], e[7], e[8], e[9], e[10]
		mesh.Position(Vector(x, y, e[3])) mesh.TexCoord(0, 0, 0) mesh.Color(r, g, nx, ny) mesh.AdvanceVertex()
		mesh.Position(Vector(x + q, y, e[4])) mesh.TexCoord(0, 1, 0) mesh.Color(r, g, nx, ny) mesh.AdvanceVertex()
		mesh.Position(Vector(x + q, y + q, e[5])) mesh.TexCoord(0, 1, 1) mesh.Color(r, g, nx, ny) mesh.AdvanceVertex()
		mesh.Position(Vector(x, y + q, e[6])) mesh.TexCoord(0, 0, 1) mesh.Color(r, g, nx, ny) mesh.AdvanceVertex()
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

	if not MAT and not build() then return end

	local eye = EyePos()
	submerged = bit.band(util.PointContents(eye), IN_WATER) ~= 0
	updateColumns(eye)
	updateTiles(eye, densityLevel(rain.amount))

	if ripplesDirty and RealTime() >= nextRipple then
		ripplesDirty, nextRipple = false, RealTime() + SPLASH_REBUILD
		dropSplashes()
		splashMesh = buildSplashes()
	end
end

local function draw(bDepth, _, b3DSky)
	if bDepth or b3DSky or submerged or render.GetRenderTarget() then return end
	local rain = tod and tod.rain
	if not rain or next(tiles) == nil then return end

	local k = rain.amount
	if k <= 0.001 then return end

	if not MAT then return end

	local eye = EyePos()
	local tonemap = render.GetToneMappingScaleLinear().x

	-- bound again every frame: the targets are recreated across a map change
	MAT:SetTexture("$basetexture", coverRT)
	MAT:SetFloat("$c0_x", eye.x)
	MAT:SetFloat("$c0_y", eye.y)
	MAT:SetFloat("$c0_z", eye.z)
	MAT:SetFloat("$c0_w", CurTime() % WRAP)
	local body, head = streakColor()
	MAT:SetFloat("$c1_w", packColor(body[1], body[2], body[3]))
	MAT:SetFloat("$c2_x", packColor(head[1], head[2], head[3]))
	MAT:SetFloat("$c1_x", ALPHA * k * tonemap)
	render.SetMaterial(MAT)
	for _, t in pairs(tiles) do
		t.mesh:Draw()
	end

	if splashMesh then
		local dir, sky, light = wetLight()
		SPLASH_MAT:SetFloat("$c2_x", dir.x)
		SPLASH_MAT:SetFloat("$c2_y", dir.y)
		SPLASH_MAT:SetFloat("$c2_z", dir.z)
		SPLASH_MAT:SetFloat("$c2_w", packColor(sky[1], sky[2], sky[3]))
		SPLASH_MAT:SetFloat("$c3_x", packColor(light[1], light[2], light[3]))
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
		["$c1_x"] = 0, ["$c1_y"] = FADE_START, ["$c1_z"] = FADE_END, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 1, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})
end

-- The render targets do not exist yet while the map loads, and asking for one
-- then hands back a texture that answers IsError with false and only becomes
-- the cover map later.  A material bound to it samples black for good, so
-- every column reads a cut of Z_MIN and the rain falls through every roof.
-- The ripples come from Lua and keep obeying the traces, which is what the
-- symptom looks like: cover works on the ground and nowhere else.
local function usableRT(t)
	return t ~= nil and not t:IsError() and t:Width() == COLUMNS
end

-- on the first frame the targets are real, never at load
function build()
	-- point sampled and wrapped: the shader addresses it by world column
	coverRT = coverRT or GetRenderTargetEx("ms_rain_cover_" .. COLUMNS, COLUMNS, COLUMNS, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, 1, 0, IMAGE_FORMAT_RGBA8888)
	if not usableRT(coverRT) then
		coverRT = nil

		return false
	end

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

	return true
end

local function start()
	stop()
	MAT, SPLASH_MAT = nil, nil
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
