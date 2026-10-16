local PIXEL_SHADER, DEPTH_SHADER, VERTEX_SHADER = "kelp_ps30", "kelpdepth_ps30", "kelp_vs30"

if SERVER then
	shaderpack.AddResources({ VERTEX_SHADER, PIXEL_SHADER, DEPTH_SHADER })

	return
end

local bspdata, foliage = shaderpack.bspdata, shaderpack.foliage
local KELP_ENABLED =CreateClientConVar("cl_draw_kelp", "0", true, false, "draw kelp forests on sunlit rocky sea beds")

local RADIUS = 3072
local MIN_DEPTH, MAX_DEPTH, DEPTH_FADE = 400, 1300, 120
local WARP_CELL, WARP = 1600, 1200
local PATCH_CELL, DETAIL_CELL = 1400, 450
local PATCH_FROM, PATCH_TO = 0.55, 0.7
local MAX_DENSITY = 0.75
local MIN_LIGHT = 0.15
local MAX_HEIGHT = 1300
local TOP_GAP = 8
local SEGMENT = 50
local STIPE_WIDTH = 2.4
local LEAF_STEP = 22
local TOP_LEAVES = 50
local CURRENT_ANGLE = math.rad(35)
local SWAY, FLUTTER = 45, 3
local BASE_COLOR = { 0.16, 0.11, 0.035 }
local TIP_COLOR = { 0.32, 0.24, 0.07 }
local TRANSLUCENCY = 0.45

local ROCKY = { gravel = true, rock = true, boulder = true }

local packColor, setConstant = shaderpack.PackColor, shaderpack.SetConstant
local valueNoise, smoothstep = foliage.ValueNoise, foliage.Smoothstep
local CURRENT_X, CURRENT_Y = math.cos(CURRENT_ANGLE), math.sin(CURRENT_ANGLE)

local function forestDensity(x, y)
	local wx = valueNoise(x - 4100, y + 2600, WARP_CELL) - 0.5
	local wy = valueNoise(x + 3300, y - 5200, WARP_CELL) - 0.5
	x, y = x + wx * WARP, y + wy * WARP
	local n = valueNoise(x + 9000, y + 9000, PATCH_CELL) * 0.7 + valueNoise(x - 6000, y + 1000, DETAIL_CELL) * 0.3

	return smoothstep(PATCH_FROM, PATCH_TO, n)
end

local basePos = Vector()
local function keep(x, y, z, r)
	basePos:SetUnpacked(x, y, z + 1)
	if bit.band(util.PointContents(basePos), CONTENTS_WATER) == 0 then return false end

	local surface = bspdata.WaterSurfaceAt(x, y, z + 1)
	if not surface then return false end

	local depth = surface - z
	if depth < MIN_DEPTH or depth > MAX_DEPTH then return false end

	local fade = smoothstep(MIN_DEPTH, MIN_DEPTH + DEPTH_FADE, depth) * (1 - smoothstep(MAX_DEPTH - DEPTH_FADE, MAX_DEPTH, depth))

	return r <= forestDensity(x, y) * fade * MAX_DENSITY
end

local rng = 0
local function rand()
	rng = (rng * 1103515245 + 12345) % 2147483648

	return rng / 2147483648
end

local writing, quads = false, 0
local vpos = Vector()
local cr, cg, cb, ca = 0, 0, 0, 0
local function vert(px, py, pz, u, v, kind, h)
	vpos:SetUnpacked(px, py, pz)
	mesh.Position(vpos)
	mesh.TexCoord(0, u + 2 * kind, v + 2 * math.floor(h))
	mesh.Color(cr, cg, cb, ca)
	mesh.AdvanceVertex()
end

local function quad(ax, ay, az, bx, by, bz, wx, wy, wz, kind, ha, hb)
	quads = quads + 1
	if not writing then return end

	vert(ax - wx, ay - wy, az - wz, 0, 0, kind, ha)
	vert(ax + wx, ay + wy, az + wz, 1, 0, kind, ha)
	vert(bx + wx, by + wy, bz + wz, 1, 1, kind, hb)
	vert(bx - wx, by - wy, bz - wz, 0, 1, kind, hb)
end

local function normalize(x, y, z)
	local l = math.sqrt(x * x + y * y + z * z)
	if l < 1e-6 then return 1, 0, 0 end

	return x / l, y / l, z / l
end

local function segment(ax, ay, az, bx, by, bz, ha, hb)
	local tx, ty, tz = normalize(bx - ax, by - ay, bz - az)
	local px, py, pz = normalize(-ty, tx, 0)
	if math.abs(tz) > 0.99 then px, py, pz = -CURRENT_Y, CURRENT_X, 0 end
	local qx, qy, qz = ty * pz - tz * py, tz * px - tx * pz, tx * py - ty * px
	local w = STIPE_WIDTH * 0.5
	quad(ax, ay, az, bx, by, bz, px * w, py * w, pz * w, 0, ha, hb)
	quad(ax, ay, az, bx, by, bz, qx * w, qy * w, qz * w, 0, ha, hb)
end

local function blade(px, py, pz, h, az, el, len, width, roll)
	local variant = 1 + math.floor(rand() * 254)
	local dx, dy, dz = math.cos(az) * math.cos(el), math.sin(az) * math.cos(el), math.sin(el)
	local sx, sy, sz = normalize(-dy, dx, 0)
	local nx, ny, nz = dy * sz - dz * sy, dz * sx - dx * sz, dx * sy - dy * sx
	local c, s = math.cos(roll), math.sin(roll)
	local wx, wy, wz = (sx * c + nx * s) * width, (sy * c + ny * s) * width, (sz * c + nz * s) * width
	quad(px, py, pz, px + dx * len, py + dy * len, pz + dz * len, wx, wy, wz, variant, h, h)
end

local function leaf(px, py, pz, h)
	local az = CURRENT_ANGLE + (rand() - 0.5) * 1.8
	local el = math.rad(5 + rand() * 45)
	local len = 35 + rand() * 25
	local width = (12 + rand() * 8) * 0.5 / 0.7
	local roll = (rand() - 0.5) * 1.6
	blade(px, py, pz, h, az, el, len, width, roll)
end

local function canopyLeaf(px, py, pz, h)
	local az = rand() * math.pi * 2
	local el = math.rad(-6 + rand() * 6)
	local len = 60 + rand() * 40
	local width = (14 + rand() * 8) * 0.5 / 0.7
	local roll = (rand() - 0.5) * 0.5
	blade(px, py, pz, h, az, el, len, width, roll)
end

local function stipe(x, y, z, height)
	local lean = CURRENT_ANGLE + (rand() - 0.5) * 1.6
	local leanAmount = 0.04 + rand() * 0.08
	local lx, ly = math.cos(lean) * leanAmount, math.sin(lean) * leanAmount

	local steps = math.max(2, math.ceil(height / SEGMENT))
	local ax, ay, az, ha = x, y, z, 0
	for k = 1, steps do
		local d = height * k / steps
		local px, py, pz = x + lx * d, y + ly * d, z + d
		segment(ax, ay, az, px, py, pz, ha, d)
		ax, ay, az, ha = px, py, pz, d
	end

	for d = LEAF_STEP * 0.6, height - TOP_LEAVES, LEAF_STEP do
		leaf(x + lx * d, y + ly * d, z + d, d)
	end

	for _ = 1, rand() < 0.5 and 1 or 2 do
		canopyLeaf(x + lx * height, y + ly * height, z + height, height)
	end
end

local function emit(tufts, o, write)
	local x, y, z, seed, light = tufts[o + 1], tufts[o + 2], tufts[o + 3], tufts[o + 4], tufts[o + 6]
	local surface = bspdata.WaterSurfaceAt(x, y, z + 1) or z + MIN_DEPTH
	local top = math.min(surface - z - TOP_GAP, MAX_HEIGHT)
	writing, quads = write, 0
	cr, cg, cb = math.floor(light / 65536), math.floor(light / 256) % 256, light % 256
	ca = math.floor(seed * 255)
	rng = math.floor(seed * 2147483647)
	stipe(x, y, z, top)

	return quads
end

local function palette(mat)
	setConstant(mat, "$c2", nil, packColor(unpack(BASE_COLOR)), packColor(unpack(TIP_COLOR)))
	mat:SetFloat("$c3_x", TRANSLUCENCY)
end

local vertexRows = { { 0, CURRENT_X, CURRENT_Y }, { SWAY, FLUTTER, 0 } }
local function frame()
	vertexRows[1][1] = CurTime() % 3600
	shaderpack.SetVertexConstants(vertexRows)
end

local layer = foliage.Layer({
	name = "kelp",
	pixelShader = PIXEL_SHADER, vertexShader = VERTEX_SHADER, depthShader = DEPTH_SHADER,
	classify = foliage.SurfaceClassifier(ROCKY), minNormalZ = 0.7,
	spacing = 80, jitter = 30, quadW = 0, quadH = MAX_HEIGHT,
	keep = keep, minLight = MIN_LIGHT, timeWrap = 3600,
	emit = emit, meshBatch = 16,
	palette = palette, frame = frame,
})
layer:SetDistance(RADIUS)

shaderpack.AfterWorld("ms_kelp", shaderpack.Toggle("ms_kelp", KELP_ENABLED, { PIXEL_SHADER, VERTEX_SHADER }, function() layer:Start() end, function() layer:Stop() end))
