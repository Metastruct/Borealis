local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

if SERVER then
	if not resource.AddShader then return end

	resource.AddShader("grass_vs30")
	resource.AddShader("grass_ps30")
	resource.AddShader("grassdepth_ps30")

	return
end

-- Grass tufts on every world surface whose material has a grass surfaceprop.
-- Faces come from the BSP (brushes and displacements, with the painted blend
-- alpha as density), tufts are generated per 512 unit chunk around the eye
-- inside a per-frame budget, and drawn as analytic blades by grass_ps30.

local GRASS_ENABLED = CreateClientConVar("cl_draw_grass", "0", true, false, "draw grass tufts on grass surfaces")
local GRASS_DISTANCE = CreateClientConVar("cl_draw_grass_distance", "3072", true, false, "grass draw distance in units", 1024, 16384)

-- winter: tod swaps the ground for snow (tod/snow.lua, December to February),
-- so the tufts thin out, shorten and go to dead straw poking through it.
-- tod_removesnow ends it at runtime through TOD_WinterRemoved
local month = tonumber(os.date("%m")) or 0
local WINTER = month >= 12 or month <= 2
local AUTUMN = false
local DENSITY, HEIGHT, DRYNESS, ROOT_COLOR, TIP_COLOR, DRY_COLOR

local function setSeason(winter, autumn)
	WINTER, AUTUMN = winter, autumn
	DENSITY = winter and 0.35 or 1 -- share of the tufts kept
	HEIGHT = winter and 0.7 or 1
	DRYNESS = winter and 1 or autumn and 0.6 or 0.15 -- 0 green .. 1 golden
	ROOT_COLOR = winter and { 0.09, 0.085, 0.06 } or autumn and { 0.07, 0.06, 0.02 } or { 0.06, 0.075, 0.02 }
	TIP_COLOR = autumn and { 0.13, 0.15, 0.045 } or { 0.15, 0.19, 0.05 }
	DRY_COLOR = winter and { 0.28, 0.25, 0.17 } or autumn and { 0.32, 0.2, 0.06 } or { 0.24, 0.21, 0.09 } -- tip colour of dry blades
end

setSeason(WINTER, AUTUMN)

local CHUNK = 512 -- world units per chunk
local SPACING = 18 -- tuft grid spacing
local JITTER = 8
local RADIUS, FADE_START, FADE_END -- chunks kept and drawn within RADIUS, blades fade out between the two, all from cl_grass_distance
local QUAD_W, QUAD_H = 26, 40 -- quad size at height scale 1
local MAX_SLOPE_Z = 0.7 -- skip faces steeper than this normal z
local WIND_ANGLE = math.atan2(0.6, 0.8)
local WIND = 0.45 -- bend at the tip, in quad widths
local TRANSLUCENCY = 0.35
local FILL_K = 0.5 -- ambient cube share added as fill light, not scaled by tod's light style
local BUILD_BUDGET_MS = 3 -- generation work per frame
local MESH_BATCH = 240 -- tufts per IMesh, about 1 ms to build
local STRIDE = 7 -- numbers per tuft in a chunk's flat tuft array: x, y, z, seed, height scale, packed light, vis cluster
local SIGHT_TESTS_PER_FRAME = 40 -- line of sight tests per draw

--------------------------------------------------------------------------
-- BSP: grass triangles with per-vertex blend alpha (0 = grass, 255 = other),
-- indexed by grid cell, and the vis tree from bspdata (cl_bsp.lua).  The
-- engine hides world geometry beyond sky brushes by PVS, never by depth, so
-- the tufts follow the same rule
--------------------------------------------------------------------------
local triGrid
local clusterAt, pvsFor, sample = bspdata.ClusterAt, bspdata.PVS, bspdata.Sample

local function grassMode(name)
	local mat = Material(name)
	local sp = (mat:GetString("$surfaceprop") or ""):lower()
	local sp2 = (mat:GetString("$surfaceprop2") or ""):lower()
	if sp == "grass" and (sp2 == "" or sp2 == "grass") then
		return 1
	elseif sp == "grass" then
		return 2
	elseif sp2 == "grass" then
		return 3
	end
end

local function loadGrassTriangles()
	local vis, why = bspdata.WaitVis()
	if not vis then return false, why end

	triGrid, why = bspdata.Triangles(grassMode, MAX_SLOPE_Z)
	if not triGrid then return false, why end

	return true
end

--------------------------------------------------------------------------
-- chunks
--------------------------------------------------------------------------
local chunks -- key -> { cx, cy, mesh = {IMesh}|false|nil, tufts }
local tuftCache -- key -> flat tuft array, or false when empty, of evicted chunks
local buildQueue
local current -- chunk being generated

local function chunkKey(cx, cy)
	return cx * 65536 + cy
end

local UP = Vector(0, 0, 1)
local traceStart, traceEnd, lightPos = Vector(0, 0, 0), Vector(0, 0, 0), Vector(0, 0, 0)
local coverTraceRes = {}
local coverTrace = { mask = MASK_SOLID_BRUSHONLY, start = traceStart, endpos = traceEnd, output = coverTraceRes }

-- more generation work when the frame has headroom, less when it is already slow
local lastThinkMs = 0
local function budget()
	return math.Clamp(16 - RealFrameTime() * 1000 + lastThinkMs, BUILD_BUDGET_MS * 0.7, BUILD_BUDGET_MS * 2)
end

-- rasterises the chunk into a flat tuft array (STRIDE numbers per tuft),
-- yielding when the frame budget is spent
local function rasterChunk(ch, cand)
	local x0, y0 = ch.cx * CHUNK, ch.cy * CHUNK
	local x1, y1 = x0 + CHUNK, y0 + CHUNK
	local tufts, n = {}, 0
	local rng = ch.cx * 73856093 + ch.cy * 19349663
	local function rand()
		rng = (rng * 1103515245 + 12345) % 2147483648

		return rng / 2147483648
	end

	local lightCache = {} -- one lighting sample per 2x2 cells, lightmap luxels are ~16 units, packed as r * 65536 + g * 256 + b of light / 2
	local sliceStart = SysTime()
	for gy = y0, y1 - 1, SPACING do
		if (SysTime() - sliceStart) * 1000 > budget() then
			coroutine.yield()
			sliceStart = SysTime()
		end

		for gx = x0, x1 - 1, SPACING do
			local x = gx + SPACING * 0.5 + (rand() - 0.5) * 2 * JITTER
			local y = gy + SPACING * 0.5 + (rand() - 0.5) * 2 * JITTER
			local seed, r3, r4, r5 = rand(), rand(), rand(), rand()
			for _, t in ipairs(cand) do
				if x >= t[13] and x <= t[15] and y >= t[14] and y <= t[16] then
					local z, alpha = sample(t, x, y)
					if z and r3 * 255 > alpha and r5 <= DENSITY then
						-- skip tufts under floors, roofs and other covering brushes, and under water
						traceStart:SetUnpacked(x, y, z + QUAD_H + 2)
						traceEnd:SetUnpacked(x, y, z + 1)
						util.TraceLine(coverTrace)
						if not coverTraceRes.Hit and bit.band(util.PointContents(traceEnd), MASK_WATER) == 0 then
							local lkey = (math.floor(x / (SPACING * 2)) * 4096 + math.floor(y / (SPACING * 2))) * 1024 + math.floor(z / 64)
							local light = lightCache[lkey]
							if not light then
								lightPos:SetUnpacked(x, y, z + 12)
								local l = render.ComputeLighting(lightPos, UP)
								light = math.Clamp(math.floor(l.x * 127.5), 0, 255) * 65536 + math.Clamp(math.floor(l.y * 127.5), 0, 255) * 256 + math.Clamp(math.floor(l.z * 127.5), 0, 255)
								lightCache[lkey] = light
							end

							-- cluster sampled above the blade, a hair higher when that lands in solid
							local cluster = clusterAt(x, y, z + 8)
							if cluster < 0 then cluster = clusterAt(x, y, z + 24) end

							-- mostly tall, some short
							tufts[n + 1], tufts[n + 2], tufts[n + 3], tufts[n + 4], tufts[n + 5], tufts[n + 6], tufts[n + 7] = x, y, z, seed, 0.5 + r4 * r4 * 0.9, light, cluster
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

-- one batch { m = IMesh, groups } for tufts first .. last (tuft indices,
-- 1-based).  The tufts come sorted by vis cluster, each run is a group with
-- its cluster (-1 for in solid), its centre and its first and last tuft.
-- screenspace_general binds position, colour and texcoord 0 only: colour
-- rgb = light / 2, colour a = seed, uv.x = blade u + 2 * height index
local function buildMesh(tufts, first, last)
	local m = Mesh()
	local groups, g = {}, nil
	mesh.Begin(m, MATERIAL_QUADS, (last - first + 1) * #DIRS)
	for i = first, last do
		local o = (i - 1) * STRIDE
		local x, y, z, seed, hs, light, cluster = tufts[o + 1], tufts[o + 2], tufts[o + 3] + 0.5, tufts[o + 4], tufts[o + 5], tufts[o + 6], tufts[o + 7]
		if not g or cluster ~= g.cluster then
			g = { cluster = cluster, n = 0, x = 0, y = 0, z = 0, ax = x, ay = y, az = z, sightEpoch = -1, blocked = false }
			groups[#groups + 1] = g
		end

		g.n, g.x, g.y, g.z = g.n + 1, g.x + x, g.y + y, g.z + z
		g.bx, g.by, g.bz = x, y, z
		vr = math.floor(light / 65536)
		vg = math.floor(light / 256) % 256
		vb = light % 256
		va = math.floor(seed * 255)
		local hIndex = math.Clamp(math.floor((hs - 0.5) / 0.9 * 7 + 0.5), 0, 7)
		hs = 0.5 + hIndex / 7 * 0.9
		local h = QUAD_H * hs * HEIGHT
		local w = QUAD_W * (0.7 + 0.3 * hs) * 0.5
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

	mesh.End()

	local lift = QUAD_H * HEIGHT * 0.5
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

local function byPrio(a, b)
	return a.prio < b.prio
end

-- bounding sphere of a chunk's tufts, for the frustum test in draw
local function chunkBounds(ch, tufts)
	local zmin, zmax = math.huge, -math.huge
	for o = 3, #tufts, STRIDE do
		local z = tufts[o]
		if z < zmin then zmin = z end
		if z > zmax then zmax = z end
	end

	local half = CHUNK * 0.5
	local hz = (zmax - zmin) * 0.5 + QUAD_H
	ch.cz = zmin + hz
	ch.radius = math.sqrt(half * half * 2 + hz * hz)
end

-- picks the next queued chunk: nearest first, chunks in front of the camera
-- before the rest.  The queue is re-sorted only when chunks were added or the
-- eye moved a chunk, a large radius queues thousands of mostly empty chunks
local queueDirty, queueEye = false, Vector()
local function nextChunk()
	local eye, fwd = EyePos(), EyeVector()
	if queueDirty or eye:DistToSqr(queueEye) > CHUNK * CHUNK then
		queueDirty, queueEye = false, eye
		for _, ch in ipairs(buildQueue) do
			local dx, dy = ch.cx * CHUNK + CHUNK * 0.5 - eye.x, ch.cy * CHUNK + CHUNK * 0.5 - eye.y
			local dist = math.sqrt(dx * dx + dy * dy)
			local behind = dist > CHUNK and (dx * fwd.x + dy * fwd.y) / dist < -0.35
			ch.prio = dist + (behind and RADIUS or 0)
		end

		table.sort(buildQueue, byPrio)
	end

	local ch = table.remove(buildQueue, 1)
	local key = chunkKey(ch.cx, ch.cy)
	if ch.mesh ~= nil or chunks[key] ~= ch then return end

	local cached = tuftCache[key]
	if cached == false then
		ch.mesh, ch.tufts = false, 0
	elseif cached then
		ch.pendingTufts, ch.nextTuft, ch.meshes = cached, 1, {}
		chunkBounds(ch, cached)
		current = ch
	else
		local x0, y0 = ch.cx * CHUNK, ch.cy * CHUNK
		local cand = bspdata.Candidates(triGrid, x0, y0, x0 + CHUNK, y0 + CHUNK)
		if #cand == 0 then
			ch.mesh, ch.tufts = false, 0
			tuftCache[key] = false
		else
			ch.co = coroutine.create(function() return rasterChunk(ch, cand) end)
			current = ch
		end
	end
end

-- advances the current chunk: raster until the budget is spent, then one mesh batch at a time
local function stepChunk()
	local ch = current
	if ch.pendingTufts then
		local tufts = ch.pendingTufts
		local total = #tufts / STRIDE
		local first = ch.nextTuft
		local last = math.min(first + MESH_BATCH - 1, total)
		ch.meshes[#ch.meshes + 1] = buildMesh(tufts, first, last)
		if last >= total then
			ch.tufts = total
			ch.mesh = ch.meshes
			ch.pendingTufts, ch.co = nil, nil
			current = nil
		else
			ch.nextTuft = last + 1
		end

		return true
	end

	local ok, tufts = coroutine.resume(ch.co)
	if not ok then
		ErrorNoHalt("[grass] chunk build failed: " .. tostring(tufts) .. "\n")
		ch.mesh, ch.tufts = false, 0
		current = nil
	elseif coroutine.status(ch.co) == "dead" then
		local key = chunkKey(ch.cx, ch.cy)
		if #tufts == 0 then
			ch.mesh, ch.tufts = false, 0
			tuftCache[key] = false
			current = nil
		else
			tuftCache[key] = tufts
			ch.pendingTufts, ch.nextTuft, ch.meshes = tufts, 1, {}
			chunkBounds(ch, tufts)
		end
	else
		return false -- budget spent inside the raster
	end

	return true
end

--------------------------------------------------------------------------
-- rendering
--------------------------------------------------------------------------
local MAT, DEPTH_MAT
local drawn = {}
local loader -- BSP parse coroutine
local ready = false
local stop -- defined below, called when the parse gives up

local function packColor(r, g, b)
	return math.floor(math.Clamp(r, 0, 1) * 255) * 65536 + math.floor(math.Clamp(g, 0, 1) * 255) * 256 + math.floor(math.Clamp(b, 0, 1) * 255)
end

-- tod rescales the lightmaps at runtime through the named light_environment's
-- light style; ComputeLighting returns the unscaled lightmap, so the current
-- style scale is applied per frame (engine: (letter - 'a') * 22 / 256)
local function worldLightScale()
	if not (tod and tod.MultToLightEnv and tod.CurrentParams) then return 1 end
	local code = tod.MultToLightEnv(tod.CurrentParams.world_light_multiplier or 1)
	if not isnumber(code) then return 1 end

	return (code - 97) * 22 / 256
end

local function think()
	local t0 = SysTime()
	if not ready then
		local ok, res, why = coroutine.resume(loader)
		if not ok then
			ErrorNoHalt("[grass] bsp parse failed: " .. tostring(res) .. "\n")
			stop()
			return
		end

		if coroutine.status(loader) == "dead" then
			-- a parse that gave up leaves no tree to look clusters up in
			if not res then
				ErrorNoHalt("[grass] grass off: " .. tostring(why) .. "\n")
				stop()
				return
			end

			ready = true
		end

		lastThinkMs = (SysTime() - t0) * 1000
		return
	end

	local frameBudget = budget()
	while (SysTime() - t0) * 1000 < frameBudget do
		if current then
			if not stepChunk() then break end
		elseif #buildQueue > 0 then
			nextChunk()
		else
			break
		end
	end

	lastThinkMs = (SysTime() - t0) * 1000
end

local function byDrawDist(a, b)
	return a.drawDist < b.drawDist
end

local visible = {}
local evictNext = 0
local lastWet = 0

-- line of sight from the eye to a group, against world brushes only: a
-- blocking face either draws (depth hides the blades) or does not (nodraw,
-- sky, a back face) and the sky fills it, so the blades are skipped either
-- way.  Windows and grates are passed through like the depth test does.
-- Tests are redone when the eye moves or after a while, a few per frame
local sightEpoch, sightEye, sightNext = 0, Vector(), 0
local sightStart, sightEnd, sightRes = Vector(), Vector(), {}
local sightTrace = { start = sightStart, endpos = sightEnd, mask = CONTENTS_SOLID, output = sightRes, filter = function() return false end }
local function sightBlocked(x, y, z)
	sightEnd:SetUnpacked(x, y, z)
	util.TraceLine(sightTrace)

	return sightRes.Hit and not sightRes.StartSolid
end
local function draw(_, _, sky3d)
	if not ready or sky3d or render.GetRenderTarget() then return end
	local eye = EyePos()
	local fwd = EyeVector()
	local amb = render.GetAmbientLightColor()

	MAT:SetFloat("$c0_x", eye.x)
	MAT:SetFloat("$c0_y", eye.y)
	MAT:SetFloat("$c0_z", eye.z)
	MAT:SetFloat("$c0_w", CurTime() % 1000)
	MAT:SetFloat("$c1_y", packColor(amb.x * FILL_K, amb.y * FILL_K, amb.z * FILL_K))
	MAT:SetFloat("$c2_x", worldLightScale())

	-- wet blades go darker and greener while it rains (tod/rain.lua)
	local wet = tod and tod.rain and tod.rain.amount or 0
	if wet ~= lastWet then
		lastWet = wet
		local k = 1 - 0.3 * wet
		MAT:SetFloat("$c2_y", packColor(ROOT_COLOR[1] * k, ROOT_COLOR[2] * k, ROOT_COLOR[3] * k))
		MAT:SetFloat("$c2_z", packColor(TIP_COLOR[1] * k, TIP_COLOR[2] * (1 - 0.2 * wet), TIP_COLOR[3] * k))
		MAT:SetFloat("$c3_z", packColor(DRY_COLOR[1] * k, DRY_COLOR[2] * k, DRY_COLOR[3] * k))
	end
	MAT:SetFloat("$c2_w", render.GetToneMappingScaleLinear().x)
	render.SetMaterial(MAT)

	-- view frustum: the setup's fov is the horizontal one at this aspect
	local vs = render.GetViewSetup()
	local ang = EyeAngles()
	local right, up = ang:Right(), ang:Up()
	local tanH = math.tan(math.rad(vs.fov or 90) * 0.5)
	local tanV = tanH / (vs.aspect or (ScrW() / ScrH()))
	local kH, kV = math.sqrt(1 + tanH * tanH), math.sqrt(1 + tanV * tanV)

	local n = math.ceil(RADIUS / CHUNK)
	local ecx, ecy = math.floor(eye.x / CHUNK), math.floor(eye.y / CHUNK)
	local half = CHUNK * 0.5
	local nvis = 0
	for cy = ecy - n, ecy + n do
		for cx = ecx - n, ecx + n do
			local ddx, ddy = cx * CHUNK + half - eye.x, cy * CHUNK + half - eye.y
			local dist = math.sqrt(ddx * ddx + ddy * ddy)
			if dist - half * 1.42 < RADIUS then
				local key = chunkKey(cx, cy)
				local ch = chunks[key]
				if not ch then
					ch = { cx = cx, cy = cy }
					chunks[key] = ch
					buildQueue[#buildQueue + 1] = ch
					queueDirty = true
				elseif ch.mesh then
					-- bounding sphere against the four side planes
					local ddz, r = ch.cz - eye.z, ch.radius
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
	local eyeCluster = clusterAt(eye.x, eye.y, eye.z)
	local pvs = pvsFor(eyeCluster)
	if RealTime() > sightNext or eye:DistToSqr(sightEye) > 64 * 64 then
		sightEpoch, sightNext = sightEpoch + 1, RealTime() + 0.5
		sightEye:Set(eye)
	end

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
		DEPTH_MAT:SetFloat("$c0_x", eye.x)
		DEPTH_MAT:SetFloat("$c0_y", eye.y)
		DEPTH_MAT:SetFloat("$c0_z", eye.z)
		DEPTH_MAT:SetFloat("$c0_w", CurTime() % 1000)
		DEPTH_MAT:SetFloat("$c2_x", fwd.x)
		DEPTH_MAT:SetFloat("$c2_y", fwd.y)
		DEPTH_MAT:SetFloat("$c2_z", fwd.z)
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
	if RealTime() > evictNext then
		evictNext = RealTime() + 2
		local limit = (RADIUS + CHUNK * 2) ^ 2
		for key, ch in pairs(chunks) do
			local ddx, ddy = ch.cx * CHUNK + half - eye.x, ch.cy * CHUNK + half - eye.y
			if ddx * ddx + ddy * ddy > limit and ch ~= current then
				destroyMeshes(ch)
				chunks[key] = nil
			end
		end
	end
end

function stop()
	hook.Remove("Think", "ms_grass")
	hook.Remove("PostDrawOpaqueRenderables", "ms_grass")
	if chunks then
		for _, ch in pairs(chunks) do
			destroyMeshes(ch)
		end
	end

	table.Empty(visible)
	chunks, tuftCache, buildQueue, current = nil, nil, nil, nil
	triGrid, loader, ready = nil, nil, false
end

-- draw distance: the chunk radius and the shader's fade range.  Chunks past a
-- shrunk radius get evicted by draw, a grown one fills in through the queue
local function setDistance()
	RADIUS = math.Clamp(GRASS_DISTANCE:GetInt(), 1024, 16384)
	FADE_START, FADE_END = RADIUS * 0.72, RADIUS * 0.98
	if MAT then
		MAT:SetFloat("$c1_w", FADE_START)
		MAT:SetFloat("$c3_w", FADE_END)
	end
	if DEPTH_MAT then
		DEPTH_MAT:SetFloat("$c1_w", FADE_START)
		DEPTH_MAT:SetFloat("$c3_w", FADE_END)
	end
end

setDistance()

local function start(PIXEL_SHADER, VERTEX_SHADER)
	stop()
	MAT = MAT or CreateMaterial("ms_grass_" .. os.time(), "screenspace_general", {
		["$pixshader"] = PIXEL_SHADER,
		["$vertexshader"] = VERTEX_SHADER,
		["$basetexture"] = "",
		["$ignorez"] = 0,
		["$depthtest"] = 1,
		["$vertexcolor"] = 1,
		["$vertextransform"] = 1,
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$linearwrite"] = 0, -- sRGB write like the world shaders, the baked light is linear
		["$nocull"] = 1,
		["<dx90"] = { ["$no_draw"] = 1 },
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = WIND_ANGLE, ["$c1_y"] = 0, ["$c1_z"] = WIND, ["$c1_w"] = FADE_START,
		["$c2_x"] = 1, ["$c2_y"] = packColor(unpack(ROOT_COLOR)), ["$c2_z"] = packColor(unpack(TIP_COLOR)), ["$c2_w"] = 1,
		["$c3_x"] = TRANSLUCENCY, ["$c3_y"] = DRYNESS, ["$c3_z"] = packColor(unpack(DRY_COLOR)), ["$c3_w"] = FADE_END,
	})
	-- the material outlives a restart, so the season's palette is set every time
	MAT:SetFloat("$c2_y", packColor(unpack(ROOT_COLOR)))
	MAT:SetFloat("$c3_y", DRYNESS)
	MAT:SetFloat("$c3_z", packColor(unpack(DRY_COLOR)))
	lastWet = -1

	if not DEPTH_MAT and file.Exists("shaders/fxc/grassdepth_ps30.vcs", "GAME") then
		DEPTH_MAT = CreateMaterial("ms_grassdepth_" .. os.time(), "screenspace_general", {
			["$pixshader"] = "grassdepth_ps30",
			["$vertexshader"] = VERTEX_SHADER,
			["$basetexture"] = "",
			["$ignorez"] = 1,
			["$vertexcolor"] = 1,
			["$vertextransform"] = 1,
			["$alpha_blend"] = 0,
			["$linearwrite"] = 1,
			["$nocull"] = 1,
			["<dx90"] = { ["$no_draw"] = 1 },
			["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
			["$c1_x"] = WIND_ANGLE, ["$c1_y"] = 0, ["$c1_z"] = WIND, ["$c1_w"] = FADE_START,
			["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
			["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = FADE_END,
		})
	end

	setDistance()

	chunks, tuftCache, buildQueue = {}, {}, {}
	loader = coroutine.create(loadGrassTriangles)
	hook.Add("Think", "ms_grass", think)
	hook.Add("PostDrawOpaqueRenderables", "ms_grass", draw)
end

local function shadersAvailable()
	return file.Exists("shaders/fxc/grass_ps30.vcs", "GAME") and file.Exists("shaders/fxc/grass_vs30.vcs", "GAME")
end

local function apply()
	if not GRASS_ENABLED:GetBool() then
		stop()
		return
	end

	if shadersAvailable() then
		start("grass_ps30", "grass_vs30")
	elseif HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
		hook.Add("ShaderMounted", "ms_grass", function()
			hook.Remove("ShaderMounted", "ms_grass")
			if GRASS_ENABLED:GetBool() and shadersAvailable() then
				start("grass_ps30", "grass_vs30")
			end
		end)
	end
end

cvars.RemoveChangeCallback("cl_draw_grass", "ms_grass")
cvars.AddChangeCallback("cl_draw_grass", apply, "ms_grass")
cvars.RemoveChangeCallback("cl_draw_grass_distance", "ms_grass")
cvars.AddChangeCallback("cl_draw_grass_distance", setDistance, "ms_grass")
hook.Remove("ShaderMounted", "ms_grass")

-- density and height are baked into the tufts, so leaving winter is a rebuild
hook.Add("TOD_WinterRemoved", "ms_grass", function()
	if not WINTER then return end
	setSeason(false, AUTUMN)
	apply()
end)

hook.Add("TOD_Autumn", "ms_grass", function()
	if WINTER or AUTUMN then return end
	setSeason(false, true)
	if MAT then
		MAT:SetFloat("$c3_y", DRYNESS)
		lastWet = -1
	end
end)

-- the parse needs the map and its materials in, so the first apply waits for
-- the world; on a reload after that point it runs straight away
if LocalPlayer and IsValid(LocalPlayer()) then
	apply()
else
	hook.Add("InitPostEntity", "ms_grass", function()
		hook.Remove("InitPostEntity", "ms_grass")
		apply()
	end)
end
