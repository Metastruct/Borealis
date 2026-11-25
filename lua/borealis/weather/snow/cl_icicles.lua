local snow = shaderpack.snow
local chunks, depthslices = shaderpack.chunks, shaderpack.depthslices
local icicles = snow.icicles or {}
snow.icicles = icicles

local ENABLED = CreateClientConVar("borealis_icicles", "1", true, false, "hang icicles under snowy roof edges")

local STRIDE = snow.STRIDE
local SKIRT_DEPTH = snow.meshBuilder.SKIRT_DEPTH
local SKY_CLUSTER = bspdata.SKY_CLUSTER
local SOLID = MASK_SOLID_BRUSHONLY
local ICE_STRIDE = 8
local MESH_TRIS = 10000
local DRAW_RANGE = 2500
local SKIRT_NXY = 0.99
local SEARCH = 4096
local FACE_OUT, FACE_IN, FACE_DEPTH, FACE_REFINE = 3, 8, 1, 6
local FASCIA_IN, FASCIA_MAX, FASCIA_STEP, FASCIA_REFINE = 0.5, 64, 4, 3
local CLEAR_OUT, CLEAR_STEP = 3, 6
local MIN_CLEARANCE = 40
local CLEARANCE_SHARE = 0.5
local ROOM_START, ROOM_MAX, ROOM_STEP, ROOM_REFINE, ROOM_BELOW = 0.5, 12, 2, 2, 1
local UNDER_STEP, UNDER_REFINE, UNDER_REACH = 2, 3, 2
local LEN_MIN, LEN_MAX = 6, 72
local CLEAR_LIMIT = LEN_MAX / CLEARANCE_SHARE + FASCIA_MAX
local CELL, JITTER = 5, 0.2
local LINE_SNAP, FACINGS = 8, 8
local WAVE_LONG_MIN, WAVE_LONG_MAX, WAVE_SHORT_MIN, WAVE_SHORT_MAX = 48, 96, 14, 30
local WAVE_LONG, WAVE_SHORT = 0.3, 0.2
local FLOOR_FLAT, FLOOR_STEEP = 0.45, 0.2
local DRIP_IN, DRIP_ABOVE, DRIP_BELOW, DRIP_GAIN = 4, 4, 12, 3
local LEN_BASE = 0.35
local RADIUS_PER_ROOT, RADIUS_MIN, RADIUS_MAX = 0.45, 0.5, 4
local FLARE, FLARE_LEN, FLARE_SHARE = 1.2, 4, 0.4
local FLARE_RINGS, FLARE_CURVE, FLARE_GAP = 3, 1.4, 1.25
local SHEAR_LIMIT = 0.4
local LIP, HUG = 0.5, 0.3
local FLAT = 0.45
local ROOT_SLANT = 1
local EMBED = 0.5
local BEND = 0.08
local TAPER = 0.75
local RING_SPREAD = 1.6
local TIP_SLOPE_MIN = 0.02
local SHAPES = { { 12, 4, 3 }, { 32, 6, 5 }, { math.huge, 8, 7 } }
local TAU = math.pi * 2
local ORDER = 1.5
local IDENTITY = Matrix()
local PROBE_TEXELS = 64
local PROBE_ROWS = PROBE_TEXELS * 2
local PROBE_SLOTS = PROBE_TEXELS * PROBE_TEXELS - 1
local PROBE_STRIDE = 4
local PROBE_DROP = 4
local PROBE_CELL = 48
local PROBE_OUT, PROBE_ALONG, PROBE_DOWN = 0.5, 0.7, 0.3
local DLIGHT_RANGE = 1024
local DLIGHT_GAIN = 0.9
local LIGHT_MAX = 2
local SKY_RINGS = { { 15, 8 }, { 40, 8 }, { 70, 4 } }
local SUN_DEPTHS = { 0, 0.4, 0.8 }
local EDGE_INSET, EDGE_LIFT = 2, 4
local EDGE_FACTOR_MIN = 0.2
local SKY_REACH = 4096
local RNG_MOD = 2147483647

local skyRays, skyWeight = {}, 0
for _, ring in ipairs(SKY_RINGS) do
	local elevation, count = math.rad(ring[1]), ring[2]
	local flat, weight = math.cos(elevation), math.cos(elevation)
	for i = 0, count - 1 do
		local yaw = (i + 0.5) / count * TAU
		skyRays[#skyRays + 1] = { math.cos(yaw) * flat * SKY_REACH, math.sin(yaw) * flat * SKY_REACH, math.sin(elevation) * SKY_REACH, weight }
		skyWeight = skyWeight + weight
	end
end

local MAT
local queue, queued, queueFrame = {}, 0, -1
local res = {}
local tr = { mask = SOLID, start = Vector(), endpos = Vector(), output = res }
local samplePos = Vector()
local vpos, vnormal = Vector(), Vector()
local probeRT, probeFrame = nil, -1
local freeSlots, freeCount, nextSlot = {}, 0, 1
local lit, written, visited, skyOpen = {}, {}, {}, {}
local bakedR, bakedG, bakedB, bakedCount, baked = {}, {}, {}, {}, {}
local pending, pendingCount = {}, 0
local writeSlot, writeValue = {}, {}
local rngState = 1

local function trace(x0, y0, z0, x1, y1, z1)
	tr.start:SetUnpacked(x0, y0, z0)
	tr.endpos:SetUnpacked(x1, y1, z1)
	util.TraceLine(tr)

	return res
end

local function solidAt(x, y, z)
	samplePos:SetUnpacked(x, y, z)

	return bit.band(util.PointContents(samplePos), SOLID) ~= 0
end

local function run(x, y, z, dx, dy, dz, limit, step, refine, want)
	if solidAt(x, y, z) ~= want then return end

	local d = 0
	while d < limit do
		local nd = math.min(d + step, limit)
		if solidAt(x + dx * nd, y + dy * nd, z + dz * nd) ~= want then
			for _ = 1, refine do
				local mid = (d + nd) * 0.5
				if solidAt(x + dx * mid, y + dy * mid, z + dz * mid) == want then d = mid else nd = mid end
			end

			return (d + nd) * 0.5
		end
		d = nd
	end

	return limit
end

local function mix(a, b)
	return bit.bxor(a * 73244475 % RNG_MOD, (b + 40503) * 2654435 % RNG_MOD)
end

local function seed(s)
	rngState = s % (RNG_MOD - 1) + 1
end

local function rnd()
	rngState = rngState * 48271 % RNG_MOD

	return rngState / RNG_MOD
end

local function profile(mx, my, mz, ox, oy)
	local top = mz - FACE_DEPTH
	local span = FACE_OUT + FACE_IN
	local free = run(mx + ox * FACE_OUT, my + oy * FACE_OUT, top, -ox, -oy, 0, span, span, FACE_REFINE, false)
	if not free then return end

	local face, fascia = 0, -FACE_DEPTH
	if free < span then
		face = FACE_OUT - free
		fascia = run(mx + ox * (face - FASCIA_IN), my + oy * (face - FASCIA_IN), top, 0, 0, -1, FASCIA_MAX, FASCIA_STEP, FASCIA_REFINE, true)
		if not fascia then return end
	end

	local reach = math.max(face, 0) + CLEAR_OUT
	local cx, cy = mx + ox * reach, my + oy * reach
	if bspdata.ClusterAt(cx, cy, top) < 0 then return end

	local clearance = run(cx, cy, top, 0, 0, -1, CLEAR_LIMIT, CLEAR_STEP, 0, false)
	if not clearance then return end
	if fascia >= FASCIA_MAX then return face, nil, 0, clearance end

	local drop = FACE_DEPTH + fascia
	local from = face + ROOM_START
	local room = run(mx + ox * from, my + oy * from, mz - drop - ROOM_BELOW, -ox, -oy, 0, ROOM_MAX + ROOM_START, ROOM_STEP, ROOM_REFINE, false)

	return face, drop, room and room - ROOM_START or 0, clearance - math.max(fascia, 0)
end

local function underside(x, y, z, reach)
	local h = run(x, y, z, 0, 0, 1, reach, UNDER_STEP, UNDER_REFINE, false)
	if h and h < reach then return z + h end
end

local function roofDrip(mx, my, mz, ox, oy)
	local x, y = mx - ox * DRIP_IN, my - oy * DRIP_IN
	local t = trace(x, y, mz + DRIP_ABOVE, x, y, mz - DRIP_BELOW)
	if t.StartSolid or not t.Hit then return 0 end

	local n = t.HitNormal

	return math.Clamp((n.x * ox + n.y * oy) * DRIP_GAIN, 0, 1)
end

local function addIcicle(out, x, y, top, len, radius, flat, ex, ey, ox, oy, bx, by, spin, tilt, slot)
	local shape
	for _, s in ipairs(SHAPES) do
		if len < s[1] then
			shape = s
			break
		end
	end

	local sides, rings = shape[2], shape[3]
	local total = len + EMBED
	local spread = radius * FLARE
	local slant = flat < 1 and ROOT_SLANT or 0
	local back = radius * flat
	local base = math.min(math.max(FLARE_LEN, 2 * back * slant / SHEAR_LIMIT, 2 * spread * math.abs(tilt) / SHEAR_LIMIT), total * FLARE_SHARE)
	local tiltMax = SHEAR_LIMIT * base / (2 * spread + radius)
	tilt = math.Clamp(tilt, -tiltMax, tiltMax)
	slant = math.min(slant, SHEAR_LIMIT * base / (2 * back))

	local ringS, last = { [0] = 0 }, 0
	for j = 1, FLARE_RINGS do
		last = last + 1
		ringS[last] = base * (j / FLARE_RINGS) ^ FLARE_CURVE
	end
	for k = 1, rings - 1 do
		local s = total * (1 - (1 - k / rings) ^ RING_SPREAD)
		if s > base * FLARE_GAP then
			last = last + 1
			ringS[last] = s
		end
	end

	local ringX, ringY, ringZ, ringA, ringB, slopeA, slopeB, ringTilt, ringSlant, ringFrac = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
	for k = 0, last do
		local s = ringS[k]
		local left = math.max((total - s) / total, TIP_SLOPE_MIN)
		local bend = (s / total) ^ 2 * total
		local core = radius * left ^ TAPER
		local coreSlope = -TAPER * radius / total * left ^ (TAPER - 1)
		local rise = math.max(1 - s / base, 0)
		ringX[k], ringY[k], ringZ[k] = x + bx * bend, y + by * bend, top - s
		ringA[k], ringB[k] = core + spread * rise * rise, core * flat
		slopeA[k], slopeB[k] = coreSlope - 2 * spread * rise / base, coreSlope
		ringTilt[k] = tilt * math.Clamp(2 - s / base, 0, 1)
		ringSlant[k] = slant * rise
		ringFrac[k] = math.max(s - EMBED, 0) / len
	end

	local tipX, tipY, tipZ = x + bx * total, y + by * total, top - total
	local cosA, sinA = {}, {}
	for a = 0, sides do
		local angle = spin + a / sides * TAU
		cosA[a], sinA[a] = math.cos(angle), math.sin(angle)
	end

	local function ringPoint(k, c, s)
		local lx, ly = c * ringA[k], s * ringB[k]

		return ringX[k] + ex * lx + ox * ly, ringY[k] + ey * lx + oy * ly, ringZ[k] - (ly + back) * ringSlant[k] + lx * ringTilt[k]
	end

	local n = #out
	local function emit(px, py, pz, nx, ny, nz, t)
		out[n + 1], out[n + 2], out[n + 3], out[n + 4] = px, py, pz, nx
		out[n + 5], out[n + 6], out[n + 7], out[n + 8] = ny, nz, t, slot
		n = n + ICE_STRIDE
	end

	local function vertex(k, a)
		local c, s = cosA[a], sinA[a]
		local hx, hy = c * ringB[k], s * ringA[k]
		local slope = c * c * slopeA[k] + s * s * slopeB[k]
		local rise = 1 / math.sqrt(1 + slope * slope)
		local scale = rise / math.sqrt(hx * hx + hy * hy)
		hx, hy = hx * scale, hy * scale
		local px, py, pz = ringPoint(k, c, s)
		emit(px, py, pz, ex * hx + ox * hy, ey * hx + oy * hy, slope * rise, ringFrac[k])
	end

	if slant > 0 then
		local scale = 1 / math.sqrt(1 + slant * slant + tilt * tilt)
		local cnx, cny, cnz = (ox * slant - ex * tilt) * scale, (oy * slant - ey * tilt) * scale, scale
		local apexX, apexY = ringX[0] - ox * back, ringY[0] - oy * back
		for a = 0, sides - 1 do
			local px, py, pz = ringPoint(0, cosA[a], sinA[a])
			emit(px, py, pz, cnx, cny, cnz, 0)
			px, py, pz = ringPoint(0, cosA[a + 1], sinA[a + 1])
			emit(px, py, pz, cnx, cny, cnz, 0)
			emit(apexX, apexY, ringZ[0], cnx, cny, cnz, 0)
		end
	end

	for k = 0, last - 1 do
		for a = 0, sides - 1 do
			vertex(k, a)
			vertex(k + 1, a)
			vertex(k + 1, a + 1)
			vertex(k, a)
			vertex(k + 1, a + 1)
			vertex(k, a + 1)
		end
	end

	for a = 0, sides - 1 do
		vertex(last, a)
		emit(tipX, tipY, tipZ, 0, 0, -1, 1)
		vertex(last, a + 1)
	end
end

local function allocSlot()
	if freeCount > 0 then
		local slot = freeSlots[freeCount]
		freeSlots[freeCount] = nil
		freeCount = freeCount - 1

		return slot
	end

	if nextSlot > PROBE_SLOTS then return 0 end
	nextSlot = nextSlot + 1

	return nextSlot - 1
end

local function lightByte(v)
	return math.floor(math.Clamp(v, 0, LIGHT_MAX) * 127.5)
end

local function sunVisible(x, y, z, sx, sy, sz)
	local t = trace(x, y, z, x + sx * SEARCH, y + sy * SEARCH, z + sz * SEARCH)

	return not t.StartSolid and (t.HitSky or not t.Hit)
end

local function shadeLight(edgeLight, x, y, top, reach, edgeX, edgeY, edgeZ, open)
	local sun = bspdata.BakedSun()
	local share = math.min(sun:Length(), 1)
	local sunVis, edgeSun = 0, 0
	if share > 0 then
		local sx, sy, sz = sun.x / share, sun.y / share, sun.z / share
		for _, depth in ipairs(SUN_DEPTHS) do
			if sunVisible(x, y, top - depth * reach, sx, sy, sz) then sunVis = sunVis + 1 end
		end
		sunVis = sunVis / #SUN_DEPTHS
		edgeSun = sunVisible(edgeX, edgeY, edgeZ, sx, sy, sz) and 1 or 0
	end

	local scale = (share * sunVis + (1 - share) * open) / math.max(share * edgeSun + 1 - share, EDGE_FACTOR_MIN) / 127.5

	return math.floor(edgeLight / 65536) * scale, math.floor(edgeLight / 256) % 256 * scale, edgeLight % 256 * scale
end

local function skyOpenness(x, y, z)
	local open = 0
	for _, ray in ipairs(skyRays) do
		local t = trace(x, y, z, x + ray[1], y + ray[2], z + ray[3])
		if not t.StartSolid and (t.HitSky or not t.Hit) then open = open + ray[4] end
	end

	return open / skyWeight
end

local function probeSlot(probes, x, y, z, ox, oy, ux, uy, facing)
	local key = snow.CellKey(x, y, z, PROBE_CELL) * FACINGS + facing
	local slot = probes.cells[key]
	if slot then return slot end

	slot = allocSlot()
	probes.cells[key] = slot
	if slot == 0 then return 0 end

	local scale = 1 / math.sqrt(PROBE_OUT * PROBE_OUT + PROBE_ALONG * PROBE_ALONG + PROBE_DOWN * PROBE_DOWN)
	local o = #probes
	probes[o + 1], probes[o + 2] = slot, Vector(x, y, z)
	probes[o + 3] = Vector((ox * PROBE_OUT + ux * PROBE_ALONG) * scale, (oy * PROBE_OUT + uy * PROBE_ALONG) * scale, -PROBE_DOWN * scale)
	probes[o + 4] = Vector((ox * PROBE_OUT - ux * PROBE_ALONG) * scale, (oy * PROBE_OUT - uy * PROBE_ALONG) * scale, -PROBE_DOWN * scale)

	skyOpen[slot] = math.floor(skyOpenness(x, y, z) * 255 + 0.5)
	bakedR[slot], bakedG[slot], bakedB[slot], bakedCount[slot] = 0, 0, 0, 0

	return slot
end

local function seedEdge(groups, probes, px, py, pz, qx, qy, qz, ox, oy, cover, light)
	local dx, dy = qx - px, qy - py
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.5 or cover <= 0 then return end

	local mx, my, mz = (px + qx) * 0.5, (py + qy) * 0.5, (pz + qz) * 0.5
	if bspdata.BeyondWorld(mx, my, mz) then return end

	local face, drop, room, clearance = profile(mx, my, mz, ox, oy)
	if not face or clearance < MIN_CLEARANCE then return end

	local maxLen = math.min(LEN_MAX, clearance * CLEARANCE_SHARE)
	if maxLen < LEN_MIN then return end

	local ux, uy = dx / len, dy / len
	local lx, ly = ux, uy
	if lx < 0 or lx == 0 and ly < 0 then lx, ly = -lx, -ly end
	local facing = math.floor(math.atan2(oy, ox) / TAU * FACINGS + 0.5) % FACINGS
	local line = mix(math.floor((my * lx - mx * ly) / LINE_SNAP + 0.5), facing)
	seed(line)
	local longFreq, longPhase = TAU / (WAVE_LONG_MIN + rnd() * (WAVE_LONG_MAX - WAVE_LONG_MIN)), rnd() * TAU
	local shortFreq, shortPhase = TAU / (WAVE_SHORT_MIN + rnd() * (WAVE_SHORT_MAX - WAVE_SHORT_MIN)), rnd() * TAU
	local floorLevel = FLOOR_FLAT + (FLOOR_STEEP - FLOOR_FLAT) * roofDrip(mx, my, mz, ox, oy)

	local a0 = px * lx + py * ly
	local sign = ux * lx + uy * ly
	local lo, hi = math.min(a0, a0 + sign * len), math.max(a0, a0 + sign * len)
	local tilt = (qz - pz) / len
	local slot
	for k = math.floor(lo / CELL), math.floor(hi / CELL) do
		seed(mix(line, k))
		rnd()
		local a = (k + JITTER + rnd() * (1 - 2 * JITTER)) * CELL
		local melt = (0.5 + WAVE_LONG * math.sin(a * longFreq + longPhase) + WAVE_SHORT * math.sin(a * shortFreq + shortPhase) - floorLevel) / (1 - floorLevel)
		if a >= lo and a < hi and melt > 0 and rnd() < cover then
			local l = LEN_MIN + (maxLen - LEN_MIN) * math.min(melt, 1) ^ 2 * (LEN_BASE + (1 - LEN_BASE) * (rnd() + rnd()) * 0.5)
			local r = math.Clamp(RADIUS_PER_ROOT * math.sqrt(l), RADIUS_MIN, RADIUS_MAX)
			local spin, bendAngle, bend = rnd() * TAU, rnd() * TAU, BEND * rnd()
			local s = (a - a0) * sign
			local x, y = px + ux * s, py + uy * s
			local edgeZ = pz + (qz - pz) * s / len
			local flat, away, root = 1

			if not drop then
				flat = FLAT
				away = face + HUG + r * flat
				root = edgeZ
			else
				local fit = math.min(r, (room - LIP * 2) * 0.5)
				if fit >= RADIUS_MIN then
					away = face - LIP - fit
					root = underside(x + ox * away, y + oy * away, edgeZ - drop - ROOM_BELOW, drop + ROOM_BELOW + UNDER_REACH)
				end

				if root then
					r = fit
				elseif drop > 0 then
					away = face + HUG + r
					root = edgeZ - drop
				end
			end

			if root then
				local bx, by = math.cos(bendAngle) * bend, math.sin(bendAngle) * bend
				if flat < 1 then
					local along, outward = math.cos(bendAngle) * bend, math.abs(math.sin(bendAngle)) * bend
					bx, by = ux * along + ox * outward, uy * along + oy * outward
					spin = 0
				end

				local cx, cy = x + ox * away, y + oy * away
				if not slot then
					slot = probeSlot(probes, cx, cy, root - PROBE_DROP, ox, oy, ux, uy, facing)
					if slot == 0 then return end

					local r0, g0, b0 = shadeLight(light, cx, cy, root - PROBE_DROP, maxLen, mx - ox * EDGE_INSET, my - oy * EDGE_INSET, mz + EDGE_LIFT, skyOpen[slot] / 255)
					bakedR[slot], bakedG[slot], bakedB[slot] = bakedR[slot] + r0, bakedG[slot] + g0, bakedB[slot] + b0
					bakedCount[slot] = bakedCount[slot] + 1
				end

				local cluster = snow.ClusterAt(cx, cy, root - 4)
				local out = groups[cluster]
				if not out then
					out = {}
					groups[cluster] = out
				end

				addIcicle(out, cx, cy, root + EMBED, l, r, flat, ux, uy, ox, oy, bx, by, spin, tilt, slot)
			end
		end
	end
end

local function isSkirt(verts, o)
	local nx, ny = verts[o + 4], verts[o + 5]

	return nx * nx + ny * ny > SKIRT_NXY and verts[o + 2 * STRIDE + 7] == 0
end

local function normalByte(v)
	return math.floor((v + 1) * 127.5 + 0.5)
end

local function buildMeshes(out)
	local meshes, left, o = {}, #out / ICE_STRIDE / 3, 0
	while left > 0 do
		chunks.YieldIfOverBudget()
		local count = math.min(left, MESH_TRIS)
		local m = Mesh()
		mesh.Begin(m, MATERIAL_TRIANGLES, count)
		for _ = 1, count * 3 do
			local nx, ny, nz = out[o + 4], out[o + 5], out[o + 6]
			vpos:SetUnpacked(out[o + 1], out[o + 2], out[o + 3])
			vnormal:SetUnpacked(nx, ny, nz)
			mesh.Position(vpos)
			mesh.Normal(vnormal)
			mesh.TexCoord(0, out[o + 8], out[o + 7])
			mesh.Color(normalByte(nx), normalByte(ny), normalByte(nz), 255)
			mesh.AdvanceVertex()
			o = o + ICE_STRIDE
		end
		mesh.End()
		meshes[#meshes + 1] = m
		left = left - count
	end

	return meshes
end

local function freeProbes(ch)
	local probes = ch.icicleProbes
	if not probes then return end

	for o = 0, #probes - 1, PROBE_STRIDE do
		local slot = probes[o + 1]
		freeCount = freeCount + 1
		freeSlots[freeCount] = slot
	end
	ch.icicleProbes = nil
end

local function settleProbes(probes)
	for o = 0, #probes - 1, PROBE_STRIDE do
		local slot = probes[o + 1]
		local count = math.max(bakedCount[slot], 1)
		baked[slot] = lightByte(bakedR[slot] / count) * 65536 + lightByte(bakedG[slot] / count) * 256 + lightByte(bakedB[slot] / count)
		pendingCount = pendingCount + 1
		pending[pendingCount] = slot
	end
end

function icicles.Build(ch, verts, tris)
	freeProbes(ch)
	local groups, probes = {}, { cells = {} }
	ch.icicleProbes = probes
	local o, last = 0, (tris - 1) * 3 * STRIDE
	while o <= last do
		local b = o + 3 * STRIDE
		if isSkirt(verts, o) and b <= last and isSkirt(verts, b) then
			local cover = math.max(verts[o + 7], verts[o + STRIDE + 7])
			seedEdge(groups, probes,
				verts[o + 1], verts[o + 2], verts[b + 2 * STRIDE + 3] + SKIRT_DEPTH,
				verts[o + STRIDE + 1], verts[o + STRIDE + 2], verts[o + 2 * STRIDE + 3] + SKIRT_DEPTH,
				verts[o + 4], verts[o + 5], cover, verts[o + 6])
			o = b + 3 * STRIDE
			chunks.YieldIfOverBudget()
		else
			o = o + 3 * STRIDE
		end
	end
	settleProbes(probes)

	local byCluster = {}
	for _, g in ipairs(ch.groups) do
		byCluster[g.cluster] = g
	end

	local added = 0
	for cluster, out in pairs(groups) do
		local g = byCluster[cluster]
		if not g then
			g = { cluster = cluster, meshes = {} }
			ch.groups[#ch.groups + 1] = g
			byCluster[cluster] = g
		end

		g.icicles = buildMeshes(out)
		added = added + #out / ICE_STRIDE / 3
	end

	return added
end

function icicles.Destroy(ch)
	freeProbes(ch)
	for _, g in ipairs(ch.groups or {}) do
		for _, m in ipairs(g.icicles or {}) do
			m:Destroy()
		end
		g.icicles = nil
	end
end

local function probeTexture()
	if probeRT then return probeRT end

	local rt = GetRenderTargetEx("borealis_icicle_probes_" .. PROBE_TEXELS .. "x" .. PROBE_ROWS, PROBE_TEXELS, PROBE_ROWS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 1, 0, IMAGE_FORMAT_RGBA8888)
	if not shaderpack.UsableRT(rt, PROBE_TEXELS, PROBE_ROWS) then return end

	render.PushRenderTarget(rt)
	render.Clear(0, 0, 0, 255)
	render.PopRenderTarget()
	probeRT = rt

	return rt
end

local function dynamicByte(v)
	return math.min(math.floor(v * DLIGHT_GAIN * 127.5), 255)
end

local function texel(slot, row, value, alpha)
	render.SetViewPort(slot % PROBE_TEXELS, math.floor(slot / PROBE_TEXELS) + row, 1, 1)
	render.Clear(math.floor(value / 65536), math.floor(value / 256) % 256, value % 256, alpha)
end

local function updateLights(shown)
	local frame = FrameNumber()
	if probeFrame == frame or not probeTexture() then return end
	probeFrame = frame

	local compute = render.ComputeDynamicLighting
	local writes = 0
	for i = 1, pendingCount do
		local slot = pending[i]
		writes = writes + 1
		writeSlot[writes], writeValue[writes] = slot, 0
		written[slot] = 0
	end

	for _, ch in ipairs(shown) do
		if ch.drawDist > DLIGHT_RANGE then break end

		local probes = ch.icicleProbes
		if probes then
			for o = 0, #probes - 1, PROBE_STRIDE do
				local slot, pos = probes[o + 1], probes[o + 2]
				local l = compute(pos, probes[o + 3])
				l:Add(compute(pos, probes[o + 4]))
				local value = 0
				if not l:IsZero() then
					value = dynamicByte(l.x) * 65536 + dynamicByte(l.y) * 256 + dynamicByte(l.z)
				end
				visited[slot] = frame
				if value > 0 then lit[slot] = true end
				if value ~= (written[slot] or 0) then
					writes = writes + 1
					writeSlot[writes], writeValue[writes] = slot, value
				end
			end
		end
	end

	for slot in pairs(lit) do
		if visited[slot] ~= frame and (written[slot] or 0) > 0 then
			writes = writes + 1
			writeSlot[writes], writeValue[writes] = slot, 0
		end
	end

	if writes == 0 then return end

	render.PushRenderTarget(probeRT)
	for i = 1, pendingCount do
		local slot = pending[i]
		pending[i] = nil
		texel(slot, PROBE_TEXELS, baked[slot] or 0, 255)
	end
	pendingCount = 0

	for i = 1, writes do
		local slot, value = writeSlot[i], writeValue[i]
		written[slot] = value
		if value == 0 then lit[slot] = nil end
		texel(slot, 0, value, skyOpen[slot] or 255)
	end
	render.SetViewPort(0, 0, PROBE_TEXELS, PROBE_ROWS)
	render.PopRenderTarget()
end

function icicles.Collect(shown, pvsFilter, list, n)
	if not MAT or not ENABLED:GetBool() then return n end

	updateLights(shown)

	for _, ch in ipairs(shown) do
		if ch.drawDist > DRAW_RANGE then break end

		for _, g in ipairs(ch.groups) do
			if g.icicles and g.cluster ~= SKY_CLUSTER and pvsFilter:Passes(g) then
				for _, m in ipairs(g.icicles) do
					n = n + 1
					list[n] = m
				end
			end
		end
	end

	return n
end

function icicles.Material()
	return MAT
end

function icicles.Queue(list, first, last, wallTex, flashlightTex)
	if first > last then return end

	local frame = FrameNumber()
	if frame ~= queueFrame then
		queueFrame, queued = frame, 0
	end

	queued = queued + 1
	local q = queue[queued]
	if not q then
		q = { meshes = {}, eye = Vector() }
		queue[queued] = q
	end

	local meshes, count = q.meshes, last - first + 1
	for i = 1, count do
		meshes[i] = list[first + i - 1]
	end
	for i = #meshes, count + 1, -1 do
		meshes[i] = nil
	end

	q.wallTex, q.flashlightTex = wallTex, flashlightTex
	q.eye:Set(EyePos())
end

local function drawQueued()
	if not MAT or queued == 0 or queueFrame ~= FrameNumber() then return end

	local q = queue[queued]
	if q.eye:DistToSqr(EyePos()) > 1 then return end
	queued = queued - 1

	MAT:SetTexture("$basetexture", probeRT or "vgui/black")
	MAT:SetTexture("$texture1", q.wallTex)
	MAT:SetTexture("$texture2", q.flashlightTex)
	render.SetMaterial(MAT)
	render.OverrideAlphaWriteEnable(true, false)
	cam.PushModelMatrix(IDENTITY, false)
	local meshes = q.meshes
	for i = 1, #meshes do
		meshes[i]:Draw()
	end
	cam.PopModelMatrix()
	render.OverrideAlphaWriteEnable(false, false)
end

function icicles.Start(suffix)
	MAT = CreateShaderMaterial("borealis_icicle_" .. suffix, {
		["$pixshader"] = snow.ICICLE_PS,
		["$vertexshader"] = snow.VS,
		["$linearread_basetexture"] = 1,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$linearwrite"] = 0,
		["$alpha_blend"] = 1,
		["$additive"] = 0,
		["$ignorez"] = 0,
		["$depthtest"] = 1,
		["$nocull"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})
	depthslices.AddEffect("borealis_icicles", ORDER, drawQueued)
end

function icicles.Stop()
	depthslices.RemoveEffect("borealis_icicles")
	MAT = nil
	queued = 0
end
