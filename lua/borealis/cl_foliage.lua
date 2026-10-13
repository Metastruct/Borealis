local foliage = shaderpack.foliage or {}
shaderpack.foliage = foliage
local bspdata, depthslices = shaderpack.bspdata, shaderpack.depthslices
foliage.layers = foliage.layers or {}

local CHUNK = 512 -- world units per chunk
local BUILD_BUDGET_MS = 3 -- generation work per frame
local MESH_BATCH = 240 -- tufts per IMesh, about 1 ms to build
local STRIDE = 7 -- numbers per tuft in a chunk's flat tuft array: x, y, z, seed, height scale, packed light, vis cluster
local SIGHT_TESTS_PER_FRAME = 40 -- line of sight tests per draw
local MESH_CACHE_TUFTS = jit.arch == "x64" and math.huge or 200000
local FILL_K = 0.5 -- ambient cube share added as fill light, not scaled by tod's light style

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
		local first = named(mat:GetString("$basetexture")) or (not base2 and named(name))
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

-- tod rescales the lightmaps at runtime through the named light_environment's
-- light style; ComputeLighting returns the unscaled lightmap, so the current
-- style scale is applied per frame (engine: (letter - 'a') * 22 / 256)
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

local function chunkKey(cx, cy)
	return cx * 65536 + cy
end

local UP = Vector(0, 0, 1)
local traceStart, traceEnd, lightPos = Vector(0, 0, 0), Vector(0, 0, 0), Vector(0, 0, 0)
local coverTraceRes = {}
local coverTrace = { mask = MASK_SOLID_BRUSHONLY, start = traceStart, endpos = traceEnd, output = coverTraceRes }

-- more generation work when the frame has headroom, less when it is already slow
function Layer:budget()
	return math.Clamp(16 - RealFrameTime() * 1000 + self.lastThinkMs, BUILD_BUDGET_MS * 0.7, BUILD_BUDGET_MS * 2)
end

-- rasterises the chunk into a flat tuft array (STRIDE numbers per tuft),
-- yielding when the frame budget is spent
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

	local lightCache = {} -- one lighting sample per 2x2 cells, lightmap luxels are ~16 units, packed as r * 65536 + g * 256 + b of light / 2
	local function coverLight(x, y, z)
		-- skip tufts under floors, roofs and other covering brushes
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

	local sliceStart = SysTime()
	for gy = y0, y1 - 1, spacing do
		if (SysTime() - sliceStart) * 1000 > self:budget() then
			coroutine.yield()
			sliceStart = SysTime()
		end

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
							-- cluster sampled above the blade, a hair higher when that lands in solid
							local cluster = clusterAt(x, y, z + 8)
							if cluster < 0 then cluster = clusterAt(x, y, z + 24) end

							-- mostly tall, some short
							tufts[n + 1], tufts[n + 2], tufts[n + 3], tufts[n + 4], tufts[n + 5], tufts[n + 6], tufts[n + 7] = x, y, z, seed, 0.5 + r4 * r4 * 0.9 * (kept == true and 1 or kept), light, cluster
							n = n + STRIDE
						end
					end
				end
			end
		end
	end

	-- tufts sorted by cluster, so a mesh batch spans few clusters
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
local DIRS = { { 1, 0 }, { COS60, SIN60 }, { -COS60, SIN60 } } -- three crossed quads per tuft
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

-- one batch { m = IMesh, groups } for tufts first .. last (tuft indices,
-- 1-based).  The tufts come sorted by vis cluster, each run is a group with
-- its cluster (-1 for in solid), its centre and its first and last tuft.
-- screenspace_general binds position, colour and texcoord 0 only: colour
-- rgb = light / 2, colour a = seed, uv.x = blade u + 2 * height index
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
			g = { cluster = cluster, n = 0, x = 0, y = 0, z = 0, ax = x, ay = y, az = z, sightEpoch = -1, blocked = false }
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

	local lift = quadH * height * 0.5
	for _, gr in ipairs(groups) do
		gr.x, gr.y, gr.z = gr.x / gr.n, gr.y / gr.n, gr.z / gr.n + lift
		gr.az, gr.bz = gr.az + lift, gr.bz + lift
	end

	return { m = m, groups = groups }
end

local function destroyMeshes(ch)
	if not ch.mesh then return end
	for _, b in ipairs(ch.mesh) do
		b.m:Destroy()
	end
end

-- bounding sphere of a chunk's tufts, for the frustum test in draw
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

-- picks the next queued chunk: nearest first, chunks in front of the camera
-- before the rest.  Priorities are recomputed only when chunks were added or the
-- eye moved a chunk, a large radius queues thousands of mostly empty chunks
function Layer:nextChunk()
	local eye, fwd = EyePos(), EyeVector()
	local buildQueue, chunks = self.buildQueue, self.chunks
	if self.queueDirty or eye:DistToSqr(self.queueEye) > CHUNK * CHUNK then
		self.queueDirty, self.queueEye = false, eye
		local n = 0
		for i = 1, #buildQueue do
			local ch = buildQueue[i]
			buildQueue[i] = nil
			if ch.mesh == nil and chunks[chunkKey(ch.cx, ch.cy)] == ch then
				local dx, dy = ch.cx * CHUNK + CHUNK * 0.5 - eye.x, ch.cy * CHUNK + CHUNK * 0.5 - eye.y
				local dist = math.sqrt(dx * dx + dy * dy)
				local behind = dist > CHUNK and (dx * fwd.x + dy * fwd.y) / dist < -0.35
				ch.prio = dist + (behind and self.radius or 0)
				n = n + 1
				buildQueue[n] = ch
			end
		end
	end

	local count = #buildQueue
	if count == 0 then return end
	local best = 1
	for i = 2, count do
		if buildQueue[i].prio < buildQueue[best].prio then best = i end
	end

	local ch = buildQueue[best]
	buildQueue[best] = buildQueue[count]
	buildQueue[count] = nil
	local key = chunkKey(ch.cx, ch.cy)
	if ch.mesh ~= nil or chunks[key] ~= ch then return end

	local cached = self.tuftCache[key]
	if cached == false then
		ch.mesh, ch.tufts = false, 0
	elseif cached then
		ch.pendingTufts, ch.nextTuft, ch.meshes = cached, 1, {}
		self:chunkBounds(ch, cached)
		self.current = ch
	else
		local x0, y0 = ch.cx * CHUNK, ch.cy * CHUNK
		local cand = bspdata.Candidates(self.triGrid, x0, y0, x0 + CHUNK, y0 + CHUNK)
		if #cand == 0 then
			ch.mesh, ch.tufts = false, 0
			self.tuftCache[key] = false
		else
			ch.co = coroutine.create(function() return self:raster(ch, cand) end)
			self.current = ch
		end
	end
end

-- advances the current chunk: raster until the budget is spent, then one mesh batch at a time
function Layer:stepChunk()
	local ch = self.current
	if ch.pendingTufts then
		local tufts = ch.pendingTufts
		local total = #tufts / STRIDE
		local first = ch.nextTuft
		local last = math.min(first + (self.cfg.meshBatch or MESH_BATCH) - 1, total)
		ch.meshes[#ch.meshes + 1] = self:buildMesh(tufts, first, last)
		if last >= total then
			ch.tufts = total
			ch.mesh = ch.meshes
			ch.pendingTufts, ch.co = nil, nil
			self.current = nil
		else
			ch.nextTuft = last + 1
		end

		return true
	end

	local ok, tufts = coroutine.resume(ch.co)
	if not ok then
		ErrorNoHalt("[" .. self.cfg.name .. "] chunk build failed: " .. tostring(tufts) .. "\n")
		ch.mesh, ch.tufts = false, 0
		self.current = nil
	elseif coroutine.status(ch.co) == "dead" then
		local key = chunkKey(ch.cx, ch.cy)
		if #tufts == 0 then
			ch.mesh, ch.tufts = false, 0
			self.tuftCache[key] = false
			self.current = nil
		else
			self.tuftCache[key] = tufts
			ch.pendingTufts, ch.nextTuft, ch.meshes = tufts, 1, {}
			self:chunkBounds(ch, tufts)
		end
	else
		return false -- budget spent inside the raster
	end

	return true
end

function Layer:load()
	local vis, why = bspdata.WaitVis()
	if not vis then return false, why end

	self.triGrid, why = bspdata.Triangles(self.cfg.classify, self.cfg.minNormalZ)
	if not self.triGrid then return false, why end

	return true
end

function Layer:think()
	if self.paused then return end
	local t0 = SysTime()
	if not self.ready then
		local ok, res, why = coroutine.resume(self.loader)
		if not ok then
			ErrorNoHalt("[" .. self.cfg.name .. "] bsp parse failed: " .. tostring(res) .. "\n")
			self:Stop()
			return
		end

		if coroutine.status(self.loader) == "dead" then
			-- a parse that gave up leaves no tree to look clusters up in
			if not res then
				ErrorNoHalt("[" .. self.cfg.name .. "] off: " .. tostring(why) .. "\n")
				self:Stop()
				return
			end

			self.ready = true
		end

		self.lastThinkMs = (SysTime() - t0) * 1000
		return
	end

	local frameBudget = self:budget()
	while (SysTime() - t0) * 1000 < frameBudget do
		if self.current then
			if not self:stepChunk() then break end
		elseif #self.buildQueue > 0 then
			self:nextChunk()
		else
			break
		end
	end

	self.lastThinkMs = (SysTime() - t0) * 1000
end

local function byDrawDist(a, b)
	return a.drawDist < b.drawDist
end

-- line of sight from the eye to a group, against world brushes only: a
-- blocking face either draws (depth hides the blades) or does not (nodraw,
-- sky, a back face) and the sky fills it, so the blades are skipped either
-- way.  Windows and grates are passed through like the depth test does.
-- Tests are redone when the eye moves or after a while, a few per frame
local sightStart, sightEnd, sightRes = Vector(), Vector(), {}
local sightTrace = { start = sightStart, endpos = sightEnd, mask = CONTENTS_SOLID, output = sightRes, filter = function() return false end }
local function sightBlocked(x, y, z)
	sightEnd:SetUnpacked(x, y, z)
	util.TraceLine(sightTrace)

	return sightRes.Hit and not sightRes.StartSolid
end

function Layer:draw(sky3d)
	if self.paused or not self.ready or sky3d or render.GetRenderTarget() then return end
	local MAT, DEPTH_MAT = self.mat, self.depthMat
	local eye = EyePos()
	local fwd = EyeVector()
	local amb = render.GetAmbientLightColor()
	local time = CurTime() * (self.cfg.timeScale or 1) % (self.cfg.timeWrap or 1000)

	setConstant(MAT, "$c0", eye.x, eye.y, eye.z, time)
	MAT:SetFloat("$c1_y", packColor(amb.x * FILL_K, amb.y * FILL_K, amb.z * FILL_K))
	MAT:SetFloat("$c2_x", worldLightScale())
	if self.cfg.frame then self.cfg.frame(MAT, DEPTH_MAT, time) end
	MAT:SetFloat("$c2_w", render.GetToneMappingScaleLinear().x)
	render.SetMaterial(MAT)

	-- view frustum: the setup's fov is the horizontal one at this aspect
	local vs = render.GetViewSetup()
	local ang = EyeAngles()
	local right, up = ang:Right(), ang:Up()
	local tanH = math.tan(math.rad(vs.fov or 90) * 0.5)
	local tanV = tanH / (vs.aspect or (ScrW() / ScrH()))
	local kH, kV = math.sqrt(1 + tanH * tanH), math.sqrt(1 + tanV * tanV)

	local chunks, visible = self.chunks, self.visible
	local radius = self.radius
	local sway = self.cfg.sway or 0
	local n = math.ceil(radius / CHUNK)
	local ecx, ecy = math.floor(eye.x / CHUNK), math.floor(eye.y / CHUNK)
	local half = CHUNK * 0.5
	local nvis = 0
	for cy = ecy - n, ecy + n do
		for cx = ecx - n, ecx + n do
			local ddx, ddy = cx * CHUNK + half - eye.x, cy * CHUNK + half - eye.y
			local dist = math.sqrt(ddx * ddx + ddy * ddy)
			if dist - half * 1.42 < radius then
				local key = chunkKey(cx, cy)
				local ch = chunks[key]
				if not ch then
					ch = { cx = cx, cy = cy }
					chunks[key] = ch
					self.buildQueue[#self.buildQueue + 1] = ch
					self.queueDirty = true
				elseif ch.mesh then
					-- bounding sphere against the four side planes
					local ddz, r = ch.cz - eye.z, ch.radius + sway
					local fz = ddx * fwd.x + ddy * fwd.y + ddz * fwd.z
					if fz > -r then
						local fx = ddx * right.x + ddy * right.y + ddz * right.z
						local fy = ddx * up.x + ddy * up.y + ddz * up.z
						if math.abs(fx) < fz * tanH + r * kH and math.abs(fy) < fz * tanV + r * kV then
							ch.drawDist = dist
							nvis = nvis + 1
							visible[nvis] = ch
						end
					end
				end
			end
		end
	end

	-- the material tests depth but does not write it; force both, near to far
	for i = #visible, nvis + 1, -1 do
		visible[i] = nil
	end

	table.sort(visible, byDrawDist)

	-- a batch draws when one of its groups is in the eye's PVS and in line of
	-- sight at its centre or either end.  An untested group counts as visible
	local eyeCluster = bspdata.ClusterAt(eye.x, eye.y, eye.z)
	local pvs = bspdata.PVS(eyeCluster)
	if RealTime() > self.sightNext or eye:DistToSqr(self.sightEye) > 64 * 64 then
		self.sightEpoch, self.sightNext = self.sightEpoch + 1, RealTime() + 0.5
		self.sightEye:Set(eye)
	end

	local sightEpoch = self.sightEpoch
	local drawn = self.drawn
	sightStart:Set(eye)
	local tests = 0
	local shown = 0
	render.OverrideDepthEnable(true, true)
	for _, ch in ipairs(visible) do
		for _, b in ipairs(ch.mesh) do
			local show = false
			for _, g in ipairs(b.groups) do
				local c = g.cluster
				if c == eyeCluster then
					show = true
					break
				elseif pvs == nil or c < 0 or pvs[c] then
					if g.sightEpoch ~= sightEpoch and tests < SIGHT_TESTS_PER_FRAME then
						tests = tests + 1
						g.sightEpoch = sightEpoch
						g.blocked = sightBlocked(g.x, g.y, g.z) and sightBlocked(g.ax, g.ay, g.az) and sightBlocked(g.bx, g.by, g.bz)
					end

					if not g.blocked then
						show = true
						break
					end
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

	-- evict chunks well outside the radius, keeping their tuft lists
	if RealTime() > self.evictNext then
		self.evictNext = RealTime() + 2
		local limit = (radius + CHUNK * 2) ^ 2
		local far, meshed = {}, 0
		for key, ch in pairs(chunks) do
			local ddx, ddy = ch.cx * CHUNK + half - eye.x, ch.cy * CHUNK + half - eye.y
			local d = ddx * ddx + ddy * ddy
			if d > limit and ch ~= self.current then
				if ch.mesh then
					ch.evictDist = d
					far[#far + 1] = ch
					meshed = meshed + ch.tufts
				else
					chunks[key] = nil
				end
			end
		end

		if meshed > MESH_CACHE_TUFTS then
			table.sort(far, function(a, b) return a.evictDist > b.evictDist end)
			for _, ch in ipairs(far) do
				if meshed <= MESH_CACHE_TUFTS then break end
				meshed = meshed - ch.tufts
				destroyMeshes(ch)
				chunks[chunkKey(ch.cx, ch.cy)] = nil
			end
		end
	end
end

function Layer:Stop()
	local id = "ms_" .. self.cfg.name
	hook.Remove("Think", id)
	hook.Remove("PostDrawOpaqueRenderables", id)
	if self.chunks then
		for _, ch in pairs(self.chunks) do
			destroyMeshes(ch)
		end
	end

	table.Empty(self.visible)
	self.chunks, self.tuftCache, self.buildQueue, self.current = nil, nil, nil, nil
	self.triGrid, self.loader, self.ready = nil, nil, false
end

-- draw distance: the chunk radius and the shader's fade range.  Chunks past a
-- shrunk radius get evicted by draw, a grown one fills in through the queue
function Layer:SetDistance(radius)
	self.radius = radius
	self.fadeStart, self.fadeEnd = radius * 0.72, radius * 0.98
	for _, mat in ipairs({ self.mat, self.depthMat }) do
		mat:SetFloat("$c1_w", self.fadeStart)
		mat:SetFloat("$c3_w", self.fadeEnd)
	end
end

function Layer:Start()
	self:Stop()
	local cfg = self.cfg
	self.mat = self.mat or CreateShaderMaterial("ms_" .. cfg.name .. "_" .. os.time(), {
		["$pixshader"] = cfg.pixelShader,
		["$vertexshader"] = cfg.vertexShader,
		["$ignorez"] = 0,
		["$depthtest"] = 1,
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$linearwrite"] = 0, -- sRGB write like the world shaders, the baked light is linear
		["$nocull"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 1, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 1,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})

	if not self.depthMat and file.Exists("shaders/fxc/" .. cfg.depthShader .. ".vcs", "GAME") then
		self.depthMat = CreateShaderMaterial("ms_" .. cfg.name .. "depth_" .. os.time(), {
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

	-- the materials outlive a restart, so the palette is set every time
	cfg.palette(self.mat, self.depthMat)
	self:SetDistance(self.radius)

	self.chunks, self.tuftCache, self.buildQueue = {}, {}, {}
	self.loader = coroutine.create(function() return self:load() end)
	local id = "ms_" .. cfg.name
	hook.Add("Think", id, function() self:think() end)
	hook.Add("PostDrawOpaqueRenderables", id, function(_, _, sky3d) self:draw(sky3d) end)
end

function foliage.Layer(cfg)
	local layer = setmetatable({
		cfg = cfg, height = 1, radius = 3072, lastThinkMs = 0, ready = false, paused = false,
		visible = {}, drawn = {}, queueDirty = false, queueEye = Vector(),
		sightEpoch = 0, sightEye = Vector(), sightNext = 0, evictNext = 0,
	}, Layer)
	foliage.layers[cfg.name] = layer

	return layer
end

function foliage.SetPaused(name, paused)
	local layer = foliage.layers[name]
	if layer then
		layer.paused = paused
	end
end
