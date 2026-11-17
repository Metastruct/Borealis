local snow = shaderpack.snow
local meshBuilder = snow.meshBuilder or {}
snow.meshBuilder = meshBuilder

local bspdata = bspdata
local geometry, heightfield, surface = snow.geometry, snow.heightfield, snow.surface

local DEPTH, CHUNK, STRIDE = snow.DEPTH, snow.CHUNK, snow.STRIDE
local CELL = 32
local LIGHT_CELL = 16
local SMALL_TRI = CELL * 2
local SKIRT_DEPTH, SKIRT_SINK, SKIRT_CHECK_DISTANCE = 1, 0.6, 2
local RAY_HEIGHT = snow.RAY_HEIGHT
local WALL_CUT_DEPTH = 4

local cellKey = snow.CellKey
local wallTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = {} }
local checkPos = Vector()

local function slopedNormal(nx, ny, gx, gy)
	if gx == 0 and gy == 0 then return nx, ny end

	local nz = math.sqrt(math.max(1 - nx * nx - ny * ny, 0))
	nx, ny = nx - gx, ny - gy
	local len = math.sqrt(nx * nx + ny * ny + nz * nz)

	return nx / len, ny / len
end

local function snowAt(x, y, z, nonSnow, cache, nx, ny)
	local cover = 1 - nonSnow / 255
	if cover <= 0 then return 0, 0, 0, 0, 0 end

	local height, lift, sx, sy, sz, gx, gy = surface.Sample(cache.spans, x, y, z, nx, ny)
	if height <= 0 then return 0, 0, 0, 0, 0 end

	local lightKey = cellKey(sx, sy, sz, LIGHT_CELL)
	local light = cache.light[lightKey]
	if not light then
		local samples = cache.samples
		local n = #samples
		samples[n + 1], samples[n + 2], samples[n + 3] = sx, sy, sz + DEPTH + 2
		light = n / 3 + 1
		cache.light[lightKey] = light
	end

	return cover * height, light, gx * cover, gy * cover, lift * cover
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

local function clipPlane(poly, nx, ny, d)
	local out = {}
	local n = #poly
	for i = 1, n do
		local a, b = poly[i], poly[i % n + 1]
		local da, db = a[1] * nx + a[2] * ny - d, b[1] * nx + b[2] * ny - d
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

local function wallFace(a, b)
	wallTrace.start:SetUnpacked(a[1], a[2], a[3] + RAY_HEIGHT)
	wallTrace.endpos:SetUnpacked(b[1], b[2], b[3] + RAY_HEIGHT)
	local tr = util.TraceLine(wallTrace)
	if tr.StartSolid then return true end
	if not tr.Hit or math.abs(tr.HitNormal.z) >= 0.5 then return end

	local n = tr.HitNormal
	local len = math.sqrt(n.x * n.x + n.y * n.y)
	local nx, ny = n.x / len, n.y / len

	return false, nx, ny, nx * tr.HitPos.x + ny * tr.HitPos.y
end

local function solidAt(x, y, z)
	checkPos:SetUnpacked(x, y, z)

	return bit.band(util.PointContents(checkPos), CONTENTS_SOLID) ~= 0
end

function meshBuilder.Build(ch)
	local triGrid = geometry.Triangles()
	local x0, y0 = ch.cx * CHUNK, ch.cy * CHUNK
	local x1, y1 = x0 + CHUNK, y0 + CHUNK
	local cand = bspdata.Candidates(triGrid, x0, y0, x1, y1)
	local cache = { light = {}, samples = {} }
	local groups, order, group = {}, {}
	local zmin, zmax = math.huge, -math.huge
	local yieldIfOverBudget = snow.Yield
	local spans = heightfield.Build(triGrid, ch.cx, ch.cy, yieldIfOverBudget)
	cache.spans = spans

	local function emit(x, y, z, nx, ny, cover, light)
		local v, k = group.verts, group.n
		v[k + 1], v[k + 2], v[k + 3], v[k + 4], v[k + 5], v[k + 6], v[k + 7] = x, y, z, nx, ny, light, cover
		group.n = k + STRIDE
		if z < zmin then zmin = z end
		if z > zmax then zmax = z end
	end

	local function useCluster(x, y, z)
		local c = math.max(bspdata.ClusterAt(x, y, z + DEPTH + 4), -1)
		group = groups[c]
		if not group then
			group = { verts = {}, n = 0 }
			groups[c] = group
			order[#order + 1] = c
		end
	end

	local function emitVertex(p, s)
		local nx, ny = slopedNormal(p[5], p[6], s[3], s[4])
		emit(p[1], p[2], p[3] + s[1] * DEPTH + s[5], nx, ny, s[1], s[2])
	end

	local function emitPoly(poly, depth)
		local n = #poly
		local snowAtVertex, snowy = {}, false
		for k = 1, n do
			local p = poly[k]
			local s = { snowAt(p[1], p[2], p[3], p[4], cache, p[5], p[6]) }
			snowAtVertex[k] = s
			snowy = snowy or s[1] > 0
		end

		if not snowy then return end

		if depth < WALL_CUT_DEPTH then
			for k = 1, n do
				local k2 = k % n + 1
				if (snowAtVertex[k][1] > 0) ~= (snowAtVertex[k2][1] > 0) then
					local a, b = poly[k], poly[k2]
					local aSolid, anx, any, ad = wallFace(a, b)
					local bSolid, bnx, bny, bd = wallFace(b, a)
					if (anx or bnx) and not (aSolid and bSolid) then
						local rest = poly
						if anx then
							local half = clipPlane(rest, anx, any, ad)
							if #half >= 3 then emitPoly(half, depth + 1) end
							rest = clipPlane(rest, -anx, -any, -ad)
						end

						if bnx and #rest >= 3 then
							local half = clipPlane(rest, bnx, bny, bd)
							if #half >= 3 then emitPoly(half, depth + 1) end
							rest = clipPlane(rest, -bnx, -bny, -bd)
						end

						if #rest >= 3 then emitPoly(rest, depth + 1) end

						return
					end
				end
			end
		end

		for k = 2, n - 1 do
			local sa, sb, sc = snowAtVertex[1], snowAtVertex[k], snowAtVertex[k + 1]
			if sa[1] + sb[1] + sc[1] > 0 then
				emitVertex(poly[1], sa)
				emitVertex(poly[k], sb)
				emitVertex(poly[k + 1], sc)
			end
		end
	end

	for _, t in ipairs(cand) do
		if t.vn then
			local vn = t.vn
			local tri = { { t[1], t[2], t[3], t[10], vn[1], vn[2] }, { t[4], t[5], t[6], t[11], vn[3], vn[4] }, { t[7], t[8], t[9], t[12], vn[5], vn[6] } }
			if t[15] - t[13] <= SMALL_TRI and t[16] - t[14] <= SMALL_TRI then
				local mx, my = (t[1] + t[4] + t[7]) / 3, (t[2] + t[5] + t[8]) / 3
				if mx >= x0 and mx < x1 and my >= y0 and my < y1 then
					useCluster(mx, my, (t[3] + t[6] + t[9]) / 3)
					emitPoly(tri, 0)
				end

				yieldIfOverBudget()
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

						if #poly >= 3 then
							local px, py, pz = 0, 0, 0
							for _, p in ipairs(poly) do
								px, py, pz = px + p[1], py + p[2], pz + p[3]
							end

							useCluster(px / #poly, py / #poly, pz / #poly)
							emitPoly(poly, 0)
						end

						yieldIfOverBudget()
					end
				end
			end
		end
	end

	for _, e in ipairs(geometry.Edges(ch.cx, ch.cy)) do
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
			local function at(f)
				return ax + dx * f, ay + dy * f, e[3] + (e[7] - e[3]) * f, e[4] + (e[8] - e[4]) * f
			end

			local stops = { tb }
			for _, axis in ipairs({ { ax, dx }, { ay, dy } }) do
				local start, delta = axis[1], axis[2]
				if delta ~= 0 then
					local g0, g1 = start + delta * ta, start + delta * tb
					for line = math.ceil(math.min(g0, g1) / CELL), math.floor(math.max(g0, g1) / CELL) do
						local f = (line * CELL - start) / delta
						if f > ta + 1e-4 and f < tb - 1e-4 then stops[#stops + 1] = f end
					end
				end
			end

			table.sort(stops)

			local px, py, pz, pa = at(ta)
			local pc, pl, _, _, pm = snowAt(px, py, pz, pa, cache)
			for _, stop in ipairs(stops) do
				local qx, qy, qz, qa = at(stop)
				local qc, ql, _, _, qm = snowAt(qx, qy, qz, qa, cache)
				local mx, my, mz = (px + qx) * 0.5, (py + qy) * 0.5, (pz + qz) * 0.5
				local ox, oy = mx + e[9] * SKIRT_CHECK_DISTANCE, my + e[10] * SKIRT_CHECK_DISTANCE
				local walled = pc + qc > 0 and (solidAt(ox, oy, mz + SKIRT_CHECK_DISTANCE) or solidAt(mx - e[9] * SKIRT_CHECK_DISTANCE, my - e[10] * SKIRT_CHECK_DISTANCE, mz + SKIRT_CHECK_DISTANCE))

				if pc + qc > 0 and not walled then
					local covered = surface.SnowBelow(spans, ox, oy, mz)
					useCluster(mx, my, mz)
					local sink = covered and SKIRT_SINK or 0
					emit(px, py, pz + pc * DEPTH + pm - sink, e[9], e[10], pc, pl)
					emit(qx, qy, qz + qc * DEPTH + qm - sink, e[9], e[10], qc, ql)
					emit(qx, qy, qz - SKIRT_DEPTH, e[9], e[10], 0, ql)
					emit(px, py, pz + pc * DEPTH + pm - sink, e[9], e[10], pc, pl)
					emit(qx, qy, qz - SKIRT_DEPTH, e[9], e[10], 0, ql)
					emit(px, py, pz - SKIRT_DEPTH, e[9], e[10], 0, pl)
				end

				px, py, pz, pc, pl, pm = qx, qy, qz, qc, ql, qm
			end
		end

		yieldIfOverBudget()
	end

	table.sort(order)
	local verts, n, clusters, clusterTris = {}, 0, {}, {}
	for _, c in ipairs(order) do
		local g = groups[c]
		if g.n > 0 then
			local v = g.verts
			for i = 1, g.n do
				verts[n + i] = v[i]
			end

			n = n + g.n
			clusters[#clusters + 1] = c
			clusterTris[#clusterTris + 1] = g.n / STRIDE / 3
		end

		yieldIfOverBudget()
	end

	ch.clusters, ch.clusterTris, ch.samples = clusters, clusterTris, cache.samples
	ch.cz = (zmin + zmax) * 0.5
	local hz = (zmax - zmin) * 0.5
	ch.radius = math.sqrt(CHUNK * CHUNK * 0.5 + hz * hz)

	return verts, n / STRIDE / 3
end

-- JIT compilation made these functions run ~x4 times slower on macos through wine/rosetta
-- I'm assuming this is primarily due to rosetta, needs testing on windows before enabling
--for _, fn in ipairs({ slopedNormal, snowAt, clipPoly, meshBuilder.Build }) do
--	jit.off(fn, true)
--end
