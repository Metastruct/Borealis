local VS = "rain_vs30"
local SPLASH_PS = "rainsplash_ps30"
local DROP_PS, DROP_VS = "raindrop_ps30", "raindrop_vs30"
local SNOW_PS, SNOW_VS = "snow_ps30", "snow_vs30"
local SHADERS = { VS, SPLASH_PS, DROP_VS, DROP_PS, SNOW_VS, SNOW_PS }

if SERVER then
	shaderpack.AddResources(SHADERS)

	return
end

-- Falling rain: one quad per drop, placed by raindrop_vs30 from a template
-- mesh shared by every tile, so the drops slide down crossed streak planes
-- that stay put in world space, and ripples on the ground, one quad per column
-- of level ground the rain reaches (rainsplash_ps30).
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
-- per frame, and each tile's position rides in its model matrix.

local procsky, cover = shaderpack.procsky, shaderpack.cover
local ENABLED = CreateClientConVar("cl_draw_precipitations", "1", true, false, "draw falling rain and snow")

local TILE = 512 -- world units, the field is the 3 x 3 of these around the eye
local DROP_TILE = 256
local STREAKS = 1100 -- crossed quad pairs per tile at full rain
local DENSITY_STEPS = 4 -- levels of streak count between nothing and full rain
local DROP_PAIRS = STREAKS * (DROP_TILE / TILE) ^ 2
local DROP_WINDOW = 11
local DROP_CODES = 2 * 3 * DROP_WINDOW
local DROP_CHUNK = 138
local HALF_H = 560 -- half height of the field, matches the shader
local PERIOD = 80 -- world units between drop slots, matches the shader
local FIELD_SLACK = 160 -- the field's height snaps again once the eye is this far above or below it, a jump never does
local HALF_W = 2.6 -- half width of a strip: the drops scatter across it, so a wide one does not read as a line
local CROSS_SPREAD = 24 -- how far the second plane of a cross sits from the first, so a pair is two streaks and not one column
local WIND = { 0.16, 0.05 } -- lean of the streaks, xy per unit of height
local LEAN_MAX, SWING_MAX = 1.45, 0.25
local FADE_START, FADE_END = 560, 760
local Z_FADE_END = 400
local ALPHA = 0.24
local COLOR_BODY = 0.5 -- a streak's body as a share of the sky behind it: rain reads dark against daylight
local COLOR_HEAD = 1.5 -- and its head, which is what shows against the world instead
local COLOR_HEAD_FLOOR = 0.22 -- the head never goes under this, or night rain has nothing left
local WRAP = 20 -- seconds, the streak shader's time period: every speed in it moves a whole number of slot hash periods over this

local COLUMN, COLUMNS, Z_MIN = cover.COLUMN, cover.COLUMNS, cover.Z_MIN
local IN_WATER = CONTENTS_WATER

local SNOW_COUNT = 12
local SNOW_REPS = 8
local SNOW_REBUILDS = 4
local SNOW_WRAP = 64
local SNOW_MARGIN = 130
local SNOW_ALPHA = 0.9
local SNOW_LIGHT = 2.5
local SNOW_FLOOR = 0.12

local SPLASH_STEP = 2 -- ripples on a coarser grid than the cover map, one quad per block of columns
local SPLASH_QUAD = 3 -- ripple quad size in cells: overlapping, so spots cross block borders
local SPLASH_ALPHA = 0.5
local SPLASH_FADE_START, SPLASH_FADE_END = 420, 720 -- inside the column window
local SPLASH_WRAP = 64 -- seconds, a multiple of every ripple rate's cycle and of the shader's cycle hash period
local SPLASH_SKY = 1.35 -- how much of the horizon's colour the wet ground mirrors
local SPLASH_GREY = 0.45 -- and how far toward its own brightness that colour is pulled: the sky over the horizon is paler than the fog at it
local SPLASH_OVERCAST = 0.85 -- how far a closed sky drains the glints off the ripples
local SPLASH_REBUILD = 0.5 -- seconds between ripple mesh rebuilds while columns come in
local SPLASH_FLAT = 10 -- how far a corner may sit off the plane through the other three before the quad is dropped
local SPLASH_NSCALE = 0.75 -- the normal's xy range in the vertex colour, matches the shader
-- the columns under a quad's first and last corner, from the block it sits on
local SPLASH_C0 = math.floor((SPLASH_STEP - SPLASH_QUAD) * 0.5)
local SPLASH_C1 = SPLASH_C0 + SPLASH_QUAD

local packColor, setConstant = shaderpack.PackColor, shaderpack.SetConstant

local SPLASH_MAT, DROP_MAT, SNOW_MAT, splashMesh
local build -- the materials, once the cover map is real
local dropChunks = {}

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
	local k = 1 - SPLASH_OVERCAST * shaderpack.Overcast()
	lightCol[1], lightCol[2], lightCol[3] = light[1] * k, light[2] * k, light[3] * k

	return dir, skyCol, lightCol
end

--------------------------------------------------------------------------
-- streak tiles: a template mesh of drops shared by every tile, the 3 x 3
-- around the eye, drawn at the field's current height
--------------------------------------------------------------------------
local fieldZ -- the field's centre, snapped to PERIOD; the drops hang off world height, so a snap never moves them

local function densityLevel(amount)
	return math.Clamp(math.ceil(amount * DENSITY_STEPS), 1, DENSITY_STEPS)
end

local function updateField(eye)
	if not fieldZ or math.abs(eye.z - fieldZ) > FIELD_SLACK then
		fieldZ = math.floor(eye.z / PERIOD + 0.5) * PERIOD
	end

	return fieldZ
end

local function buildDropChunk(first)
	local last = math.min(first + DROP_CHUNK, DROP_PAIRS) - 1
	local m = Mesh()
	local ok = pcall(function()
		mesh.Begin(m, MATERIAL_QUADS, (last - first + 1) * DROP_CODES)
		for p = first, last do
			for code = 0, DROP_CODES - 1 do
				for corner = 0, 3 do
					mesh.Position(p, code, corner)
					mesh.AdvanceVertex()
				end
			end
		end
		mesh.End()
	end)

	if not ok then
		m:Destroy()
		return
	end

	return { first = first, mesh = m }
end

local function updateDrops()
	local n = #dropChunks
	local first = n * DROP_CHUNK
	if first >= DROP_PAIRS then return end

	dropChunks[n + 1] = buildDropChunk(first)
end

local setVertexConstants = shaderpack.SetVertexConstants

local snowTiles, snowDirty = {}, {}
local ripplesDirty, nextRipple = false, 0
local submerged = false -- the eye is under a surface: there is no rain to see from down there
local columnKey, columnFromKey = cover.ColumnKey, cover.ColumnFromKey

local function markSnowDirty(cx, cy)
	local tx0, tx1 = math.floor(cx * COLUMN / DROP_TILE), math.floor(((cx + 1) * COLUMN - 1) / DROP_TILE)
	local ty0, ty1 = math.floor(cy * COLUMN / DROP_TILE), math.floor(((cy + 1) * COLUMN - 1) / DROP_TILE)
	for tx = tx0, tx1 do
		for ty = ty0, ty1 do
			snowDirty[columnKey(tx, ty)] = true
		end
	end
end

local function snowRand(tx, ty, p, k)
	return (math.sin(tx * 12.9898 + ty * 78.233 + p * 37.719 + k * 4.581) * 43758.5453) % 1
end

local function buildSnowTile(tx, ty)
	local m = Mesh()
	mesh.Begin(m, MATERIAL_QUADS, SNOW_COUNT * SNOW_REPS)
	for p = 0, SNOW_COUNT - 1 do
		local x = (tx + snowRand(tx, ty, p, 0)) * DROP_TILE
		local y = (ty + snowRand(tx, ty, p, 1)) * DROP_TILE
		local cut = cover.CutAt(x, y) or Z_MIN

		for rep = 0, SNOW_REPS - 1 do
			for corner = 0, 3 do
				mesh.Position(x, y, cut)
				mesh.TexCoord(0, p, rep * 4 + corner)
				mesh.AdvanceVertex()
			end
		end
	end

	mesh.End()

	return m
end

local function dropSnowTiles()
	for key, m in pairs(snowTiles) do
		m:Destroy()
		snowTiles[key] = nil
	end

	snowDirty = {}
end

local function updateSnowTiles(eye)
	local reach = FADE_END + SNOW_MARGIN
	local tx0, tx1 = math.floor((eye.x - reach) / DROP_TILE), math.floor((eye.x + reach) / DROP_TILE)
	local ty0, ty1 = math.floor((eye.y - reach) / DROP_TILE), math.floor((eye.y + reach) / DROP_TILE)

	for key, m in pairs(snowTiles) do
		local tx, ty = columnFromKey(key)
		if tx < tx0 - 1 or tx > tx1 + 1 or ty < ty0 - 1 or ty > ty1 + 1 then
			m:Destroy()
			snowTiles[key] = nil
			snowDirty[key] = nil
		end
	end

	local budget = SNOW_REBUILDS
	for tx = tx0, tx1 do
		for ty = ty0, ty1 do
			local key = columnKey(tx, ty)
			if budget > 0 and (not snowTiles[key] or snowDirty[key]) then
				budget = budget - 1
				if snowTiles[key] then
					snowTiles[key]:Destroy()
				end

				snowTiles[key] = buildSnowTile(tx, ty)
				snowDirty[key] = nil
			end
		end
	end
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
	local winX, winY = cover.Window()
	if not winX then return nil end

	local groundAt = cover.Ground
	local quads, count = {}, 0
	local q = COLUMN * SPLASH_QUAD
	-- blocks aligned to the world, not the window, so they keep their seeds as it moves
	for cy = winY + winY % SPLASH_STEP, winY + COLUMNS - 1, SPLASH_STEP do
		for cx = winX + winX % SPLASH_STEP, winX + COLUMNS - 1, SPLASH_STEP do
			-- the columns under the quad's own corners, which are its corner
			-- heights; one missing means the quad reaches out past an edge
			local z00 = groundAt(cx + SPLASH_C0, cy + SPLASH_C0)
			local z10 = groundAt(cx + SPLASH_C1, cy + SPLASH_C0)
			local z11 = groundAt(cx + SPLASH_C1, cy + SPLASH_C1)
			local z01 = groundAt(cx + SPLASH_C0, cy + SPLASH_C1)
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
	local rain, snow = tod and tod.rain, tod and tod.snow
	local raining = rain and rain.amount > 0.001
	local snowing = snow and snow.amount > 0.001
	if not raining then
		dropSplashes()
		ripplesDirty = true
		if not snowing then return end
	end

	local eye = EyePos()
	if not cover.Update(eye) then return end
	if not DROP_MAT then build() end

	submerged = bit.band(util.PointContents(eye), IN_WATER) ~= 0
	if snowing then
		updateSnowTiles(eye)
	end

	if not raining then return end

	updateField(eye)
	updateDrops()

	if ripplesDirty and RealTime() >= nextRipple then
		ripplesDirty, nextRipple = false, RealTime() + SPLASH_REBUILD
		dropSplashes()
		splashMesh = buildSplashes()
	end
end

local dropRows = { {}, {}, {}, {} }
local dropMatrix = Matrix()
local DROP_LEAN_X = (WIND[1] * LEAN_MAX + WIND[2] * SWING_MAX) * HALF_H
local DROP_LEAN_Y = (WIND[2] * LEAN_MAX + WIND[1] * SWING_MAX) * HALF_H
local DROP_SPREAD = CROSS_SPREAD * 0.5 + HALF_W
local planes = { Vector(), Vector(), Vector(), Vector() }
local corner = Vector()

local function setPlanes(fwd, right, up, vs)
	local h = math.rad(vs.fov) * 0.5
	local v = math.atan(math.tan(h) / vs.aspect)
	local sh, ch, sv, cv = math.sin(h), math.cos(h), math.sin(v), math.cos(v)
	planes[1]:Set(fwd * sh + right * ch)
	planes[2]:Set(fwd * sh - right * ch)
	planes[3]:Set(fwd * sv + up * cv)
	planes[4]:Set(fwd * sv - up * cv)
end

local function boxVisible(x0, x1, y0, y1)
	local nx, ny = math.max(x0, 0, -x1), math.max(y0, 0, -y1)
	if nx * nx + ny * ny > FADE_END * FADE_END then return false end

	local z0, z1 = -Z_FADE_END, Z_FADE_END
	for _, n in ipairs(planes) do
		local inside = false
		for i = 0, 7 do
			corner.x = bit.band(i, 1) == 0 and x0 or x1
			corner.y = bit.band(i, 2) == 0 and y0 or y1
			corner.z = bit.band(i, 4) == 0 and z0 or z1
			if corner:Dot(n) >= 0 then
				inside = true
				break
			end
		end

		if not inside then return false end
	end

	return true
end

local function tileVisible(eye, tx, ty, fz)
	local lean = math.max(math.abs(eye.z + Z_FADE_END - fz), math.abs(eye.z - Z_FADE_END - fz)) / HALF_H
	local rx, ry = DROP_LEAN_X * lean + DROP_SPREAD, DROP_LEAN_Y * lean + DROP_SPREAD

	return boxVisible(tx - rx - eye.x, tx + DROP_TILE + rx - eye.x, ty - ry - eye.y, ty + DROP_TILE + ry - eye.y)
end

local function drawDrops(eye, time, level)
	if #dropChunks == 0 or not fieldZ then return end

	local pairsCount = math.floor(DROP_PAIRS * level / DENSITY_STEPS)
	local vs = render.GetViewSetup()
	local ang = EyeAngles()
	local fwd, right, up = ang:Forward(), ang:Right(), ang:Up()
	local pixel = 2 * math.tan(math.rad(vs.fov) * 0.5) / vs.width
	local r = dropRows
	r[1][1], r[1][2], r[1][3] = time, pairsCount, math.floor(255 * level / DENSITY_STEPS) / 255
	r[2][1], r[2][2], r[2][3] = right.x * pixel, right.y * pixel, right.z * pixel
	r[3][1], r[3][2], r[3][3] = up.x * pixel, up.y * pixel, up.z * pixel
	r[4][1], r[4][2], r[4][3] = fwd.x, fwd.y, fwd.z
	setVertexConstants(r)
	setPlanes(fwd, right, up, vs)

	render.SetMaterial(DROP_MAT)
	local fx, fy = (math.floor(eye.x / TILE) - 1) * TILE, (math.floor(eye.y / TILE) - 1) * TILE
	local span = 3 * TILE / DROP_TILE - 1
	for dx = 0, span do
		for dy = 0, span do
			local tx, ty = fx + dx * DROP_TILE, fy + dy * DROP_TILE
			if tileVisible(eye, tx, ty, fieldZ) then
				dropMatrix:SetTranslation(Vector(tx, ty, fieldZ))
				cam.PushModelMatrix(dropMatrix)
				for _, chunk in ipairs(dropChunks) do
					if chunk.first < pairsCount then
						chunk.mesh:Draw()
					end
				end
				cam.PopModelMatrix()
			end
		end
	end
end

local snowRows = { {}, {}, {} }

local function drawSnow(eye, amount)
	local r, g, b = render.GetFogColor()
	SNOW_MAT:SetTexture("$basetexture", cover.Texture())
	setConstant(SNOW_MAT, "$c0", eye.x, eye.y, eye.z)
	setConstant(SNOW_MAT, "$c1", SNOW_ALPHA * render.GetToneMappingScaleLinear().x, nil, nil, packColor(
		math.max(r / 255 * SNOW_LIGHT, SNOW_FLOOR),
		math.max(g / 255 * SNOW_LIGHT, SNOW_FLOOR),
		math.max(b / 255 * SNOW_LIGHT, SNOW_FLOOR)))

	local vs = render.GetViewSetup()
	local ang = EyeAngles()
	local fwd, right, up = ang:Forward(), ang:Right(), ang:Up()
	local rows = snowRows
	rows[1][1], rows[1][2], rows[1][3] = CurTime() % SNOW_WRAP, math.ceil(SNOW_COUNT * amount), 2 * math.tan(math.rad(vs.fov) * 0.5) / vs.width
	rows[2][1], rows[2][2], rows[2][3] = right.x, right.y, right.z
	rows[3][1], rows[3][2], rows[3][3] = up.x, up.y, up.z
	setVertexConstants(rows)
	setPlanes(fwd, right, up, vs)

	render.SetMaterial(SNOW_MAT)
	for key, m in pairs(snowTiles) do
		local tx, ty = columnFromKey(key)
		tx, ty = tx * DROP_TILE, ty * DROP_TILE
		if boxVisible(tx - SNOW_MARGIN - eye.x, tx + DROP_TILE + SNOW_MARGIN - eye.x, ty - SNOW_MARGIN - eye.y, ty + DROP_TILE + SNOW_MARGIN - eye.y) then
			m:Draw()
		end
	end
end

local function draw(bDepth, _, b3DSky)
	if bDepth or b3DSky or submerged or render.GetRenderTarget() then return end
	local snow = tod and tod.snow
	if snow and snow.amount > 0.001 and SNOW_MAT then
		drawSnow(EyePos(), snow.amount)
	end

	local rain = tod and tod.rain
	if not rain then return end

	local k = rain.amount
	if k <= 0.001 then return end

	if not DROP_MAT then return end

	local eye = EyePos()
	local tonemap = render.GetToneMappingScaleLinear().x

	-- bound again every frame: the targets are recreated across a map change
	DROP_MAT:SetTexture("$basetexture", cover.Texture())
	setConstant(DROP_MAT, "$c0", eye.x, eye.y, eye.z, CurTime() % WRAP)
	local body, head = streakColor()
	setConstant(DROP_MAT, "$c1", ALPHA * k * tonemap, nil, nil, packColor(body[1], body[2], body[3]))
	DROP_MAT:SetFloat("$c2_x", packColor(head[1], head[2], head[3]))
	drawDrops(eye, CurTime() % WRAP, densityLevel(k))

	if splashMesh then
		local dir, sky, light = wetLight()
		setConstant(SPLASH_MAT, "$c2", dir.x, dir.y, dir.z, packColor(sky[1], sky[2], sky[3]))
		SPLASH_MAT:SetFloat("$c3_x", packColor(light[1], light[2], light[3]))
		setConstant(SPLASH_MAT, "$c0", eye.x, eye.y, eye.z, CurTime() % SPLASH_WRAP)
		SPLASH_MAT:SetFloat("$c1_x", SPLASH_ALPHA * k * tonemap)
		render.SetMaterial(SPLASH_MAT)
		splashMesh:Draw()
	end
end

local function stop()
	cover.Unlisten("ms_precipitations")
	hook.Remove("PreRender", "ms_precipitations")
	hook.Remove("PostDrawTranslucentRenderables", "ms_precipitations")
	dropSplashes()
	for i = #dropChunks, 1, -1 do
		dropChunks[i].mesh:Destroy()
		dropChunks[i] = nil
	end

	dropSnowTiles()
end

-- a new material every start: a kept one from an older version of this file
-- would silently drop the constants it was not created with
local materialSerial = 0

local function material(name, pixelShader, vertexShader)
	materialSerial = materialSerial + 1

	return CreateShaderMaterial(name .. "_" .. os.time() .. "_" .. materialSerial, {
		["$pixshader"] = pixelShader,
		["$vertexshader"] = vertexShader or VS,
		["$linearread_basetexture"] = 1, -- the cover map is data
		["$ignorez"] = 0,
		["$depthtest"] = 1,
		["$additive"] = 0,
		["$linearwrite"] = 0,
		["$nocull"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = FADE_START, ["$c1_z"] = FADE_END, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 1, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})
end

function build()
	fieldZ = nil
	DROP_MAT = material("ms_raindrop", DROP_PS, DROP_VS)
	DROP_MAT:SetTexture("$basetexture", cover.Texture())
	SPLASH_MAT = material("ms_rainsplash", SPLASH_PS)
	setConstant(SPLASH_MAT, "$c1", nil, SPLASH_FADE_START, SPLASH_FADE_END)
	SNOW_MAT = material("ms_snow", SNOW_PS, SNOW_VS)
	SNOW_MAT:SetTexture("$basetexture", cover.Texture())
end

local function onColumn(cx, cy, cutChanged, groundChanged)
	if cutChanged then
		markSnowDirty(cx, cy)
	end

	if groundChanged then
		ripplesDirty = true
	end
end

local function onReset()
	dropSnowTiles()
	ripplesDirty = true
end

local function start()
	stop()
	SPLASH_MAT, DROP_MAT, SNOW_MAT = nil, nil, nil
	ripplesDirty = true
	cover.Listen("ms_precipitations", onColumn, onReset)
	hook.Add("PreRender", "ms_precipitations", prepare)
	hook.Add("PostDrawTranslucentRenderables", "ms_precipitations", draw)
end

shaderpack.Toggle("ms_precipitations", ENABLED, SHADERS, start, stop)()
