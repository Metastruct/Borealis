local snow = shaderpack.snow
local heightfield = snow.heightfield

local DEPTH = snow.DEPTH
local CELL, MARGIN = heightfield.CELL, heightfield.MARGIN
local SLOPE_WIDTH, DRIFT_MAX = heightfield.SLOPE_WIDTH, heightfield.DRIFT_MAX
local KIND_SNOW, KIND_SHELTERED, KIND_WATER = heightfield.KIND_SNOW, heightfield.KIND_SHELTERED, heightfield.KIND_WATER

local COLORS = {
	[KIND_SHELTERED] = { 200, 40, 40 },
	[KIND_WATER] = { 40, 80, 220 },
}

local overlays = {}
local mode = "depth"

function heightfield.Debug(cx, cy)
	local triangles = snow.geometry.Triangles()
	if not triangles then return end

	return heightfield.Build(triangles, cx, cy)
end

local function spanColor(s)
	if s.kind ~= KIND_SNOW then
		local c = COLORS[s.kind]

		return c[1], c[2], c[3]
	end

	if mode == "fade" then
		local f = math.min(s.fade / SLOPE_WIDTH, 1) * 255

		return 255 - f, f, 0
	elseif mode == "wall" then
		local f = math.min(s.lift / DRIFT_MAX, 1) * 255

		return f, f, 255
	elseif mode == "relax" then
		local f = math.min(math.abs(s.delta) / DEPTH, 1) * 255

		return s.delta < 0 and 255 or 255 - f, s.delta > 0 and 255 or 255 - f, 255 - f
	end

	local f = 80 + 175 * math.min(math.max(s.amount, 0) / (DEPTH + DRIFT_MAX), 1)

	return f, f, f
end

local function buildMesh(field)
	local quads = {}
	local half = CELL * 0.45
	for _, s in ipairs(field.spans) do
		if s.i >= MARGIN and s.i < field.n - MARGIN and s.j >= MARGIN and s.j < field.n - MARGIN then
			quads[#quads + 1] = s
		end
	end

	if #quads == 0 then return end

	local m = Mesh()
	local pos = Vector()
	mesh.Begin(m, MATERIAL_QUADS, #quads)
	for _, s in ipairs(quads) do
		local z = s.floor + 1 + (s.kind == KIND_SNOW and math.max(s.amount, 0) or 0)
		local r, g, b = spanColor(s)
		for _, c in ipairs({ { -half, -half }, { -half, half }, { half, half }, { half, -half } }) do
			pos:SetUnpacked(s.x + c[1], s.y + c[2], z)
			mesh.Position(pos)
			mesh.Color(r, g, b, 200)
			mesh.AdvanceVertex()
		end
	end
	mesh.End()

	return m
end

function heightfield.Show(field)
	local key = field.cx .. ":" .. field.cy
	if overlays[key] and overlays[key].mesh then overlays[key].mesh:Destroy() end
	overlays[key] = { field = field, mesh = buildMesh(field) }
end

function heightfield.SetMode(m)
	mode = m
	for _, o in pairs(overlays) do
		if o.mesh then o.mesh:Destroy() end
		o.mesh = buildMesh(o.field)
	end
end

function heightfield.Clear()
	for _, o in pairs(overlays) do
		if o.mesh then o.mesh:Destroy() end
	end
	overlays = {}
end

hook.Add("PostDrawTranslucentRenderables", "borealis_snow_heightfield", function(depth, _, sky3d)
	if depth or sky3d or next(overlays) == nil then return end

	render.SetColorMaterial()
	for _, o in pairs(overlays) do
		if o.mesh then o.mesh:Draw() end
	end
end)
