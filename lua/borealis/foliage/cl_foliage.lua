local foliage = shaderpack.foliage or {}
shaderpack.foliage = foliage
local bspdata, depthslices, chunks = shaderpack.bspdata, shaderpack.depthslices, shaderpack.chunks
foliage.layers = foliage.layers or {}

local CHUNK = 512
local MESH_BATCH = 240
local STRIDE = 7
local MESH_CACHE_TUFTS = jit.arch == "x64" and math.huge or 200000
local FILL_K = 0.5

local Layer = {}
Layer.__index = Layer

local packColor, setConstant = shaderpack.PackColor, shaderpack.SetConstant

local function lattice(ix, iy)
	local h = (ix * 73856093 + iy * 19349663) % 2147483648
	h = (h * 1103515245 + 12345) % 2147483648
	h = (h * 1103515245 + 12345) % 2147483648

	return h / 2147483648
end

function foliage.ValueNoise(x, y, cell)
	local fx, fy = x / cell, y / cell
	local ix, iy = math.floor(fx), math.floor(fy)
	local tx, ty = fx - ix, fy - iy
	tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
	local a, b = lattice(ix, iy), lattice(ix + 1, iy)
	local c, d = lattice(ix, iy + 1), lattice(ix + 1, iy + 1)
	local top = a + (b - a) * tx

	return top + (c + (d - c) * tx - top) * ty
end

function foliage.Smoothstep(e0, e1, v)
	local t = math.Clamp((v - e0) / (e1 - e0), 0, 1)

	return t * t * (3 - 2 * t)
end

function foliage.SurfaceClassifier(kinds, names)
	local function named(texture)
		if not texture then return false end
		texture = texture:lower()
		for _, n in ipairs(names) do
			if texture:find(n, 1, true) then return true end
		end

		return false
	end

	return function(name)
		local mat = Material(name)
		local sp = (mat:GetString("$surfaceprop") or ""):lower()
		local sp2 = (mat:GetString("$surfaceprop2") or ""):lower()
		if kinds[sp] and (sp2 == "" or kinds[sp2]) then
			return 1
		elseif kinds[sp] then
			return 2
		elseif kinds[sp2] then
			return 3
		end

		if not names then return end

		local base2 = mat:GetString("$basetexture2")
		local first = named(mat:GetString("$basetexture")) or (not base2 and named((name:lower():gsub("^maps/[^/]+/", ""))))
		local second = named(base2)
		if first and (not base2 or second) then
			return 1
		elseif first then
			return 2
		elseif second then
			return 3
		end
	end
end

local lightEnvironment
local function hasLightEnvironment()
	if lightEnvironment == nil then
		local f, lump = bspdata.OpenLumps()
		lightEnvironment = f and lump(0):find("\"light_environment\"", 1, true) ~= nil or false
		if f then f:Close() end
	end

	return lightEnvironment
end

local function worldLightScale()
	if not (tod and tod.MultToLightEnv and tod.CurrentParams) or not hasLightEnvironment() then return 1 end
	local code = tod.MultToLightEnv(tod.CurrentParams.world_light_multiplier or 1)
	if not isnumber(code) then return 1 end

	return (code - 97) * 22 / 256
end

foliage.WorldLightScale = worldLightScale

local UP = Vector(0, 0, 1)
local traceStart, traceEnd, lightPos = Vector(0, 0, 0), Vector(0, 0, 0), Vector(0, 0, 0)
local coverTraceRes = {}
local coverTrace = { mask = MASK_SOLID_BRUSHONLY, start = traceStart, endpos = traceEnd, output = coverTraceRes }

function Layer:raster(ch, cand)
	local cfg = self.cfg
	local spacing, jitter, keep, minLight = cfg.spacing, cfg.jitter, cfg.keep, cfg.minLight
	local coverHeight = cfg.quadH + 2
	local sample, clusterAt = bspdata.Sample, bspdata.ClusterAt
	local x0, y0 = ch.cx * CHUNK, ch.cy * CHUNK
	local x1, y1 = x0 + CHUNK, y0 + CHUNK
	local tufts, n = {}, 0
	local rng = ch.cx * 73856093 + ch.cy * 19349663
	local function rand()
		rng = (rng * 1103515245 + 12345) % 2147483648

		return rng / 2147483648
	end

	local lightCache = {}
	local function coverLight(x, y, z)
		traceStart:SetUnpacked(x, y, z + coverHeight)
		traceEnd:SetUnpacked(x, y, z + 1)
		util.TraceLine(coverTrace)
		if coverTraceRes.Hit then return nil end

		local lkey = (math.floor(x / (spacing * 2)) * 4096 + math.floor(y / (spacing * 2))) * 1024 + math.floor(z / 64)
		local light = lightCache[lkey]
		if not light then
			lightPos:SetUnpacked(x, y, z + 12)
			local l = render.ComputeLighting(lightPos, UP)
			light = math.Clamp(math.floor(l.x * 127.5), 0, 255) * 65536 + math.Clamp(math.floor(l.y * 127.5), 0, 255) * 256 + math.Clamp(math.floor(l.z * 127.5), 0, 255)
			lightCache[lkey] = light
		end

		if minLight and math.max(math.floor(light / 65536), math.floor(light / 256) % 256, light % 256) < minLight * 127.5 then return nil end

		return light
	end

	for gy = y0, y1 - 1, spacing do
		chunks.YieldIfOverBudget()

		for gx = x0, x1 - 1, spacing do
			local x = gx + spacing * 0.5 + (rand() - 0.5) * 2 * jitter
			local y = gy + spacing * 0.5 + (rand() - 0.5) * 2 * jitter
			local seed, r3, r4, r5 = rand(), rand(), rand(), rand()
			for _, t in ipairs(cand) do
				if x >= t[13] and x <= t[15] and y >= t[14] and y <= t[16] then
					local z, alpha = sample(t, x, y)
					local kept = z and r3 * 255 > alpha and keep(x, y, z, r5)
					if kept then
						local light = coverLight(x, y, z)
						if light then
							local cluster = clusterAt(x, y, z + 8)
							if cluster < 0 then cluster = clusterAt(x, y, z + 24) end

							tufts[n + 1], tufts[n + 2], tufts[n + 3], tufts[n + 4], tufts[n + 5], tufts[n + 6], tufts[n + 7] = x, y, z, seed, 0.5 + r4 * r4 * 0.9 * (kept == true and 1 or kept), light, cluster
							n = n + STRIDE
						end
					end
				end
			end
		end
	end

	local count = n / STRIDE
	local order = {}
	for i = 1, count do
		order[i] = i
	end

	table.sort(order, function(a, b)
		return tufts[(a - 1) * STRIDE + 7] < tufts[(b - 1) * STRIDE + 7]
	end)

	local sorted = {}
	for i = 1, count do
		local src, dst = (order[i] - 1) * STRIDE, (i - 1) * STRIDE
		for k = 1, STRIDE do
			sorted[dst + k] = tufts[src + k]
		end
	end

	return sorted
end

local COS60, SIN60 = math.cos(math.rad(60)), math.sin(math.rad(60))
local DIRS = { { 1, 0 }, { COS60, SIN60 }, { -COS60, SIN60 } }
local vpos = Vector(0, 0, 0)
local vr, vg, vb, va = 0, 0, 0, 0
local function vert(px, py, pz, u, v)
	vpos:SetUnpacked(px, py, pz)
	mesh.Position(vpos)
	mesh.TexCoord(0, u, v)
	mesh.Color(vr, vg, vb, va)
	mesh.AdvanceVertex()
end

local function emitTuft(quadW, quadH, height, x, y, z, seed, hs, light)
	vr = math.floor(light / 65536)
	vg = math.floor(light / 256) % 256
	vb = light % 256
	va = math.floor(seed * 255)
	local hIndex = math.Clamp(math.floor((hs - 0.5) / 0.9 * 7 + 0.5), 0, 7)
	hs = 0.5 + hIndex / 7 * 0.9
	local h = quadH * hs * height
	local w = quadW * (0.7 + 0.3 * hs) * 0.5
	local rot = seed * math.pi
	local cr, sr = math.cos(rot), math.sin(rot)
	local u0 = hIndex * 2
	for _, d in ipairs(DIRS) do
		local dx = (d[1] * cr - d[2] * sr) * w
		local dy = (d[1] * sr + d[2] * cr) * w
		local lx, ly, rx, ry = x - dx, y - dy, x + dx, y + dy
		vert(lx, ly, z, u0, 1)
		vert(lx, ly, z + h, u0, 0)
		vert(rx, ry, z + h, u0 + 1, 0)
		vert(rx, ry, z, u0 + 1, 1)
	end
end

function Layer:buildMesh(tufts, first, last)
	local quadW, quadH, height, emit = self.cfg.quadW, self.cfg.quadH, self.height, self.cfg.emit
	local quads = 0
	if emit then
		for i = first, last do
			quads = quads + emit(tufts, (i - 1) * STRIDE, false)
		end
	else
		quads = (last - first + 1) * #DIRS
	end

	local m = Mesh()
	local groups, g = {}, nil
	mesh.Begin(m, MATERIAL_QUADS, quads)
	for i = first, last do
		local o = (i - 1) * STRIDE
		local x, y, z, seed, hs, light, cluster = tufts[o + 1], tufts[o + 2], tufts[o + 3] + 0.5, tufts[o + 4], tufts[o + 5], tufts[o + 6], tufts[o + 7]
		if not g or cluster ~= g.cluster then
			g = { cluster = cluster, n = 0, x = 0, y = 0, z = 0, ax = x, ay = y, az = z }
			groups[#groups + 1] = g
		end

		g.n, g.x, g.y, g.z = g.n + 1, g.x + x, g.y + y, g.z + z
		g.bx, g.by, g.bz = x, y, z
		if emit then
			emit(tufts, o, true)
		else
			emitTuft(quadW, quadH, height, x, y, z, seed, hs, light)
		end
	end

	mesh.End()

	local midHeight = quadH * height * 0.5
	for _, gr in ipairs(groups) do
		gr.x, gr.y, gr.z = gr.x / gr.n, gr.y / gr.n, gr.z / gr.n + midHeight
		gr.az, gr.bz = gr.az + midHeight, gr.bz + midHeight
	end

	return { m = m, groups = groups }
end

local function destroyMeshes(ch)
	if not ch.meshes then return end
	for _, b in ipairs(ch.meshes) do
		b.m:Destroy()
	end

	ch.meshes = nil
end

function Layer:chunkBounds(ch, tufts)
	local zmin, zmax = math.huge, -math.huge
	for o = 3, #tufts, STRIDE do
		local z = tufts[o]
		if z < zmin then zmin = z end
		if z > zmax then zmax = z end
	end

	local half = CHUNK * 0.5
	local hz = (zmax - zmin) * 0.5 + self.cfg.quadH
	ch.cz = zmin + hz
	ch.radius = math.sqrt(half * half * 2 + hz * hz)
end

function Layer:buildChunk(ch)
	local key = chunks.Key(ch.cx, ch.cy)
	local tufts = self.tuftCache[key]
	if tufts == false then return 0 end

	if not tufts then
		local x0, y0 = ch.cx * CHUNK, ch.cy * CHUNK
		local cand = bspdata.Candidates(self.triGrid, x0, y0, x0 + CHUNK, y0 + CHUNK)
		tufts = #cand > 0 and self:raster(ch, cand) or {}
		if #tufts == 0 then
			self.tuftCache[key] = false

			return 0
		end

		self.tuftCache[key] = tufts
	end

	self:chunkBounds(ch, tufts)

	local total = #tufts / STRIDE
	local batch = self.cfg.meshBatch or MESH_BATCH
	ch.meshes = {}
	for first = 1, total, batch do
		chunks.YieldIfOverBudget()
		ch.meshes[#ch.meshes + 1] = self:buildMesh(tufts, first, math.min(first + batch - 1, total))
	end

	return total
end

function Layer:load()
	local vis, why = bspdata.WaitVis()
	if not vis then return false, why end

	local grid
	grid, why = bspdata.Triangles(self.cfg.classify, self.cfg.minNormalZ)
	if not grid then return false, why end

	self.triGrid = bspdata.RemoveSkybox(grid)

	return true
end

function Layer:draw(sky3d)
	local grid = self.grid
	if grid.paused or not grid.ready or sky3d or render.GetRenderTarget() then return end
	local MAT, DEPTH_MAT = self.mat, self.depthMat
	local v = chunks.View()
	local eye, fwd, amb = v.eye, v.fwd, v.amb
	local time = CurTime() * (self.cfg.timeScale or 1) % (self.cfg.timeWrap or 1000)

	if math.abs(MAT:GetFloat("$c1_w") - self.fadeStart) > 1 then
		self.cfg.palette(MAT, DEPTH_MAT)
		self:SetDistance(self.radius)
	end

	setConstant(MAT, "$c0", eye.x, eye.y, eye.z, time)
	MAT:SetFloat("$c1_y", packColor(amb.x * FILL_K, amb.y * FILL_K, amb.z * FILL_K))
	MAT:SetFloat("$c2_x", worldLightScale())
	if self.cfg.frame then self.cfg.frame(MAT, DEPTH_MAT, time) end
	MAT:SetFloat("$c2_w", v.tonemap)
	render.SetMaterial(MAT)

	local visible = grid:Visible(v)

	local sight = self.sight
	sight:Begin(eye)
	local drawn = self.drawn
	local shown = 0
	if self.cfg.engineLights then
		MAT:SetTexture("$basetexture", shaderpack.dynamiclights.Texture() or "vgui/black")
		MAT:SetTexture("$texture1", shaderpack.dynamiclights.ProjectedTexture() or "vgui/black")
		shaderpack.dynamiclights.Update(eye)
		shaderpack.dynamiclights.UpdateProjected(eye)
		render.SetMaterial(MAT)
	end

	render.OverrideDepthEnable(true, true)
	for _, ch in ipairs(visible) do
		for _, b in ipairs(ch.meshes) do
			local show = false
			for _, g in ipairs(b.groups) do
				if sight:Shows(g) then
					show = true
					break
				end
			end

			if show then
				b.m:Draw()
				shown = shown + 1
				drawn[shown] = b.m
			end
		end
	end

	render.OverrideDepthEnable(false, false)

	if DEPTH_MAT and shown > 0 and depthslices and depthslices.BeginDepthWrite() then
		setConstant(DEPTH_MAT, "$c0", eye.x, eye.y, eye.z, time)
		setConstant(DEPTH_MAT, "$c2", fwd.x, fwd.y, fwd.z)
		render.SetMaterial(DEPTH_MAT)
		for i = 1, shown do
			drawn[i]:Draw()
		end
		depthslices.EndDepthWrite()
	end

	for i = shown + 1, #drawn do
		drawn[i] = nil
	end
end

function Layer:Stop()
	hook.Remove("PostDrawOpaqueRenderables", "borealis_" .. self.cfg.name)
	self.grid:Stop()
	self.tuftCache, self.triGrid = nil, nil
end

function Layer:SetDistance(radius)
	radius = math.min(radius, chunks.MAX_DISTANCE)
	self.radius = radius
	self.grid.radius = radius
	self.fadeStart, self.fadeEnd = radius * 0.72, radius * 0.98
	for _, mat in ipairs({ self.mat, self.depthMat }) do
		mat:SetFloat("$c1_w", self.fadeStart)
		mat:SetFloat("$c3_w", self.fadeEnd)
	end
end

function Layer:Start()
	self:Stop()
	local cfg = self.cfg
	self.mat = self.mat or CreateShaderMaterial("borealis_" .. cfg.name .. "_" .. os.time(), {
		["$pixshader"] = cfg.pixelShader,
		["$vertexshader"] = cfg.vertexShader,
		["$linearread_basetexture"] = 1,
		["$linearread_texture1"] = 1,
		["$ignorez"] = 0,
		["$depthtest"] = 1,
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$linearwrite"] = 0,
		["$nocull"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 1, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 1,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})

	if not self.depthMat and file.Exists("shaders/fxc/" .. cfg.depthShader .. ".vcs", "GAME") then
		self.depthMat = CreateShaderMaterial("borealis_" .. cfg.name .. "depth_" .. os.time(), {
			["$pixshader"] = cfg.depthShader,
			["$vertexshader"] = cfg.vertexShader,
			["$alpha_blend"] = 0,
			["$nocull"] = 1,
			["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
			["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
			["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
			["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
		})
	end

	cfg.palette(self.mat, self.depthMat)
	self:SetDistance(self.radius)

	self.tuftCache = {}
	self.grid:Start()
	hook.Add("PostDrawOpaqueRenderables", "borealis_" .. cfg.name, function(_, _, sky3d) self:draw(sky3d) end)
end

function foliage.Layer(cfg)
	local layer = setmetatable({
		cfg = cfg, height = 1, radius = 3072,
		drawn = {},
		sight = chunks.Sight(),
	}, Layer)
	layer.grid = chunks.Grid({
		name = cfg.name, size = CHUNK, radius = layer.radius, pad = cfg.sway, cacheLimit = MESH_CACHE_TUFTS,
		load = function() return layer:load() end,
		build = function(ch) return layer:buildChunk(ch) end,
		destroy = destroyMeshes,
		failed = function() layer:Stop() end,
	})
	foliage.layers[cfg.name] = layer

	return layer
end

function foliage.SetPaused(name, paused)
	local layer = foliage.layers[name]
	if layer then
		layer.grid:SetPaused(paused)
	end
end
