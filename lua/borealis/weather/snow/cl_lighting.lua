local snow = shaderpack.snow
local chunks = shaderpack.chunks
local lighting = snow.lighting or {}
snow.lighting = lighting

local STRIDE = snow.STRIDE
local REFINE_CELL, REFINE_DIFF = 64, 4
local YIELD_SAMPLES = 256

local cellKey = snow.CellKey
local UP = Vector(0, 0, 1)
local samplePos = Vector()
local sumR, sumG, sumB, sumN = 0, 0, 0, 0

function lighting.Average()
	if sumN == 0 then return end

	return sumR / sumN, sumG / sumN, sumB / sumN
end

local NEIGHBOURS = {}
for dz = -1, 1 do
	for dy = -1, 1 do
		for dx = -1, 1 do
			if dx ~= 0 or dy ~= 0 or dz ~= 0 then
				NEIGHBOURS[#NEIGHBOURS + 1] = cellKey(dx * REFINE_CELL, dy * REFINE_CELL, dz * REFINE_CELL, REFINE_CELL) - cellKey(0, 0, 0, REFINE_CELL)
			end
		end
	end
end

local function lightDiff(a, b)
	return math.max(math.abs(math.floor(a / 65536) - math.floor(b / 65536)), math.abs(math.floor(a / 256) % 256 - math.floor(b / 256) % 256), math.abs(a % 256 - b % 256))
end

function lighting.Bake(ch, verts, tris)
	local yieldIfOverBudget = chunks.YieldIfOverBudget
	local samples, lights, cellOf, cellSample, farthest, farthestDist, refine = ch.samples, {}, {}, {}, {}, {}, {}
	local count, computed = #samples / 3, 0

	local function sampleLight(i)
		local at = i * 3
		local x, y, z = samples[at - 2], samples[at - 1], samples[at]
		if bspdata.BeyondWorld(x, y, z) then x, y, z = bspdata.WorldToSky(x, y, z) end
		samplePos:SetUnpacked(x, y, z)
		local l, d = render.ComputeLighting(samplePos, UP), render.ComputeDynamicLighting(samplePos, UP)
		local r, g, b = math.Clamp(l.x - d.x, 0, 2), math.Clamp(l.y - d.y, 0, 2), math.Clamp(l.z - d.z, 0, 2)
		lights[i] = math.floor(r * 127.5) * 65536 + math.floor(g * 127.5) * 256 + math.floor(b * 127.5)
		sumR, sumG, sumB, sumN = sumR + r, sumG + g, sumB + b, sumN + 1
		computed = computed + 1
		if computed % YIELD_SAMPLES == 0 then yieldIfOverBudget() end
	end

	for i = 1, count do
		local at = i * 3
		local x, y, z = samples[at - 2], samples[at - 1], samples[at]
		local key = cellKey(x, y, z, REFINE_CELL)
		cellOf[i] = key
		local rep = cellSample[key]
		if not rep then
			cellSample[key] = i
			sampleLight(i)
		else
			local ra = rep * 3
			local dx, dy, dz = x - samples[ra - 2], y - samples[ra - 1], z - samples[ra]
			local dist = dx * dx + dy * dy + dz * dz
			if not farthest[key] or dist > farthestDist[key] then
				farthest[key], farthestDist[key] = i, dist
			end
		end
	end

	for key, i in pairs(cellSample) do
		local light, other = lights[i], farthest[key]
		if other then
			sampleLight(other)
			refine[key] = lightDiff(light, lights[other]) > REFINE_DIFF
		end

		if not refine[key] then
			for _, offset in ipairs(NEIGHBOURS) do
				local nb = cellSample[key + offset]
				if nb and lightDiff(light, lights[nb]) > REFINE_DIFF then
					refine[key] = true
					break
				end
			end
		end
	end

	for i = 1, count do
		if not lights[i] then
			local key = cellOf[i]
			if refine[key] then
				sampleLight(i)
			else
				lights[i] = lights[cellSample[key]]
			end
		end
	end

	for o = 6, tris * 3 * STRIDE, STRIDE do
		verts[o] = lights[verts[o]] or 0
	end

	ch.samples = nil
end
