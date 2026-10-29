local PS, VS, DEPTH_PS, STAMP_PS = "snowcover_ps30", "water_vs30", "waterdepth_ps30", "snowstamp_ps30"
local NOISE = "shaderpack/procsky/fognoise"
local SHADERS = { PS, VS, DEPTH_PS, STAMP_PS }

if SERVER then
	shaderpack.AddResources(SHADERS, { NOISE })

	return
end

local bspdata, depthslices, foliage = shaderpack.bspdata, shaderpack.depthslices, shaderpack.foliage
local ENABLED = CreateClientConVar("cl_draw_snowcover", "1", true, false, "draw deep snow with footprints on snowy ground in winter")

local DEPTH = 10
local CHUNK, CELL = 512, 32
local MIN_NZ = 0.6
local RADIUS = 3072
local FADE_START, FADE_END = RADIUS * 0.75, RADIUS * 0.95
local MESH_TRIS = 10000
local MESH_CACHE_TRIS = jit.arch == "x64" and math.huge or 300000
local BUILD_BUDGET_MS = 2
local SKY_REACH = 16384
local SKY_CELL, LIGHT_CELL, CLUSTER_CELL = 16, 16, 64
local SMALL_TRI = CELL * 2
local SKIRT_DROP = 1
local FILL_K = 0.5
local SNOWY = { "grass", "mud", "sand", "snow" }
local NOT_SNOWY = { "water", "gm_flatgrass" }

local TRAIL_TEXELS, TRAIL_SPAN = 1024, 2048
local TEXEL = TRAIL_SPAN / TRAIL_TEXELS
local TRAIL_STEP = 128
local REFILL_INTERVAL = 1
local SETTLE_TIME, SNOWFALL_TIME = 1200, 120
local CAPTURE_PAD = 4
local CAPTURE_HEIGHT = 4096
local GATHER_INTERVAL = 0.25
local RESTAMP_INTERVAL = 1

local setConstant, packColor, toLinear = shaderpack.SetConstant, shaderpack.PackColor, shaderpack.ToLinear

local function snowy(name)
	if not name then return false end
	local lower = name:lower()
	for _, s in ipairs(NOT_SNOWY) do
		if lower:find(s, 1, true) then return false end
	end

	for _, s in ipairs(SNOWY) do
		if lower:find(s, 1, true) then return true end
	end

	return false
end

local function classify(name)
	if not snowy(name) then return end
	local base2 = Material(name):GetString("$basetexture2")

	return (not base2 or snowy(base2)) and 1 or 2
end

local function chunkKey(cx, cy)
	return cx * 65536 + cy
end

local function triNormal(t)
	local ux, uy, uz = t[4] - t[1], t[5] - t[2], t[6] - t[3]
	local vx, vy, vz = t[7] - t[1], t[8] - t[2], t[9] - t[3]
	local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
	local len = math.sqrt(nx * nx + ny * ny + nz * nz)
	if len < 1e-6 then return 0, 0, 0 end
	if nz < 0 then len = -len end

	return nx / len, ny / len, nz / len
end

local function vertexKey(x, y, z)
	return math.floor(x * 8 + 0.5) .. "," .. math.floor(y * 8 + 0.5) .. "," .. math.floor(z * 8 + 0.5)
end

local triGrid, edgeGrid

local function skyboxPVS()
	local f, lump = bspdata.OpenLumps()
	if not f then return end

	local entities = lump(0)
	f:Close()
	for block in entities:gmatch("%b{}") do
		if block:find("\"classname\" \"sky_camera\"", 1, true) then
			local x, y, z = (block:match("\"origin\" \"([^\"]*)\"") or ""):match("(%S+)%s+(%S+)%s+(%S+)")
			local cluster = x and bspdata.ClusterAt(tonumber(x), tonumber(y), tonumber(z)) or -1

			return cluster >= 0 and bspdata.PVS(cluster) or nil
		end
	end
end

local wetPos = Vector()

local function submerged(x, y, z)
	wetPos:SetUnpacked(x, y, z + 2)

	return bit.band(util.PointContents(wetPos), MASK_WATER) ~= 0
end

local function load()
	local vis, why = bspdata.WaitVis()
	if not vis then return false, why end

	local grid
	grid, why = bspdata.Triangles(classify, MIN_NZ)
	if not grid then return false, why end

	local yieldIfOverBudget = bspdata.FrameBudget()
	local skybox = skyboxPVS()
	local seen, edges, normals, up = {}, {}, {}, {}
	for _, cell in pairs(grid) do
		for _, t in ipairs(cell) do
			if not seen[t] then
				seen[t] = true
				t.nx, t.ny, t.nz = triNormal(t)
				if t.nz >= MIN_NZ and skybox then
					local c = bspdata.ClusterAt((t[1] + t[4] + t[7]) / 3, (t[2] + t[5] + t[8]) / 3, (t[3] + t[6] + t[9]) / 3 + DEPTH + 4)
					if c >= 0 and skybox[c] then t.nz = 0 end
				end

				if t.nz >= MIN_NZ and submerged(t[1], t[2], t[3]) and submerged(t[4], t[5], t[6]) and submerged(t[7], t[8], t[9]) then
					t.nz = 0
				end

				if t.nz >= MIN_NZ then
					local keys = { vertexKey(t[1], t[2], t[3]), vertexKey(t[4], t[5], t[6]), vertexKey(t[7], t[8], t[9]) }
					t.keys = keys
					up[#up + 1] = t
					for _, k in ipairs(keys) do
						local sum = normals[k]
						if not sum then
							sum = { 0, 0, 0 }
							normals[k] = sum
						end

						sum[1], sum[2], sum[3] = sum[1] + t.nx, sum[2] + t.ny, sum[3] + t.nz
					end

					for e = 1, 3 do
						local ka, kb = keys[e], keys[e % 3 + 1]
						local key = ka < kb and ka .. "|" .. kb or kb .. "|" .. ka
						if edges[key] == nil then
							edges[key] = { t, e }
						else
							edges[key] = false
						end
					end
				end

				yieldIfOverBudget()
			end
		end
	end

	for _, t in ipairs(up) do
		local vn = {}
		for i, k in ipairs(t.keys) do
			local sum = normals[k]
			local len = math.sqrt(sum[1] * sum[1] + sum[2] * sum[2] + sum[3] * sum[3])
			vn[i * 2 - 1], vn[i * 2] = sum[1] / len, sum[2] / len
		end

		t.vn, t.keys = vn, nil
		yieldIfOverBudget()
	end

	local egrid = {}
	for _, rec in pairs(edges) do
		if rec then
			local t, e = rec[1], rec[2]
			local ia, ib, ic = (e - 1) * 3, (e % 3) * 3, ((e + 1) % 3) * 3
			local ax, ay, az, bx, by, bz = t[ia + 1], t[ia + 2], t[ia + 3], t[ib + 1], t[ib + 2], t[ib + 3]
			local ox, oy = by - ay, ax - bx
			local len = math.sqrt(ox * ox + oy * oy)
			if len > 1e-3 then
				ox, oy = ox / len, oy / len
				if (t[ic + 1] - ax) * ox + (t[ic + 2] - ay) * oy > 0 then ox, oy = -ox, -oy end

				local edge = { ax, ay, az, t[10 + (e - 1)], bx, by, bz, t[10 + e % 3], ox, oy }
				for cy = math.floor(math.min(ay, by) / CHUNK), math.floor(math.max(ay, by) / CHUNK) do
					for cx = math.floor(math.min(ax, bx) / CHUNK), math.floor(math.max(ax, bx) / CHUNK) do
						local key = chunkKey(cx, cy)
						local list = egrid[key]
						if not list then
							list = {}
							egrid[key] = list
						end

						list[#list + 1] = edge
					end
				end
			end
		end

		yieldIfOverBudget()
	end

	triGrid, edgeGrid = grid, egrid

	return true
end

local UP = Vector(0, 0, 1)
local probePos = Vector()
local skyTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = {} }

local function cellKey(x, y, z, size)
	return (math.floor(x / size) + 4096) * 67108864 + (math.floor(y / size) + 4096) * 8192 + math.floor(z / size) + 4096
end

local function snowAt(x, y, z, nonSnow, cache)
	local cover = 1 - nonSnow / 255
	if cover <= 0 then return 0, 0 end

	local skyKey = cellKey(x, y, z, SKY_CELL)
	local open = cache.sky[skyKey]
	if open == nil then
		skyTrace.start:SetUnpacked(x, y, z + 4)
		skyTrace.endpos:SetUnpacked(x, y, z + SKY_REACH)
		local tr = util.TraceLine(skyTrace)
		probePos:SetUnpacked(x, y, z + 2)
		open = (not tr.Hit or tr.HitSky) and not tr.StartSolid and bit.band(util.PointContents(probePos), MASK_WATER) == 0
		cache.sky[skyKey] = open
	end

	if not open then return 0, 0 end

	local lightKey = cellKey(x, y, z, LIGHT_CELL)
	local light = cache.light[lightKey]
	if not light then
		probePos:SetUnpacked(x, y, z + DEPTH + 2)
		local l = render.ComputeLighting(probePos, UP)
		light = math.Clamp(math.floor(l.x * 127.5), 0, 255) * 65536 + math.Clamp(math.floor(l.y * 127.5), 0, 255) * 256 + math.Clamp(math.floor(l.z * 127.5), 0, 255)
		cache.light[lightKey] = light
	end

	return cover, light
end

local function clipPoly(poly, axis, value, sign)
	local out = {}
	local n = #poly
	for i = 1, n do
		local a, b = poly[i], poly[i % n + 1]
		local da, db = (a[axis] - value) * sign, (b[axis] - value) * sign
		if da >= 0 then out[#out + 1] = a end
		if (da >= 0) ~= (db >= 0) then
			local f = da / (da - db)
			local v = {}
			for k = 1, #a do
				v[k] = a[k] + (b[k] - a[k]) * f
			end
			out[#out + 1] = v
		end
	end

	return out
end

local STRIDE = 7

local function buildChunk(ch)
	local x0, y0 = ch.cx * CHUNK, ch.cy * CHUNK
	local x1, y1 = x0 + CHUNK, y0 + CHUNK
	local cand = bspdata.Candidates(triGrid, x0, y0, x1, y1)
	local verts, n = {}, 0
	local cache = { sky = {}, light = {}, cluster = {} }
	local clusters, clusterSet = {}, {}
	local zmin, zmax = math.huge, -math.huge
	local sliceStart = SysTime()

	local function budget()
		if (SysTime() - sliceStart) * 1000 > BUILD_BUDGET_MS then
			coroutine.yield()
			sliceStart = SysTime()
		end
	end

	local function emit(x, y, z, nx, ny, cover, light)
		verts[n + 1], verts[n + 2], verts[n + 3], verts[n + 4], verts[n + 5], verts[n + 6], verts[n + 7] = x, y, z, nx, ny, light, cover
		n = n + STRIDE
		if z < zmin then zmin = z end
		if z > zmax then zmax = z end
	end

	local function addCluster(x, y, z)
		local key = cellKey(x, y, z, CLUSTER_CELL)
		if cache.cluster[key] then return end
		cache.cluster[key] = true

		local c = bspdata.ClusterAt(x, y, z + DEPTH + 4)
		if c >= 0 and not clusterSet[c] then
			clusterSet[c] = true
			clusters[#clusters + 1] = c
		end
	end

	local function emitTri(poly, i1, i2, i3)
		local a, b, c = poly[i1], poly[i2], poly[i3]
		local ca, la = snowAt(a[1], a[2], a[3], a[4], cache)
		local cb, lb = snowAt(b[1], b[2], b[3], b[4], cache)
		local cc, lc = snowAt(c[1], c[2], c[3], c[4], cache)
		if ca + cb + cc <= 0 then return false end

		emit(a[1], a[2], a[3] + ca * DEPTH, a[5], a[6], ca, la)
		emit(b[1], b[2], b[3] + cb * DEPTH, b[5], b[6], cb, lb)
		emit(c[1], c[2], c[3] + cc * DEPTH, c[5], c[6], cc, lc)

		return true
	end

	for _, t in ipairs(cand) do
		if t.vn then
			local vn = t.vn
			local tri = { { t[1], t[2], t[3], t[10], vn[1], vn[2] }, { t[4], t[5], t[6], t[11], vn[3], vn[4] }, { t[7], t[8], t[9], t[12], vn[5], vn[6] } }
			if t[15] - t[13] <= SMALL_TRI and t[16] - t[14] <= SMALL_TRI then
				local mx, my = (t[1] + t[4] + t[7]) / 3, (t[2] + t[5] + t[8]) / 3
				if mx >= x0 and mx < x1 and my >= y0 and my < y1 and emitTri(tri, 1, 2, 3) then
					addCluster(mx, my, t[3])
				end

				budget()
			else
				local ix0 = math.floor(math.max(t[13], x0) / CELL)
				local ix1 = math.floor((math.min(t[15], x1) - 1e-3) / CELL)
				local iy0 = math.floor(math.max(t[14], y0) / CELL)
				local iy1 = math.floor((math.min(t[16], y1) - 1e-3) / CELL)
				for iy = iy0, iy1 do
					for ix = ix0, ix1 do
						local cx0, cy0 = ix * CELL, iy * CELL
						local poly = clipPoly(tri, 1, cx0, 1)
						if #poly >= 3 then poly = clipPoly(poly, 1, cx0 + CELL, -1) end
						if #poly >= 3 then poly = clipPoly(poly, 2, cy0, 1) end
						if #poly >= 3 then poly = clipPoly(poly, 2, cy0 + CELL, -1) end

						local any = false
						for k = 2, #poly - 1 do
							any = emitTri(poly, 1, k, k + 1) or any
						end

						if any then addCluster(poly[1][1], poly[1][2], poly[1][3]) end
						budget()
					end
				end
			end
		end
	end

	for _, e in ipairs(edgeGrid[chunkKey(ch.cx, ch.cy)] or {}) do
		local ax, ay, bx, by = e[1], e[2], e[5], e[6]
		local dx, dy = bx - ax, by - ay
		local ta, tb = 0, 1
		for _, side in ipairs({ { -dx, ax - x0 }, { dx, x1 - ax }, { -dy, ay - y0 }, { dy, y1 - ay } }) do
			local p, q = side[1], side[2]
			if p == 0 then
				if q < 0 then ta, tb = 1, 0 end
			else
				local r = q / p
				if p < 0 then ta = math.max(ta, r) else tb = math.min(tb, r) end
			end
		end

		if tb > ta then
			local pieces = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) * (tb - ta) / CELL))
			local function at(f)
				return ax + dx * f, ay + dy * f, e[3] + (e[7] - e[3]) * f, e[4] + (e[8] - e[4]) * f
			end

			local px, py, pz, pa = at(ta)
			local pc, pl = snowAt(px, py, pz, pa, cache)
			for k = 1, pieces do
				local qx, qy, qz, qa = at(ta + (tb - ta) * k / pieces)
				local qc, ql = snowAt(qx, qy, qz, qa, cache)
				if pc + qc > 0 then
					emit(px, py, pz + pc * DEPTH, e[9], e[10], pc, pl)
					emit(qx, qy, qz + qc * DEPTH, e[9], e[10], qc, ql)
					emit(qx, qy, qz - SKIRT_DROP, e[9], e[10], 0, ql)
					emit(px, py, pz + pc * DEPTH, e[9], e[10], pc, pl)
					emit(qx, qy, qz - SKIRT_DROP, e[9], e[10], 0, ql)
					emit(px, py, pz - SKIRT_DROP, e[9], e[10], 0, pl)
				end

				px, py, pz, pc, pl = qx, qy, qz, qc, ql
			end
		end

		budget()
	end

	ch.clusters = clusters
	ch.cz = (zmin + zmax) * 0.5
	local hz = (zmax - zmin) * 0.5
	ch.radius = math.sqrt(CHUNK * CHUNK * 0.5 + hz * hz)

	return verts, n / STRIDE / 3
end

local vpos = Vector()

local function buildMeshes(verts, tris)
	local meshes = {}
	local o = 0
	while tris > 0 do
		local count = math.min(tris, MESH_TRIS)
		local m = Mesh()
		mesh.Begin(m, MATERIAL_TRIANGLES, count)
		for _ = 1, count * 3 do
			local light = verts[o + 6]
			vpos:SetUnpacked(verts[o + 1], verts[o + 2], verts[o + 3])
			mesh.Position(vpos)
			mesh.TexCoord(0, verts[o + 4], verts[o + 5])
			mesh.Color(math.floor(light / 65536), math.floor(light / 256) % 256, light % 256, math.floor(verts[o + 7] * 255 + 0.5))
			mesh.AdvanceVertex()
			o = o + STRIDE
		end
		mesh.End()
		meshes[#meshes + 1] = m
		tris = tris - count
	end

	return meshes
end

local chunks, queue, current, loader, ready = {}, {}, nil, nil, false

local function destroyChunk(ch)
	for _, m in ipairs(ch.meshes or {}) do
		m:Destroy()
	end
	ch.meshes = nil
end

local function think()
	local t0 = SysTime()
	if not ready then
		local ok, res, why = coroutine.resume(loader)
		if not ok or (coroutine.status(loader) == "dead" and not res) then
			ErrorNoHalt("[snowcover] off: " .. tostring(ok and why or res) .. "\n")
			loader = nil
			hook.Remove("Think", "ms_snowcover")

			return
		end

		ready = coroutine.status(loader) == "dead"

		return
	end

	while (SysTime() - t0) * 1000 < BUILD_BUDGET_MS do
		if not current then
			local eye = EyePos()
			local best, bestDist
			for i, ch in ipairs(queue) do
				local dx, dy = ch.cx * CHUNK + CHUNK * 0.5 - eye.x, ch.cy * CHUNK + CHUNK * 0.5 - eye.y
				local d = dx * dx + dy * dy
				if not bestDist or d < bestDist then best, bestDist = i, d end
			end

			if not best then break end
			current = table.remove(queue, best)
			if chunks[chunkKey(current.cx, current.cy)] ~= current then
				current = nil
			else
				current.co = coroutine.create(buildChunk)
			end
		else
			local ok, verts, tris = coroutine.resume(current.co, current)
			if not ok then
				ErrorNoHalt("[snowcover] chunk build failed: " .. tostring(verts) .. "\n")
				current.meshes, current.tris, current.co, current = {}, 0, nil, nil
			elseif coroutine.status(current.co) == "dead" then
				current.meshes = tris > 0 and buildMeshes(verts, tris) or {}
				current.tris = tris
				current.co, current = nil, nil
			else
				break
			end
		end
	end
end

local trailRT, stampRT, winX, winY
local stampMat, blurMat
local capturing = false

local function eachRTRect(X0, Y0, w, h, fn)
	local px, py = X0 % TRAIL_TEXELS, Y0 % TRAIL_TEXELS
	local w1, h1 = math.min(w, TRAIL_TEXELS - px), math.min(h, TRAIL_TEXELS - py)
	fn(px, py, w1, h1, 0, 0)
	if w1 < w then fn(0, py, w - w1, h1, w1, 0) end
	if h1 < h then fn(px, 0, w1, h - h1, 0, h1) end
	if w1 < w and h1 < h then fn(0, 0, w - w1, h - h1, w1, h1) end
end

local function clearRect(px, py, w, h)
	render.SetViewPort(px, py, w, h)
	render.Clear(0, 0, 0, 0)
end

local function recentre(eye)
	local half = TRAIL_TEXELS / 2
	local cx = math.floor(eye.x / TEXEL / TRAIL_STEP + 0.5) * TRAIL_STEP - half
	local cy = math.floor(-eye.y / TEXEL / TRAIL_STEP + 0.5) * TRAIL_STEP - half
	if cx == winX and cy == winY then return end

	render.PushRenderTarget(trailRT)
	if not winX or math.abs(cx - winX) >= TRAIL_TEXELS or math.abs(cy - winY) >= TRAIL_TEXELS then
		render.Clear(0, 0, 0, 0)
	else
		local dx, dy = cx - winX, cy - winY
		if dx > 0 then
			eachRTRect(winX + TRAIL_TEXELS, cy, dx, TRAIL_TEXELS, clearRect)
		elseif dx < 0 then
			eachRTRect(cx, cy, -dx, TRAIL_TEXELS, clearRect)
		end

		if dy > 0 then
			eachRTRect(cx, winY + TRAIL_TEXELS, TRAIL_TEXELS, dy, clearRect)
		elseif dy < 0 then
			eachRTRect(cx, cy, TRAIL_TEXELS, -dy, clearRect)
		end

		render.SetViewPort(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)
	end
	render.PopRenderTarget()
	winX, winY = cx, cy
end

local nextRefill = 0

local function refill()
	local now = RealTime()
	if now < nextRefill then return end
	nextRefill = now + REFILL_INTERVAL

	local snow = tod and tod.snow and tod.snow.amount or 0
	local dec = (1 / SETTLE_TIME + snow / SNOWFALL_TIME) * REFILL_INTERVAL
	local c, err = 1, math.huge
	for v = 1, 255 do
		local e = math.abs(toLinear(v) - dec)
		if e > err then break end
		c, err = v, e
	end

	render.PushRenderTarget(trailRT)
	cam.Start2D()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_REVERSE_SUBTRACT, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
	surface.SetDrawColor(c, c, c, 255)
	surface.DrawRect(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	surface.SetDrawColor(0, 0, 0, 255)
	surface.DrawRect(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)
	render.OverrideBlend(false)
	cam.End2D()
	render.PopRenderTarget()
end

local candidates, nextGather = {}, 0

local function printable(e)
	if not IsValid(e) or e:IsDormant() or e:GetNoDraw() or (e:GetModel() or "") == "" then return false end
	if e:IsPlayer() then return e:Alive() and not e:InVehicle() end

	return e:IsNPC() or e:IsNextBot() or e:IsRagdoll() or e:IsVehicle() or e:GetClass() == "prop_physics"
end

local function gather(eye)
	local now = RealTime()
	if now < nextGather then return end
	nextGather = now + GATHER_INTERVAL

	local half = TRAIL_SPAN / 2
	candidates = {}
	for _, e in ipairs(ents.FindInBox(eye - Vector(half, half, half), eye + Vector(half, half, half))) do
		if printable(e) then candidates[#candidates + 1] = e end
	end
end

local captureView = { type = "3D", origin = Vector(), angles = Angle(90, 90, 0), znear = 1, zfar = CAPTURE_HEIGHT * 2, ortho = {} }
local groundRes = {}
local groundTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = groundRes }
local CLIP_NORMAL = Vector(0, 0, -1)

local stamps = {}
local lastStamp = setmetatable({}, { __mode = "k" })

local function stampRect(e)
	if not printable(e) then return end

	local now = RealTime()
	local pos, ang = e:GetPos(), e:GetAngles()
	local last = lastStamp[e]
	if last and now - last.t < RESTAMP_INTERVAL and last.pos == pos and last.ang == ang then return end

	local mins, maxs = e:WorldSpaceAABB()
	local mx, my = (mins.x + maxs.x) * 0.5, (mins.y + maxs.y) * 0.5
	groundTrace.start:SetUnpacked(mx, my, mins.z + DEPTH)
	groundTrace.endpos:SetUnpacked(mx, my, mins.z - DEPTH * 2)
	util.TraceLine(groundTrace)
	if not groundRes.Hit then return end

	local top = groundRes.HitPos.z + DEPTH
	if mins.z > top then return end

	local X0 = math.max(math.floor(mins.x / TEXEL) - CAPTURE_PAD, winX)
	local X1 = math.min(math.ceil(maxs.x / TEXEL) + CAPTURE_PAD, winX + TRAIL_TEXELS)
	local Y0 = math.max(math.floor(-maxs.y / TEXEL) - CAPTURE_PAD, winY)
	local Y1 = math.min(math.ceil(-mins.y / TEXEL) + CAPTURE_PAD, winY + TRAIL_TEXELS)
	if X1 <= X0 or Y1 <= Y0 then return end

	lastStamp[e] = { t = now, pos = pos, ang = ang }

	return { e = e, top = top, X0 = X0, Y0 = Y0, w = X1 - X0, h = Y1 - Y0 }
end

local function drawStamp(s)
	render.PushCustomClipPlane(CLIP_NORMAL, -s.top)
	eachRTRect(s.X0, s.Y0, s.w, s.h, function(px, py, w, h, ox, oy)
		local hw, hh = w * TEXEL * 0.5, h * TEXEL * 0.5
		captureView.x, captureView.y, captureView.w, captureView.h = px, py, w, h
		captureView.origin:SetUnpacked((s.X0 + ox) * TEXEL + hw, -((s.Y0 + oy) * TEXEL + hh), s.top + CAPTURE_HEIGHT)
		local ortho = captureView.ortho
		ortho.left, ortho.right, ortho.top, ortho.bottom = -hw, hw, -hh, hh
		cam.Start(captureView)
		s.e:DrawModel()
		cam.End()
	end)
	render.PopCustomClipPlane()
end

local function blurRect(px, py, w, h)
	render.SetViewPort(px, py, w, h)
	render.DrawScreenQuad()
end

local function capture()
	local n = 0
	for _, e in ipairs(candidates) do
		local ok, s = pcall(stampRect, e)
		if ok and s then
			n = n + 1
			stamps[n] = s
		end
	end

	for i = #stamps, n + 1, -1 do
		stamps[i] = nil
	end

	if n == 0 then return end

	render.PushRenderTarget(stampRT)
	for i = 1, n do
		local s = stamps[i]
		eachRTRect(s.X0, s.Y0, s.w, s.h, clearRect)
	end
	render.SetViewPort(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)

	render.MaterialOverride(stampMat)
	render.SuppressEngineLighting(true)
	local clipping = render.EnableClipping(true)
	capturing = true
	for i = 1, n do
		local ok, err = pcall(drawStamp, stamps[i])
		if not ok then ErrorNoHalt("[snowcover] capture: " .. tostring(err) .. "\n") end
	end
	capturing = false
	render.EnableClipping(clipping)
	render.SuppressEngineLighting(false)
	render.MaterialOverride()
	render.PopRenderTarget()

	render.PushRenderTarget(trailRT)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	render.SetMaterial(blurMat)
	for i = 1, n do
		local s = stamps[i]
		eachRTRect(s.X0, s.Y0, s.w, s.h, blurRect)
	end
	render.SetViewPort(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)
	render.OverrideBlend(false)
	render.PopRenderTarget()
end

local function prepare()
	if not trailRT then return end

	local eye = EyePos()
	recentre(eye)
	refill()
	gather(eye)
	capture()
end

local MAT, DEPTH_MAT
local materialSerial = 0
local extra = Matrix()

local function skyTint(tonemap)
	local procsky = shaderpack.procsky
	if procsky and procsky.GetSkyColors then
		local _, z = procsky.GetSkyColors()

		return z[1] * tonemap, z[2] * tonemap, z[3] * tonemap
	end

	local r, g, b = render.GetFogColor()

	return toLinear(r) * tonemap, toLinear(g) * tonemap, toLinear(b) * tonemap
end

local visible = {}

local function draw(depth, skybox, sky3d)
	if not ready or depth or skybox or sky3d or render.GetRenderTarget() then return end

	local eye, fwd = EyePos(), EyeVector()
	local ang = EyeAngles()
	local right, up = ang:Right(), ang:Up()
	local tanH, tanV = shaderpack.ViewTan()
	local kH, kV = math.sqrt(1 + tanH * tanH), math.sqrt(1 + tanV * tanV)
	local eyeCluster = bspdata.ClusterAt(eye.x, eye.y, eye.z)
	local pvs = bspdata.PVS(eyeCluster)

	local n = math.ceil(RADIUS / CHUNK)
	local ecx, ecy = math.floor(eye.x / CHUNK), math.floor(eye.y / CHUNK)
	local half = CHUNK * 0.5
	local nvis = 0
	for cy = ecy - n, ecy + n do
		for cx = ecx - n, ecx + n do
			local dx, dy = cx * CHUNK + half - eye.x, cy * CHUNK + half - eye.y
			if math.sqrt(dx * dx + dy * dy) - half * 1.42 < RADIUS then
				local key = chunkKey(cx, cy)
				local ch = chunks[key]
				if not ch then
					ch = { cx = cx, cy = cy }
					chunks[key] = ch
					queue[#queue + 1] = ch
				elseif ch.meshes and #ch.meshes > 0 then
					local dz, r = ch.cz - eye.z, ch.radius
					local fz = dx * fwd.x + dy * fwd.y + dz * fwd.z
					local fx = dx * right.x + dy * right.y + dz * right.z
					local fy = dx * up.x + dy * up.y + dz * up.z
					if fz > -r and math.abs(fx) < fz * tanH + r * kH and math.abs(fy) < fz * tanV + r * kV then
						local seen = pvs == nil or #ch.clusters == 0
						for _, c in ipairs(ch.clusters) do
							if seen then break end
							seen = c == eyeCluster or pvs[c] and true or false
						end

						if seen then
							nvis = nvis + 1
							visible[nvis] = ch
						end
					end
				end
			end
		end
	end

	for i = #visible, nvis + 1, -1 do
		visible[i] = nil
	end

	if nvis == 0 then return end

	local tonemap = render.GetToneMappingScaleLinear().x
	local amb = render.GetAmbientLightColor()
	local sun = bspdata.BakedSun()
	local winMinX, winMaxX = (winX + 1) * TEXEL, (winX + TRAIL_TEXELS - 1) * TEXEL
	local winMinY, winMaxY = -(winY + TRAIL_TEXELS - 1) * TEXEL, -(winY + 1) * TEXEL
	setConstant(MAT, "$c0", eye.x, eye.y, eye.z, CurTime() % 1000)
	setConstant(MAT, "$c1", winMinX, winMinY, winMaxX, winMaxY)
	setConstant(MAT, "$c2", sun.x, sun.y, sun.z, foliage.WorldLightScale())
	setConstant(MAT, "$c3", packColor(amb.x * FILL_K, amb.y * FILL_K, amb.z * FILL_K), tonemap, FADE_START, FADE_END)

	local fr, fg, fb = render.GetFogColor()
	local fogStart, fogEnd = render.GetFogDistances()
	local fogMax = render.GetFogMode() == MATERIAL_FOG_NONE and 0 or render.GetFogMaxDensity()
	local sr, sg, sb = skyTint(tonemap)
	extra:SetUnpacked(
		toLinear(fr) * tonemap, toLinear(fg) * tonemap, toLinear(fb) * tonemap, fogStart,
		fogEnd, fogMax, 0, 0,
		sr, sg, sb, 0,
		0, 0, 0, 0
	)
	MAT:SetMatrix("$viewprojmat", extra)

	cam.PushModelMatrix(Matrix(), false)
	render.SetMaterial(MAT)
	render.OverrideDepthEnable(true, true)
	for i = 1, nvis do
		for _, m in ipairs(visible[i].meshes) do
			m:Draw()
		end
	end
	render.OverrideDepthEnable(false, false)

	if DEPTH_MAT and depthslices.BeginDepthWrite() then
		render.SetMaterial(DEPTH_MAT)
		for i = 1, nvis do
			for _, m in ipairs(visible[i].meshes) do
				m:Draw()
			end
		end
		depthslices.EndDepthWrite()
	end
	cam.PopModelMatrix()
end

local nextEvict = 0

local function evict()
	local now = RealTime()
	if now < nextEvict then return end
	nextEvict = now + 2

	local eye = EyePos()
	local limit = (RADIUS + CHUNK * 2) ^ 2
	local far, meshed = {}, 0
	for key, ch in pairs(chunks) do
		local dx, dy = ch.cx * CHUNK + CHUNK * 0.5 - eye.x, ch.cy * CHUNK + CHUNK * 0.5 - eye.y
		local d = dx * dx + dy * dy
		if d > limit and ch ~= current then
			if not ch.meshes then
				chunks[key] = nil
			elseif ch.tris > 0 then
				ch.evictDist = d
				far[#far + 1] = ch
				meshed = meshed + ch.tris
			end
		end
	end

	if meshed <= MESH_CACHE_TRIS then return end

	table.sort(far, function(a, b) return a.evictDist > b.evictDist end)
	for _, ch in ipairs(far) do
		if meshed <= MESH_CACHE_TRIS then break end
		meshed = meshed - ch.tris
		destroyChunk(ch)
		chunks[chunkKey(ch.cx, ch.cy)] = nil
	end
end

local winterRemoved = false

local function stop()
	hook.Remove("Think", "ms_snowcover")
	hook.Remove("PreRender", "ms_snowcover")
	hook.Remove("PostDrawOpaqueRenderables", "ms_snowcover")
	hook.Remove("ShouldDrawLocalPlayer", "ms_snowcover")
	for _, ch in pairs(chunks) do
		destroyChunk(ch)
	end

	chunks, queue, current, loader, ready = {}, {}, nil, nil, false
	triGrid, edgeGrid = nil, nil
	winX, winY = nil, nil
end

local function start()
	stop()
	if winterRemoved or shaderpack.Season() ~= "winter" then return end

	trailRT = GetRenderTargetEx("ms_snowcover_trail_" .. TRAIL_TEXELS, TRAIL_TEXELS, TRAIL_TEXELS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA16161616F)
	stampRT = GetRenderTargetEx("ms_snowcover_stamp_" .. TRAIL_TEXELS, TRAIL_TEXELS, TRAIL_TEXELS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
	if not shaderpack.UsableRT(trailRT, TRAIL_TEXELS) or not shaderpack.UsableRT(stampRT, TRAIL_TEXELS) then
		trailRT, stampRT = nil, nil

		return
	end

	materialSerial = materialSerial + 1
	local suffix = os.time() .. "_" .. materialSerial
	stampMat = CreateMaterial("ms_snowcover_stamp_" .. suffix, "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$model"] = 1,
		["$nocull"] = 1,
		["$ignorez"] = 1,
	})
	blurMat = CreateShaderMaterial("ms_snowcover_blur_" .. suffix, {
		["$pixshader"] = STAMP_PS,
		["$basetexture"] = stampRT:GetName(),
		["$linearread_basetexture"] = 1,
		["$linearwrite"] = 1,
		["$alpha_blend"] = 0,
	})
	MAT = CreateShaderMaterial("ms_snowcover_" .. suffix, {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$texture1"] = NOISE,
		["$linearread_basetexture"] = 1,
		["$linearread_texture1"] = 1,
		["$linearwrite"] = 0,
		["$alpha_blend"] = 0,
		["$additive"] = 0,
		["$ignorez"] = 0,
		["$depthtest"] = 1,
		["$nocull"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	}, "screenspace_general_8tex")
	MAT:SetTexture("$basetexture", trailRT)
	blurMat:SetTexture("$basetexture", stampRT)
	DEPTH_MAT = CreateShaderMaterial("ms_snowcoverdepth_" .. suffix, {
		["$pixshader"] = DEPTH_PS,
		["$vertexshader"] = VS,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
	})

	for _, rt in ipairs({ trailRT, stampRT }) do
		render.PushRenderTarget(rt)
		render.Clear(0, 0, 0, 0)
		render.PopRenderTarget()
	end

	loader = coroutine.create(load)
	hook.Add("Think", "ms_snowcover", function()
		think()
		evict()
	end)
	hook.Add("PreRender", "ms_snowcover", prepare)
	hook.Add("PostDrawOpaqueRenderables", "ms_snowcover", draw)
	hook.Add("ShouldDrawLocalPlayer", "ms_snowcover", function()
		if capturing then return true end
	end)
end

local apply = shaderpack.Toggle("ms_snowcover", ENABLED, SHADERS, start, stop, { NOISE })
shaderpack.AfterWorld("ms_snowcover", apply)

hook.Add("TOD_WinterRemoved", "ms_snowcover", function()
	winterRemoved = true
	stop()
end)
