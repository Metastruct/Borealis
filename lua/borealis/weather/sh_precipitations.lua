local VS = "borealis_rain_vs30"
local SPLASH_PS = "borealis_rainsplash_ps30"
local DROP_PS, DROP_VS = "borealis_raindrop_ps30", "borealis_raindrop_vs30"
local SNOW_PS, SNOW_VS = "borealis_snow_ps30", "borealis_snow_vs30"
local SHADERS = { VS, SPLASH_PS, DROP_VS, DROP_PS, SNOW_VS, SNOW_PS }

local RAIN_LOOP = "borealis/weather/rain_loop.wav"

if SERVER then
	shaderpack.AddResources(SHADERS)
	resource.AddFile("sound/" .. RAIN_LOOP)

	return
end

local precipitations = shaderpack.precipitations or {}
shaderpack.precipitations = precipitations

local procsky, cover, wind, surfacewater = shaderpack.procsky, shaderpack.cover, shaderpack.wind, shaderpack.surfacewater
local locallights, dynamiclights = shaderpack.locallights, shaderpack.dynamiclights
local ENABLED = CreateClientConVar("borealis_precipitations", "1", true, false, "draw falling rain and snow")
local RAIN_VOLUME = CreateClientConVar("borealis_rain_volume", "0.4", true, false, "rain volume: the rumble, the drips under cover, the thunder and the rain on water, 0 to 1")
local RAIN_MUTE = CreateClientConVar("borealis_rain_mute_losefocus", "1", true, false, "mute the rain while the game is unfocused")

function precipitations.RainVolume()
	if RAIN_MUTE:GetBool() and not system.HasFocus() then return 0 end

	return math.Clamp(RAIN_VOLUME:GetFloat(), 0, 1)
end

local TILE = 512
local DROP_TILE = 256
local STREAKS = 1100
local DENSITY_STEPS = 4
local DROP_PAIRS = STREAKS * (DROP_TILE / TILE) ^ 2
local DROP_WINDOW = 11
local DROP_CODES = 2 * 3 * DROP_WINDOW
local DROP_CHUNK = 138
local HALF_H = 560
local PERIOD = 80
local FIELD_TOLERANCE = 160
local HALF_W = 2.6
local CROSS_SPREAD = 24
local RAIN_LEAN, RAIN_LEAN_WIND = 0.1, 0.2
local LEAN_MAX, SWING_MAX = 1.45, 0.25
local FADE_START, FADE_END = 560, 760
local Z_FADE_END = 400
local ALPHA = 0.24
local COLOR_BODY = 0.5
local COLOR_HEAD = 1.5
local COLOR_HEAD_FLOOR = 0.22
local LIGHT_GAIN = 0.6
local WRAP = 20

local COLUMN, COLUMNS, Z_MIN = cover.COLUMN, cover.COLUMNS, cover.Z_MIN
local IN_WATER = CONTENTS_WATER

local SNOW_COUNT = 12
local SNOW_REPS = 8
local SNOW_REBUILDS = 4
local SNOW_WRAP = 64
local SNOW_MARGIN = 130
local SNOW_DRIFT = 0.25
local SNOW_SLANT_SPAN = 1000
local SNOW_ALPHA = 0.9
local SNOW_ALBEDO = 0.25
local SNOW_LIGHT_GAIN = 0.6
local SNOW_AMBIENT_FILL = 0.5

local SPLASH_STEP = 2
local SPLASH_QUAD = 3
local SPLASH_ALPHA = 0.5
local SPLASH_FADE_START, SPLASH_FADE_END = 420, 720
local SPLASH_WRAP = 64
local SPLASH_SKY = 1.35
local SPLASH_GREY = 0.45
local SPLASH_OVERCAST = 0.85
local SPLASH_REBUILD = 0.5
local SPLASH_FLAT = 10
local SPLASH_NSCALE = 0.75
local SPLASH_C0 = math.floor((SPLASH_STEP - SPLASH_QUAD) * 0.5)
local SPLASH_C1 = SPLASH_C0 + SPLASH_QUAD

local packColor, setConstant, toLinear = shaderpack.PackColor, shaderpack.SetConstant, shaderpack.ToLinear

local SPLASH_MAT, DROP_MAT, SNOW_MAT, splashMesh
local build
local dropChunks = {}

local UP = Vector(0, 0, 1)
local DIM = { 0.12, 0.13, 0.16 }
local skyCol, lightCol = { 0, 0, 0 }, { 0, 0, 0 }
local bodyCol, headCol = { 0, 0, 0 }, { 0, 0, 0 }

local function streakColor()
	local r, g, b = render.GetFogColor()
	bodyCol[1], bodyCol[2], bodyCol[3] = r / 255 * COLOR_BODY, g / 255 * COLOR_BODY, b / 255 * COLOR_BODY
	headCol[1] = math.max(r / 255 * COLOR_HEAD, COLOR_HEAD_FLOOR)
	headCol[2] = math.max(g / 255 * COLOR_HEAD, COLOR_HEAD_FLOOR)
	headCol[3] = math.max(b / 255 * COLOR_HEAD, COLOR_HEAD_FLOOR)

	return bodyCol, headCol
end

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

local fieldZ

local function densityLevel(amount)
	return math.Clamp(math.ceil(amount * DENSITY_STEPS), 1, DENSITY_STEPS)
end

local function updateField(eye)
	if not fieldZ or math.abs(eye.z - fieldZ) > FIELD_TOLERANCE then
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
local submerged = false
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
		local coverZ = cover.HeightAt(x, y) or Z_MIN

		for rep = 0, SNOW_REPS - 1 do
			for corner = 0, 3 do
				mesh.Position(x, y, coverZ)
				mesh.TexCoord(0, p, rep * 4 + corner)
				mesh.AdvanceVertex()
			end
		end
	end

	mesh.End()

	return m
end

local function removeSnowTiles()
	for key, m in pairs(snowTiles) do
		m:Destroy()
		snowTiles[key] = nil
	end

	snowDirty = {}
end

local function snowDrift()
	local drift = SNOW_DRIFT * wind.Strength()

	return -wind.X * drift, -wind.Y * drift, SNOW_MARGIN + drift * SNOW_SLANT_SPAN
end

local function updateSnowTiles(eye)
	local _, _, margin = snowDrift()
	local tileRange = FADE_END + margin
	local tx0, tx1 = math.floor((eye.x - tileRange) / DROP_TILE), math.floor((eye.x + tileRange) / DROP_TILE)
	local ty0, ty1 = math.floor((eye.y - tileRange) / DROP_TILE), math.floor((eye.y + tileRange) / DROP_TILE)

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

local function packNormal(v)
	return math.floor(math.Clamp(v / SPLASH_NSCALE * 0.5 + 0.5, 0, 1) * 255 + 0.5)
end

local function removeSplashes()
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
	for cy = winY + winY % SPLASH_STEP, winY + COLUMNS - 1, SPLASH_STEP do
		for cx = winX + winX % SPLASH_STEP, winX + COLUMNS - 1, SPLASH_STEP do
			local z00 = groundAt(cx + SPLASH_C0, cy + SPLASH_C0)
			local z10 = groundAt(cx + SPLASH_C1, cy + SPLASH_C0)
			local z11 = groundAt(cx + SPLASH_C1, cy + SPLASH_C1)
			local z01 = groundAt(cx + SPLASH_C0, cy + SPLASH_C1)
			if z00 and z10 and z11 and z01 and math.abs(z00 - z10 + z11 - z01) * 0.5 <= SPLASH_FLAT then
				local seed = (cx * 73856093 + cy * 19349663) % 65536
				local dzdx, dzdy = (z10 - z00 + z11 - z01) * 0.5 / q, (z01 - z00 + z11 - z10) * 0.5 / q
				local nz = 1 / math.sqrt(dzdx * dzdx + dzdy * dzdy + 1)
				local zOffset = seed % 7 * 0.15
				count = count + 1
				quads[count] = { (cx + SPLASH_C0 + 0.5) * COLUMN, (cy + SPLASH_C0 + 0.5) * COLUMN,
					z00 + zOffset, z10 + zOffset, z11 + zOffset, z01 + zOffset,
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

local function prepare()
	local rain, snow = tod and tod.rain, tod and tod.snow
	local raining = rain and rain.amount > 0.001
	local snowing = snow and snow.amount > 0.001
	if not raining then
		removeSplashes()
		ripplesDirty = true
		if not snowing then return end
	end

	local eye = EyePos()
	if not cover.Update(eye) then return end
	if not DROP_MAT then build() end

	submerged = bit.band(util.PointContents(eye), IN_WATER) ~= 0
	locallights.Update(eye)
	dynamiclights.Update(eye)
	dynamiclights.UpdateProjected(eye)
	if snowing then
		updateSnowTiles(eye)
	end

	if not raining then return end

	updateField(eye)
	updateDrops()

	if ripplesDirty and RealTime() >= nextRipple then
		ripplesDirty, nextRipple = false, RealTime() + SPLASH_REBUILD
		removeSplashes()
		splashMesh = buildSplashes()
	end
end

local dropRows = { {}, {}, {}, {}, {} }
local dropMatrix = Matrix()
local dropPos = Vector()
local dropLeanX, dropLeanY = 0, 0
local DROP_SPREAD = CROSS_SPREAD * 0.5 + HALF_W
local planes = { Vector(), Vector(), Vector(), Vector() }
local corner = Vector()

local function setPlane(plane, a, ka, b, kb)
	plane:SetUnpacked(a.x * ka + b.x * kb, a.y * ka + b.y * kb, a.z * ka + b.z * kb)
end

local function setPlanes(fwd, right, up, vs)
	local h = math.rad(vs.fov) * 0.5
	local v = math.atan(math.tan(h) / vs.aspect)
	local sh, ch, sv, cv = math.sin(h), math.cos(h), math.sin(v), math.cos(v)
	setPlane(planes[1], fwd, sh, right, ch)
	setPlane(planes[2], fwd, sh, right, -ch)
	setPlane(planes[3], fwd, sv, up, cv)
	setPlane(planes[4], fwd, sv, up, -cv)
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
	local rx, ry = dropLeanX * lean + DROP_SPREAD, dropLeanY * lean + DROP_SPREAD

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
	local lean = RAIN_LEAN + RAIN_LEAN_WIND * wind.Strength()
	local wx, wy = -wind.X * lean, -wind.Y * lean
	r[5][1], r[5][2], r[5][3] = wx, wy, 0
	dropLeanX = (math.abs(wx) * LEAN_MAX + math.abs(wy) * SWING_MAX) * HALF_H
	dropLeanY = (math.abs(wy) * LEAN_MAX + math.abs(wx) * SWING_MAX) * HALF_H
	setVertexConstants(r)
	setPlanes(fwd, right, up, vs)

	render.SetMaterial(DROP_MAT)
	local fx, fy = (math.floor(eye.x / TILE) - 1) * TILE, (math.floor(eye.y / TILE) - 1) * TILE
	local span = 3 * TILE / DROP_TILE - 1
	for dx = 0, span do
		for dy = 0, span do
			local tx, ty = fx + dx * DROP_TILE, fy + dy * DROP_TILE
			if tileVisible(eye, tx, ty, fieldZ) then
				dropPos:SetUnpacked(tx, ty, fieldZ)
				dropMatrix:SetTranslation(dropPos)
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

local snowRows = { {}, {}, {}, {} }

local function drawSnow(eye, amount)
	local tonemap = shaderpack.ToneMapScale()
	local k = SNOW_ALBEDO * tonemap
	local fill = render.GetAmbientLightColor() * (SNOW_AMBIENT_FILL * k)
	local fr, fg, fb = render.GetFogColor()
	local fogStart, fogEnd = render.GetFogDistances()
	local fogMax = render.GetFogMode() == MATERIAL_FOG_NONE and 0 or render.GetFogMaxDensity()
	SNOW_MAT:SetTexture("$basetexture", cover.Texture())
	SNOW_MAT:SetTexture("$texture1", locallights.Texture() or "vgui/black")
	SNOW_MAT:SetTexture("$texture2", dynamiclights.Texture() or "vgui/black")
	SNOW_MAT:SetTexture("$texture3", dynamiclights.ProjectedTexture() or "vgui/black")
	setConstant(SNOW_MAT, "$c0", eye.x, eye.y, eye.z, fogMax)
	setConstant(SNOW_MAT, "$c1", SNOW_ALPHA, locallights.Scale() * k, tonemap * SNOW_LIGHT_GAIN, fogStart)
	setConstant(SNOW_MAT, "$c2", fill.x, fill.y, fill.z, fogEnd)
	setConstant(SNOW_MAT, "$c3", toLinear(fr) * tonemap, toLinear(fg) * tonemap, toLinear(fb) * tonemap)

	local vs = render.GetViewSetup()
	local ang = EyeAngles()
	local fwd, right, up = ang:Forward(), ang:Right(), ang:Up()
	local rows = snowRows
	rows[1][1], rows[1][2], rows[1][3] = CurTime() % SNOW_WRAP, math.ceil(SNOW_COUNT * amount), 2 * math.tan(math.rad(vs.fov) * 0.5) / vs.width
	rows[2][1], rows[2][2], rows[2][3] = right.x, right.y, right.z
	rows[3][1], rows[3][2], rows[3][3] = up.x, up.y, up.z
	local dx, dy, margin = snowDrift()
	rows[4][1], rows[4][2], rows[4][3] = dx, dy, 0
	setVertexConstants(rows)
	setPlanes(fwd, right, up, vs)

	render.SetMaterial(SNOW_MAT)
	for key, m in pairs(snowTiles) do
		local tx, ty = columnFromKey(key)
		tx, ty = tx * DROP_TILE, ty * DROP_TILE
		if boxVisible(tx - margin - eye.x, tx + DROP_TILE + margin - eye.x, ty - margin - eye.y, ty + DROP_TILE + margin - eye.y) then
			m:Draw()
		end
	end
end

local function drawWeather()
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
	local tonemap = shaderpack.ToneMapScale()

	DROP_MAT:SetTexture("$basetexture", cover.Texture())
	DROP_MAT:SetTexture("$texture1", locallights.Texture() or "vgui/black")
	DROP_MAT:SetTexture("$texture2", dynamiclights.Texture() or "vgui/black")
	DROP_MAT:SetTexture("$texture3", dynamiclights.ProjectedTexture() or "vgui/black")
	setConstant(DROP_MAT, "$c0", eye.x, eye.y, eye.z, CurTime() % WRAP)
	local body, head = streakColor()
	setConstant(DROP_MAT, "$c1", ALPHA * k * tonemap, nil, nil, packColor(body[1], body[2], body[3]))
	setConstant(DROP_MAT, "$c2", packColor(head[1], head[2], head[3]), locallights.Scale() * tonemap * LIGHT_GAIN, nil, tonemap * LIGHT_GAIN)
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

local function draw(bDepth, _, b3DSky)
	if bDepth or b3DSky or submerged or render.GetRenderTarget() then return end
	drawWeather()
end

local setRainSounds

local function stop()
	setRainSounds(false)
	cover.Unlisten("borealis_precipitations")
	surfacewater.above.borealis_precipitations = nil
	hook.Remove("PreRender", "borealis_precipitations")
	hook.Remove("PostDrawTranslucentRenderables", "borealis_precipitations")
	removeSplashes()
	for i = #dropChunks, 1, -1 do
		dropChunks[i].mesh:Destroy()
		dropChunks[i] = nil
	end

	removeSnowTiles()
end

local materialSerial = 0

local function material(name, pixelShader, vertexShader)
	materialSerial = materialSerial + 1

	return CreateShaderMaterial(name .. "_" .. os.time() .. "_" .. materialSerial, {
		["$pixshader"] = pixelShader,
		["$vertexshader"] = vertexShader or VS,
		["$linearread_basetexture"] = 1,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
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
	DROP_MAT = material("borealis_raindrop", DROP_PS, DROP_VS)
	DROP_MAT:SetTexture("$basetexture", cover.Texture())
	SPLASH_MAT = material("borealis_rainsplash", SPLASH_PS)
	setConstant(SPLASH_MAT, "$c1", nil, SPLASH_FADE_START, SPLASH_FADE_END)
	SNOW_MAT = material("borealis_snow", SNOW_PS, SNOW_VS)
	SNOW_MAT:SetTexture("$basetexture", cover.Texture())
end

local function onColumn(cx, cy, coverChanged, groundChanged)
	if coverChanged then
		markSnowDirty(cx, cy)
	end

	if groundChanged then
		ripplesDirty = true
	end
end

local function onReset()
	removeSnowTiles()
	ripplesDirty = true
end

local function start()
	stop()
	SPLASH_MAT, DROP_MAT, SNOW_MAT = nil, nil, nil
	ripplesDirty = true
	cover.Listen("borealis_precipitations", onColumn, onReset)
	surfacewater.above.borealis_precipitations = drawWeather
	hook.Add("PreRender", "borealis_precipitations", prepare)
	hook.Add("PostDrawTranslucentRenderables", "borealis_precipitations", draw)
	setRainSounds(true)
end

do
	local RUMBLE = file.Exists("sound/" .. RAIN_LOOP, "GAME") and RAIN_LOOP or "ambient/weather/rumble_rain.wav"
	local COVER_VOLUME = 0.3
	local SKY_RANGE = 8192
	local OPEN_SEARCH, OPEN_NEAR = 1400, 300
	local OPEN_STEPS = { 0.45, 0.95 }
	local OPEN_RAYS, OPEN_SPIN, OPEN_HISTORY = 8, math.rad(17), 12
	local COVER_INTERVAL = 0.25
	local DRIP_INTERVAL = { 0.6, 1.8 }
	local THUNDER_AMOUNT = 0.8
	local THUNDER_INTERVAL = { 25, 70 }
	local THUNDER_DELAY = { 0.8, 3 }

	local coverTrace = { mask = bit.bor(CONTENTS_SOLID, CONTENTS_MOVEABLE, CONTENTS_WINDOW, CONTENTS_GRATE) }
	local rainSounds = false
	local raining = false
	local rumbleOwner
	local covered = false
	local exposure = 0
	local nextCover, nextDrip, nextThunder = 0, 0, 0
	local openPhase = 0
	local openHistory, openAt = {}, 1
	for i = 1, OPEN_HISTORY do
		openHistory[i] = 0
	end

	if precipitations.rumble then
		precipitations.rumble:Stop()
		precipitations.rumble = nil
	end

	local function rainExposure()
		local eye = EyePos()
		coverTrace.start = eye
		coverTrace.endpos = eye + UP * SKY_RANGE

		local up = util.TraceLine(coverTrace)
		if not up.Hit or up.HitSky then return 1, true end

		local nearestOpen = OPEN_SEARCH
		openPhase = openPhase + OPEN_SPIN
		for i = 0, OPEN_RAYS - 1 do
			local a = openPhase + i * math.pi * 2 / OPEN_RAYS
			local dir = Vector(math.cos(a), math.sin(a), 0)
			coverTrace.start = eye
			coverTrace.endpos = eye + dir * OPEN_SEARCH
			local out = util.TraceLine(coverTrace)
			local clear = out.Fraction * OPEN_SEARCH - 8
			for _, k in ipairs(OPEN_STEPS) do
				local d = clear * k
				if d <= 0 or d >= nearestOpen then break end

				coverTrace.start = eye + dir * d
				coverTrace.endpos = coverTrace.start + UP * SKY_RANGE
				local u = util.TraceLine(coverTrace)
				if not u.Hit or u.HitSky then
					nearestOpen = d
					break
				end
			end
		end

		return 1 - math.Clamp((nearestOpen - OPEN_NEAR) / (OPEN_SEARCH - OPEN_NEAR), 0, 1), false
	end

	local function stopRumble(fade)
		local s = precipitations.rumble
		if not s then return end

		if fade then
			s:FadeOut(fade)
		else
			s:Stop()
		end

		precipitations.rumble = nil
	end

	local function updateRumble(ply, volume)
		local s = precipitations.rumble
		if s and (rumbleOwner ~= ply or not s:IsPlaying()) then
			s:Stop()
			s, precipitations.rumble = nil, nil
		end

		if not s then
			rumbleOwner = ply
			s = CreateSound(ply, RUMBLE)
			precipitations.rumble = s
			s:PlayEx(0, 100)
		end

		s:ChangeVolume(volume, 0.5)
	end

	local function thunder(ply)
		local v = precipitations.RainVolume()
		local rain = tod and tod.rain
		if v > 0 and rain and rain.amount > 0 and IsValid(ply) then
			ply:EmitSound("ambient/weather/thunder" .. math.random(6) .. ".wav", 0, math.random(90, 110), 0.7 * v * exposure, CHAN_STATIC)
		end
	end

	hook.Add("Think", "borealis_rain_sounds", function()
		local rain = tod and tod.rain
		local a = rain and rain.amount or 0
		local now = RealTime()
		if a <= 0 then
			raining = false
			stopRumble(2)
			return
		end

		if not raining then
			raining = true
			nextThunder = now + math.Rand(THUNDER_INTERVAL[1], THUNDER_INTERVAL[2])
		end

		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		if ply.IsDreaming and ply:IsDreaming() then
			stopRumble()
			return
		end

		if now >= nextCover then
			nextCover = now + COVER_INTERVAL
			local target, sky = rainExposure()
			covered = not sky
			rain.covered = covered
			openHistory[openAt] = target
			openAt = openAt % OPEN_HISTORY + 1
			exposure = 0
			for i = 1, OPEN_HISTORY do
				exposure = math.max(exposure, openHistory[i])
			end
		end

		local vol = precipitations.RainVolume()
		if vol <= 0 then
			stopRumble()
			return
		end

		if exposure <= 0 then
			stopRumble(1.5)
			return
		end

		if rainSounds then
			updateRumble(ply, a * vol * (covered and COVER_VOLUME or 1) * exposure)
			if covered and now >= nextDrip then
				nextDrip = now + math.Rand(DRIP_INTERVAL[1], DRIP_INTERVAL[2]) / a
				sound.Play("ambient/weather/rain_drip" .. math.random(5) .. ".wav", ply:GetPos() + VectorRand() * 200, 65, math.random(90, 110), 0.6 * vol)
			end
		end

		if a >= THUNDER_AMOUNT and now >= nextThunder then
			nextThunder = now + math.Rand(THUNDER_INTERVAL[1], THUNDER_INTERVAL[2])
			if rain.Flash then rain.Flash() end
			timer.Simple(math.Rand(THUNDER_DELAY[1], THUNDER_DELAY[2]), function() thunder(ply) end)
		end
	end)

	function setRainSounds(on)
		rainSounds = on
		if not on then stopRumble() end
	end
end

shaderpack.Toggle("borealis_precipitations", ENABLED, SHADERS, start, stop)()
