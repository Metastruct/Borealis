local snow = shaderpack.snow
local heightfield = snow.heightfield
local surface = snow.surface or {}
snow.surface = surface

local DEPTH = snow.DEPTH
local CELL, STEP, STEP_MIN, MIN_RISE = heightfield.CELL, heightfield.STEP, heightfield.STEP_MIN, heightfield.MIN_RISE
local EDGE_MIN_HEIGHT = heightfield.EDGE_MIN_HEIGHT
local KIND_SNOW = heightfield.KIND_SNOW
local profile = heightfield.Profile
local RAY_HEIGHT = snow.RAY_HEIGHT
local MATCH = 12
local SOLID_TOLERANCE = 1
local GRADIENT_STEP = CELL * 0.5

local res = {}
local trace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = res }

local function matchSpan(list, z)
	local best, bestDz
	for _, s in ipairs(list) do
		local dz = math.abs(s.floor - z)
		if dz <= MATCH and (not best or dz < bestDz) then best, bestDz = s, dz end
	end

	return best
end

local function exposedPoint(data, x, y, z)
	local key = math.floor(x * 4 + 0.5) .. "," .. math.floor(y * 4 + 0.5) .. "," .. math.floor(z * 4 + 0.5)
	local open = data.points[key]
	if open == nil then
		open = snow.SeesSky(x, y, z + 2) and not snow.Submerged(x, y, z)
		data.points[key] = open
	end

	return open
end

local picks = { {}, {}, {}, {} }

local function reachable(x, y, z, s)
	local dx, dy, dz = s.x - x, s.y - y, s.floor - z
	trace.start:SetUnpacked(x, y, z + RAY_HEIGHT)
	trace.endpos:SetUnpacked(s.x, s.y, s.floor + RAY_HEIGHT)
	bspdata.TraceLine(trace)
	if res.StartSolid and res.FractionLeftSolid * math.sqrt(dx * dx + dy * dy + dz * dz) > SOLID_TOLERANCE then return false end

	return res.Fraction >= 1
end

local function blendColumns(data, x, y, z, nx, ny, nz, allowPoint)
	local n, gx0, gy0, columns = data.n, data.gx0, data.gy0, data.columns
	local fx, fy = x / CELL - 0.5 - gx0, y / CELL - 0.5 - gy0
	local i0, j0 = math.floor(fx), math.floor(fy)
	local tx, ty = fx - i0, fy - j0
	local count, slots = 0, 0
	for k = 0, 3 do
		local di, dj = k % 2, math.floor(k / 2)
		local w = (di == 1 and tx or 1 - tx) * (dj == 1 and ty or 1 - ty)
		local i, j = i0 + di, j0 + dj
		if w > 0 and i >= 0 and i < n and j >= 0 and j < n then
			slots = slots + 1
			local cx, cy = (gx0 + i + 0.5) * CELL, (gy0 + j + 0.5) * CELL
			local cz = z - (nx * (cx - x) + ny * (cy - y)) / nz
			local s = matchSpan(columns[j * n + i], cz)
			if s then
				count = count + 1
				local p = picks[count]
				p.s, p.w, p.o = s, w, s.floor - cz
			end
		end
	end

	if count < slots then
		local kept = 0
		for c = 1, count do
			local p = picks[c]
			if reachable(x, y, z, p.s) then
				kept = kept + 1
				picks[c], picks[kept] = picks[kept], p
			end
		end
		count = kept
	end

	local near
	for c = 1, count do
		local p = picks[c]
		if not near or math.abs(p.o) < math.abs(near.o) then near = p end
	end

	local matched, snowW, height, lift, bestW, best = 0, 0, 0, 0, 0
	for c = 1, count do
		local p = picks[c]
		local s, w, gap = p.s, p.w, p.o - (near and near.o or 0)
		if p == near or not (gap > STEP_MIN and near.s.riseEdge or gap < -STEP_MIN and s.riseEdge) then
			matched = matched + w
			if s.kind == KIND_SNOW then
				local h, l = profile(s, x, y)
				snowW = snowW + w
				height = height + w * h
				lift = lift + w * (l + s.delta)
				if w > bestW then bestW, best = w, s end
			end
		end
	end

	if matched <= 0 then
		local nearest, nearestD
		for j = j0 - 1, j0 + 2 do
			for i = i0 - 1, i0 + 2 do
				if (i < i0 or i > i0 + 1 or j < j0 or j > j0 + 1) and i >= 0 and i < n and j >= 0 and j < n then
					local cx, cy = (gx0 + i + 0.5) * CELL, (gy0 + j + 0.5) * CELL
					local d = (cx - x) * (cx - x) + (cy - y) * (cy - y)
					if not nearestD or d < nearestD then
						local s = matchSpan(columns[j * n + i], z - (nx * (cx - x) + ny * (cy - y)) / nz)
						if s and reachable(x, y, z, s) then nearest, nearestD = s, d end
					end
				end
			end
		end

		if not nearest then
			if allowPoint and exposedPoint(data, x, y, z) then return EDGE_MIN_HEIGHT, 0, { x = x, y = y, floor = z } end

			return 0, 0
		end

		if nearest.kind ~= KIND_SNOW then return 0, 0 end

		local h, l = profile(nearest, x, y)

		return h, l + nearest.delta, nearest
	end

	if snowW <= 0 then return 0, 0 end

	return height / matched, lift / snowW, best
end

function surface.Sample(data, x, y, z, nx, ny)
	nx, ny = nx or 0, ny or 0
	local nz = math.max(math.sqrt(math.max(1 - nx * nx - ny * ny, 0)), 0.3)
	local height, lift, best = blendColumns(data, x, y, z, nx, ny, nz, true)
	if height <= 0 or DEPTH * height + lift <= 0 then return 0 end

	local e = GRADIENT_STEP
	local function surfaceAt(dx, dy)
		local h, l = blendColumns(data, x + dx, y + dy, z - (nx * dx + ny * dy) / nz, nx, ny, nz)
		if h <= 0 then return end

		return DEPTH * h + l
	end

	local here = DEPTH * height + lift
	local px, mx, py, my = surfaceAt(e, 0), surfaceAt(-e, 0), surfaceAt(0, e), surfaceAt(0, -e)
	local gx = px and mx and (px - mx) / (2 * e) or px and (px - here) / e or mx and (here - mx) / e or 0
	local gy = py and my and (py - my) / (2 * e) or py and (py - here) / e or my and (here - my) / e or 0
	if lift < 0 then height, lift = height + lift / DEPTH, 0 end

	return height, lift, best.x, best.y, best.floor, gx, gy
end

function surface.SnowBelow(data, x, y, z)
	local n = data.n
	local i, j = math.floor(x / CELL - data.gx0), math.floor(y / CELL - data.gy0)
	if i < 0 or i >= n or j < 0 or j >= n then return false end

	for _, s in ipairs(data.columns[j * n + i]) do
		if s.kind == KIND_SNOW and s.floor < z - MIN_RISE and s.floor >= z - STEP then return true end
	end

	return false
end
