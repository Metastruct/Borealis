local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

if SERVER then
	if not resource.AddShader then return end

	resource.AddShader("grass_vs30")
	resource.AddShader("grass_ps30")

	return
end

-- Grass tufts on every world surface whose material has a grass surfaceprop.
-- Faces come from the BSP (brushes and displacements, with the painted blend
-- alpha as density), tufts are generated per 512 unit chunk around the eye
-- inside a per-frame budget, and drawn as analytic blades by grass_ps30.

local GRASS_ENABLED = CreateClientConVar("cl_draw_grass", "0", true, false, "draw grass tufts on grass surfaces")

local CHUNK = 512 -- world units per chunk
local SPACING = 18 -- tuft grid spacing
local JITTER = 8
local RADIUS = 3072 -- chunks kept and drawn within this distance
local FADE_START, FADE_END = 2200, 3000
local QUAD_W, QUAD_H = 26, 40 -- quad size at height scale 1
local MAX_SLOPE_Z = 0.7 -- skip faces steeper than this normal z
local WIND_ANGLE = math.atan2(0.6, 0.8)
local WIND = 0.45 -- bend at the tip, in quad widths
local TRANSLUCENCY = 0.35
local DRYNESS = 0.15 -- 0 green .. 1 golden
-- linear albedo, from gm_construct/grass1's average (0.061, 0.077, 0.020):
-- tips 2.5x the ground, roots 1x
local ROOT_COLOR = { 0.06, 0.075, 0.02 }
local TIP_COLOR = { 0.15, 0.19, 0.05 }
local DRY_COLOR = { 0.24, 0.21, 0.09 } -- tip colour of dry blades
local FILL_K = 0.5 -- ambient cube share added as fill light, not scaled by tod's light style
local BUILD_BUDGET_MS = 3 -- generation work per frame
local LOAD_BUDGET_MS = 8 -- BSP parse work per frame
local MESH_BATCH = 60 -- tufts per IMesh
local TRI_CELL = 1024 -- triangle index cell size

--------------------------------------------------------------------------
-- BSP: grass triangles with per-vertex blend alpha (0 = grass, 255 = other),
-- indexed by TRI_CELL grid cell.  Parsed in a coroutine over several frames.
--------------------------------------------------------------------------
local tris, triGrid

-- little-endian decoders over lump strings (1-based positions)
local byte = string.byte
local function u16(s, pos)
	local b1, b2 = byte(s, pos, pos + 1)

	return b2 * 256 + b1
end

local function i16(s, pos)
	local v = u16(s, pos)

	return v >= 32768 and v - 65536 or v
end

local function i32(s, pos)
	local b1, b2, b3, b4 = byte(s, pos, pos + 3)
	local v = ((b4 * 256 + b3) * 256 + b2) * 256 + b1

	return v >= 2147483648 and v - 4294967296 or v
end

local function f32(s, pos)
	local b1, b2, b3, b4 = byte(s, pos, pos + 3)
	local sign = b4 >= 128 and -1 or 1
	local exp = (b4 % 128) * 2 + math.floor(b3 / 128)
	local mant = ((b3 % 128) * 256 + b2) * 256 + b1
	if exp == 0 then return sign * mant * 2 ^ -149 end
	if exp == 255 then return mant == 0 and sign * math.huge or 0 end

	return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
end

local function addTri(ax, ay, az, bx, by, bz, cx, cy, cz, aa, ab, ac)
	local minx, miny, maxx, maxy = math.min(ax, bx, cx), math.min(ay, by, cy), math.max(ax, bx, cx), math.max(ay, by, cy)
	local t = { ax, ay, az, bx, by, bz, cx, cy, cz, aa, ab, ac, minx, miny, maxx, maxy }
	tris[#tris + 1] = t
	for gy = math.floor(miny / TRI_CELL), math.floor(maxy / TRI_CELL) do
		for gx = math.floor(minx / TRI_CELL), math.floor(maxx / TRI_CELL) do
			local key = gx .. ":" .. gy
			local cell = triGrid[key]
			if not cell then
				cell = {}
				triGrid[key] = cell
			end

			cell[#cell + 1] = t
		end
	end
end

-- displacement grid: the face is a quad, corner order starts at startPosition,
-- disp verts run column-major relative to that order (verified against traces)
local function addDisplacement(px, py, pz, dispinfo, dispverts, di, alphaFor)
	local dp = di * 176 + 1
	local sx, sy, sz = f32(dispinfo, dp), f32(dispinfo, dp + 4), f32(dispinfo, dp + 8)
	local vertStart = i32(dispinfo, dp + 12)
	local power = i32(dispinfo, dp + 20)
	local n = 2 ^ power + 1

	local best, bestD = 1, math.huge
	for c = 1, 4 do
		local d = (px[c] - sx) ^ 2 + (py[c] - sy) ^ 2 + (pz[c] - sz) ^ 2
		if d < bestD then best, bestD = c, d end
	end

	local cx, cy, cz = {}, {}, {}
	for c = 0, 3 do
		local corner = (best - 1 + c) % 4 + 1
		cx[c], cy[c], cz[c] = px[corner], py[corner], pz[corner]
	end

	local gx, gy, gz, ga = {}, {}, {}, {}
	for r = 0, n - 1 do
		local tr = r / (n - 1)
		local ax, ay, az = cx[0] + (cx[3] - cx[0]) * tr, cy[0] + (cy[3] - cy[0]) * tr, cz[0] + (cz[3] - cz[0]) * tr
		local bx, by, bz = cx[1] + (cx[2] - cx[1]) * tr, cy[1] + (cy[2] - cy[1]) * tr, cz[1] + (cz[2] - cz[1]) * tr
		for c = 0, n - 1 do
			local tc = c / (n - 1)
			local idx = r * n + c
			local vp = (vertStart + c * n + r) * 20 + 1
			local dx, dy, dz, dist, alpha = f32(dispverts, vp), f32(dispverts, vp + 4), f32(dispverts, vp + 8), f32(dispverts, vp + 12), f32(dispverts, vp + 16)
			gx[idx] = ax + (bx - ax) * tc + dx * dist
			gy[idx] = ay + (by - ay) * tc + dy * dist
			gz[idx] = az + (bz - az) * tc + dz * dist
			ga[idx] = alphaFor(alpha)
		end
	end

	for r = 0, n - 2 do
		for c = 0, n - 2 do
			local i00, i01, i10, i11 = r * n + c, r * n + c + 1, (r + 1) * n + c, (r + 1) * n + c + 1
			if (r + c) % 2 == 0 then
				addTri(gx[i00], gy[i00], gz[i00], gx[i10], gy[i10], gz[i10], gx[i11], gy[i11], gz[i11], ga[i00], ga[i10], ga[i11])
				addTri(gx[i00], gy[i00], gz[i00], gx[i11], gy[i11], gz[i11], gx[i01], gy[i01], gz[i01], ga[i00], ga[i11], ga[i01])
			else
				addTri(gx[i00], gy[i00], gz[i00], gx[i10], gy[i10], gz[i10], gx[i01], gy[i01], gz[i01], ga[i00], ga[i10], ga[i01])
				addTri(gx[i10], gy[i10], gz[i10], gx[i11], gy[i11], gz[i11], gx[i01], gy[i01], gz[i01], ga[i10], ga[i11], ga[i01])
			end
		end
	end
end

local function loadGrassTriangles()
	local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
	if not f then return false end

	local function lump(i)
		f:Seek(8 + i * 16)
		local ofs, len = f:ReadLong(), f:ReadLong()
		f:Seek(ofs)

		return f:Read(len) or "", len
	end

	local strData = lump(43)
	local strTable, stLen = lump(44)
	local texdataL, tdLen = lump(2)
	local texinfoL, tiLen = lump(6)
	local faces, faLen = lump(7)
	local dispinfo = lump(26)
	local dispverts = lump(33)
	local verts = lump(3)
	local edges = lump(12)
	local surfedges = lump(13)
	local planes = lump(1)
	f:Close()

	local sliceStart = SysTime()
	local function breathe()
		if (SysTime() - sliceStart) * 1000 > LOAD_BUDGET_MS then
			coroutine.yield()
			sliceStart = SysTime()
		end
	end

	local names = {}
	for i = 0, stLen / 4 - 1 do
		names[i] = string.match(strData, "^[^%z]*", i32(strTable, i * 4 + 1) + 1)
	end

	local texdata = {}
	for i = 0, tdLen / 32 - 1 do
		texdata[i] = names[i32(texdataL, i * 32 + 13)]
	end

	local texinfo = {}
	for i = 0, tiLen / 72 - 1 do
		texinfo[i] = i32(texinfoL, i * 72 + 69)
	end

	-- grass mode per texdata: 1 = whole surface, 2 = where blend alpha is low, 3 = where it is high
	local grassMode = {}
	local seen = 0
	for i, name in pairs(texdata) do
		local mat = Material(name)
		local sp = (mat:GetString("$surfaceprop") or ""):lower()
		local sp2 = (mat:GetString("$surfaceprop2") or ""):lower()
		if sp == "grass" and (sp2 == "" or sp2 == "grass") then
			grassMode[i] = 1
		elseif sp == "grass" then
			grassMode[i] = 2
		elseif sp2 == "grass" then
			grassMode[i] = 3
		end

		seen = seen + 1
		if seen % 50 == 0 then breathe() end
	end

	local function vertex(idx)
		local p = idx * 12 + 1

		return f32(verts, p), f32(verts, p + 4), f32(verts, p + 8)
	end

	for i = 0, faLen / 56 - 1 do
		if i % 512 == 0 then breathe() end
		local fp = i * 56 + 1
		local ti = i16(faces, fp + 10)
		local mode = texinfo[ti] and grassMode[texinfo[ti]]
		if mode and f32(planes, u16(faces, fp) * 20 + 9) >= MAX_SLOPE_Z then
			local firstedge, numedges, di = i32(faces, fp + 4), i16(faces, fp + 8), i16(faces, fp + 12)
			local px, py, pz = {}, {}, {}
			for e = 0, numedges - 1 do
				local se = i32(surfedges, (firstedge + e) * 4 + 1)
				local vi = u16(edges, math.abs(se) * 4 + 1 + (se < 0 and 2 or 0))
				px[e + 1], py[e + 1], pz[e + 1] = vertex(vi)
			end

			if di == -1 then
				for e = 2, numedges - 1 do
					addTri(px[1], py[1], pz[1], px[e], py[e], pz[e], px[e + 1], py[e + 1], pz[e + 1], 0, 0, 0)
				end
			elseif numedges == 4 then
				addDisplacement(px, py, pz, dispinfo, dispverts, di, function(a)
					return mode == 1 and 0 or (mode == 2 and a or 255 - a)
				end)
				breathe()
			end
		end
	end

	return true
end

--------------------------------------------------------------------------
-- chunks
--------------------------------------------------------------------------
local chunks -- key -> { cx, cy, mesh = {IMesh}|false|nil, tufts }
local tuftCache -- key -> tuft list, or false when empty, of evicted chunks
local buildQueue
local current -- chunk being generated

local function chunkKey(cx, cy)
	return cx .. ":" .. cy
end

-- point (x, y) against triangle t: z and blend alpha when inside
local function sample(t, x, y)
	local ax, ay, bx, by, cx, cy = t[1], t[2], t[4], t[5], t[7], t[8]
	local v0x, v0y = cx - ax, cy - ay
	local v1x, v1y = bx - ax, by - ay
	local v2x, v2y = x - ax, y - ay
	local d00 = v0x * v0x + v0y * v0y
	local d01 = v0x * v1x + v0y * v1y
	local d11 = v1x * v1x + v1y * v1y
	local d20 = v2x * v0x + v2y * v0y
	local d21 = v2x * v1x + v2y * v1y
	local denom = d00 * d11 - d01 * d01
	if math.abs(denom) < 1e-6 then return nil end
	local wc = (d11 * d20 - d01 * d21) / denom
	local wb = (d00 * d21 - d01 * d20) / denom
	local wa = 1 - wb - wc
	if wa < -0.001 or wb < -0.001 or wc < -0.001 then return nil end

	return wa * t[3] + wb * t[6] + wc * t[9], wa * t[10] + wb * t[11] + wc * t[12]
end

-- triangles overlapping a chunk, from the grid index
local function candidates(x0, y0, x1, y1)
	local cand, seen = {}, {}
	for gy = math.floor(y0 / TRI_CELL), math.floor(y1 / TRI_CELL) do
		for gx = math.floor(x0 / TRI_CELL), math.floor(x1 / TRI_CELL) do
			local cell = triGrid[gx .. ":" .. gy]
			if cell then
				for _, t in ipairs(cell) do
					if not seen[t] and t[15] >= x0 and t[13] <= x1 and t[16] >= y0 and t[14] <= y1 then
						seen[t] = true
						cand[#cand + 1] = t
					end
				end
			end
		end
	end

	return cand
end

local UP = Vector(0, 0, 1)
local traceStart, traceEnd, lightPos = Vector(0, 0, 0), Vector(0, 0, 0), Vector(0, 0, 0)
local coverTrace = { mask = MASK_SOLID_BRUSHONLY, start = traceStart, endpos = traceEnd }

-- more generation work when the frame has headroom, less when it is already slow
local lastThinkMs = 0
local function budget()
	return math.Clamp(16 - RealFrameTime() * 1000 + lastThinkMs, BUILD_BUDGET_MS * 0.7, BUILD_BUDGET_MS * 2)
end

-- rasterises the chunk into a tuft list, yielding when the frame budget is spent
local function rasterChunk(ch, cand)
	local x0, y0 = ch.cx * CHUNK, ch.cy * CHUNK
	local x1, y1 = x0 + CHUNK, y0 + CHUNK
	local tufts = {}
	local rng = ch.cx * 73856093 + ch.cy * 19349663
	local function rand()
		rng = (rng * 1103515245 + 12345) % 2147483648

		return rng / 2147483648
	end

	local lightCache = {} -- one lighting sample per 2x2 cells, lightmap luxels are ~16 units
	local sliceStart = SysTime()
	for gy = y0, y1 - 1, SPACING do
		if (SysTime() - sliceStart) * 1000 > budget() then
			coroutine.yield()
			sliceStart = SysTime()
		end

		for gx = x0, x1 - 1, SPACING do
			local x = gx + SPACING * 0.5 + (rand() - 0.5) * 2 * JITTER
			local y = gy + SPACING * 0.5 + (rand() - 0.5) * 2 * JITTER
			local seed, r3, r4 = rand(), rand(), rand()
			for _, t in ipairs(cand) do
				if x >= t[13] and x <= t[15] and y >= t[14] and y <= t[16] then
					local z, alpha = sample(t, x, y)
					if z and r3 * 255 > alpha then
						-- skip tufts under floors, roofs and other covering brushes
						traceStart:SetUnpacked(x, y, z + QUAD_H + 2)
						traceEnd:SetUnpacked(x, y, z + 1)
						if not util.TraceLine(coverTrace).Hit then
							local lkey = math.floor(x / (SPACING * 2)) * 4096 + math.floor(y / (SPACING * 2))
							local light = lightCache[lkey]
							if not light then
								lightPos:SetUnpacked(x, y, z + 12)
								light = render.ComputeLighting(lightPos, UP)
								lightCache[lkey] = light
							end

							-- mostly tall, some short
							tufts[#tufts + 1] = { x, y, z, seed, 0.5 + r4 * r4 * 0.9, light }
						end
					end
				end
			end
		end
	end

	return tufts
end

local COS60, SIN60 = math.cos(math.rad(60)), math.sin(math.rad(60))
local DIRS = { { 1, 0 }, { COS60, SIN60 }, { -COS60, SIN60 } } -- three crossed quads per tuft
local vpos = Vector(0, 0, 0)

-- one IMesh for tufts[first .. last].  screenspace_general binds position,
-- colour and texcoord 0 only: colour rgb = light / 2, colour a = seed,
-- uv.x = blade u + 2 * height index
local function buildMesh(tufts, first, last)
	local m = Mesh()
	mesh.Begin(m, MATERIAL_QUADS, (last - first + 1) * #DIRS)
	for i = first, last do
		local tf = tufts[i]
		local x, y, z, seed, hs, light = tf[1], tf[2], tf[3] + 0.5, tf[4], tf[5], tf[6]
		local r = math.Clamp(math.floor(light.x * 127.5), 0, 255)
		local g = math.Clamp(math.floor(light.y * 127.5), 0, 255)
		local b = math.Clamp(math.floor(light.z * 127.5), 0, 255)
		local a = math.floor(seed * 255)
		local hIndex = math.Clamp(math.floor((hs - 0.5) / 0.9 * 7 + 0.5), 0, 7)
		hs = 0.5 + hIndex / 7 * 0.9
		local h = QUAD_H * hs
		local w = QUAD_W * (0.7 + 0.3 * hs) * 0.5
		local rot = seed * math.pi
		local cr, sr = math.cos(rot), math.sin(rot)
		local u0 = hIndex * 2
		local function vert(px, py, pz, u, v)
			vpos:SetUnpacked(px, py, pz)
			mesh.Position(vpos)
			mesh.TexCoord(0, u, v)
			mesh.Color(r, g, b, a)
			mesh.AdvanceVertex()
		end

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

	return m
end

local function destroyMeshes(ch)
	if not ch.mesh then return end
	for _, m in ipairs(ch.mesh) do
		m:Destroy()
	end
end

-- picks the next queued chunk: nearest first, chunks in front of the camera before the rest
local function nextChunk()
	local eye, fwd = EyePos(), EyeAngles():Forward()
	for _, ch in ipairs(buildQueue) do
		local dx, dy = ch.cx * CHUNK + CHUNK * 0.5 - eye.x, ch.cy * CHUNK + CHUNK * 0.5 - eye.y
		local dist = math.sqrt(dx * dx + dy * dy)
		local behind = dist > CHUNK and (dx * fwd.x + dy * fwd.y) / dist < -0.35
		ch.prio = dist + (behind and RADIUS or 0)
	end

	table.sort(buildQueue, function(a, b) return a.prio < b.prio end)
	local ch = table.remove(buildQueue, 1)
	local key = chunkKey(ch.cx, ch.cy)
	if ch.mesh ~= nil or chunks[key] ~= ch then return end

	local cached = tuftCache[key]
	if cached == false then
		ch.mesh, ch.tufts = false, 0
	elseif cached then
		ch.pendingTufts, ch.nextTuft, ch.meshes = cached, 1, {}
		current = ch
	else
		local x0, y0 = ch.cx * CHUNK, ch.cy * CHUNK
		local cand = candidates(x0, y0, x0 + CHUNK, y0 + CHUNK)
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
		local first = ch.nextTuft
		local last = math.min(first + MESH_BATCH - 1, #tufts)
		ch.meshes[#ch.meshes + 1] = buildMesh(tufts, first, last)
		if last >= #tufts then
			ch.tufts = #tufts
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
		end
	else
		return false -- budget spent inside the raster
	end

	return true
end

--------------------------------------------------------------------------
-- rendering
--------------------------------------------------------------------------
local MAT
local loader -- BSP parse coroutine
local ready = false

local function packColor(c)
	return math.floor(math.Clamp(c[1], 0, 1) * 255) * 65536 + math.floor(math.Clamp(c[2], 0, 1) * 255) * 256 + math.floor(math.Clamp(c[3], 0, 1) * 255)
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
		local ok, err = coroutine.resume(loader)
		if not ok then
			ErrorNoHalt("[grass] bsp parse failed: " .. tostring(err) .. "\n")
			hook.Remove("Think", "ms_grass")
			return
		end

		ready = coroutine.status(loader) == "dead"
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

local evictNext = 0
local function draw(_, _, sky3d)
	if not ready or sky3d or render.GetRenderTarget() then return end
	local eye = EyePos()
	local fwd = EyeAngles():Forward()
	local amb = render.GetAmbientLightColor()

	MAT:SetFloat("$c0_x", eye.x)
	MAT:SetFloat("$c0_y", eye.y)
	MAT:SetFloat("$c0_z", eye.z)
	MAT:SetFloat("$c0_w", CurTime() % 1000)
	MAT:SetFloat("$c1_y", packColor({ amb.x * FILL_K, amb.y * FILL_K, amb.z * FILL_K }))
	MAT:SetFloat("$c2_x", worldLightScale())
	MAT:SetFloat("$c2_w", render.GetToneMappingScaleLinear().x)
	render.SetMaterial(MAT)

	local n = math.ceil(RADIUS / CHUNK)
	local ecx, ecy = math.floor(eye.x / CHUNK), math.floor(eye.y / CHUNK)
	local half = CHUNK * 0.5
	local visible = {}
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
				elseif ch.mesh and (dist < CHUNK or (ddx * fwd.x + ddy * fwd.y) / dist > -0.35) then
					ch.drawDist = dist
					visible[#visible + 1] = ch
				end
			end
		end
	end

	-- the material tests depth but does not write it; force both, near to far
	table.sort(visible, function(a, b) return a.drawDist < b.drawDist end)
	render.OverrideDepthEnable(true, true)
	for _, ch in ipairs(visible) do
		for _, m in ipairs(ch.mesh) do
			m:Draw()
		end
	end

	render.OverrideDepthEnable(false, false)

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

local function stop()
	hook.Remove("Think", "ms_grass")
	hook.Remove("PostDrawOpaqueRenderables", "ms_grass")
	if chunks then
		for _, ch in pairs(chunks) do
			destroyMeshes(ch)
		end
	end

	chunks, tuftCache, buildQueue, current = nil, nil, nil, nil
	tris, triGrid, loader, ready = nil, nil, nil, false
end

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
		["$c2_x"] = 1, ["$c2_y"] = packColor(ROOT_COLOR), ["$c2_z"] = packColor(TIP_COLOR), ["$c2_w"] = 1,
		["$c3_x"] = TRANSLUCENCY, ["$c3_y"] = DRYNESS, ["$c3_z"] = packColor(DRY_COLOR), ["$c3_w"] = FADE_END,
	})

	tris, triGrid = {}, {}
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
hook.Remove("ShaderMounted", "ms_grass")

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
