local locallights = shaderpack.locallights or {}
shaderpack.locallights = locallights

local cover = shaderpack.cover

local COLUMN, COLUMNS = cover.COLUMN, cover.COLUMNS
local COVERED = cover.Z_MIN + cover.Z_RANGE
local LIGHT_MAX = 4
local GROUND_LIFT = 12
local TIME_BUDGET = 0.0003
local CHECKS_PER_FRAME = 1024

local columnKey = cover.ColumnKey
local UP = Vector(0, 0, 1)
local samplePos = Vector()
local rt
local texelKey, texelDone = {}, {}
local dirty, dirtyCount = {}, 0
local nextColumn, lastX, lastY = 1, nil, nil
local clearPending = true

local orderX, orderY = {}, {}
do
	local half = COLUMNS / 2
	local cells = {}
	for oy = 0, COLUMNS - 1 do
		for ox = 0, COLUMNS - 1 do
			local dx, dy = ox - half, oy - half
			cells[#cells + 1] = { ox, oy, dx * dx + dy * dy }
		end
	end

	table.sort(cells, function(a, b) return a[3] < b[3] end)
	for i, cell in ipairs(cells) do
		orderX[i], orderY[i] = cell[1], cell[2]
	end
end

local function lightByte(v)
	return math.floor(math.sqrt(math.Clamp(v / LIGHT_MAX, 0, 1)) * 255 + 0.5)
end

local function lightAt(x, y, z)
	if bspdata.BeyondWorld(x, y, z) then x, y, z = bspdata.WorldToSky(x, y, z) end
	samplePos:SetUnpacked(x, y, z)
	local l, d = render.ComputeLighting(samplePos, UP), render.ComputeDynamicLighting(samplePos, UP)

	return lightByte(l.x - d.x), lightByte(l.y - d.y), lightByte(l.z - d.z)
end

local function writeColumn(cx, cy)
	local x, y = (cx + 0.5) * COLUMN, (cy + 0.5) * COLUMN
	local top = cover.HeightAt(x, y)
	if not top then return false end

	local r, g, b = 0, 0, 0
	if top < COVERED then r, g, b = lightAt(x, y, top + GROUND_LIFT) end
	render.SetViewPort(cx % COLUMNS, cy % COLUMNS, 1, 1)
	render.Clear(r, g, b, 0)

	return true
end

local function ensureRT()
	if rt then return rt end

	rt = GetRenderTargetEx("borealis_local_lights_" .. COLUMNS, COLUMNS, COLUMNS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
	if not shaderpack.UsableRT(rt, COLUMNS) then
		rt = nil

		return nil
	end

	return rt
end

local function clearToEye(eye)
	local top = cover.HeightAt(eye.x, eye.y)
	if top and top >= COVERED then top = nil end
	local r, g, b = lightAt(eye.x, eye.y, math.max(eye.z, (top or eye.z) + GROUND_LIFT))
	render.PushRenderTarget(rt)
	render.Clear(r, g, b, 0)
	render.PopRenderTarget()
	clearPending = false
end

local function reset()
	texelKey, texelDone = {}, {}
	dirty, dirtyCount = {}, 0
	nextColumn = 1
	clearPending = true
end

local function onColumn(cx, cy, coverChanged)
	if not coverChanged then return end

	local texel = cx % COLUMNS * COLUMNS + cy % COLUMNS
	if texelKey[texel] == columnKey(cx, cy) and not dirty[texel] then
		dirty[texel] = true
		dirtyCount = dirtyCount + 1
	end
end

function locallights.Update(eye)
	if not ensureRT() then return end

	local winX, winY = cover.Window()
	if not winX then return end

	if clearPending then clearToEye(eye) end
	if winX ~= lastX or winY ~= lastY then
		lastX, lastY = winX, winY
		nextColumn = 1
	end

	if nextColumn > #orderX and dirtyCount == 0 then return end

	local deadline = SysTime() + TIME_BUDGET
	render.PushRenderTarget(rt)
	for texel in pairs(dirty) do
		if SysTime() >= deadline then break end

		local cx, cy = cover.ColumnFromKey(texelKey[texel])
		if writeColumn(cx, cy) then
			texelDone[texel] = true
			dirty[texel] = nil
			dirtyCount = dirtyCount - 1
		end
	end

	for _ = 1, CHECKS_PER_FRAME do
		if nextColumn > #orderX or SysTime() >= deadline then break end

		local cx, cy = winX + orderX[nextColumn], winY + orderY[nextColumn]
		local key = columnKey(cx, cy)
		local texel = cx % COLUMNS * COLUMNS + cy % COLUMNS
		if texelKey[texel] ~= key then
			texelKey[texel], texelDone[texel] = key, nil
			if dirty[texel] then
				dirty[texel] = nil
				dirtyCount = dirtyCount - 1
			end
		end

		if not texelDone[texel] and writeColumn(cx, cy) then
			texelDone[texel] = true
		end

		nextColumn = nextColumn + 1
	end

	render.SetViewPort(0, 0, COLUMNS, COLUMNS)
	render.PopRenderTarget()
end

function locallights.Texture()
	return rt
end

function locallights.Scale()
	local foliage = shaderpack.foliage

	return foliage and foliage.WorldLightScale and foliage.WorldLightScale() or 1
end

cover.Listen("borealis_locallights", onColumn, reset)
