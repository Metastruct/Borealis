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

function lighting.Resolve(ch, verts, tris)
	local yieldIfOverBudget = chunks.YieldIfOverBudget
	local samples, lights, cellOf, reps, far, farDist, refine = ch.samples, {}, {}, {}, {}, {}, {}
	local count, computed = #samples / 3, 0

	local function compute(i)
		local at = i * 3
		samplePos:SetUnpacked(samples[at - 2], samples[at - 1], samples[at])
		local l, d = render.ComputeLighting(samplePos, UP), render.ComputeDynamicLighting(samplePos, UP)
		lights[i] = math.Clamp(math.floor((l.x - d.x) * 127.5), 0, 255) * 65536 + math.Clamp(math.floor((l.y - d.y) * 127.5), 0, 255) * 256 + math.Clamp(math.floor((l.z - d.z) * 127.5), 0, 255)
		computed = computed + 1
		if computed % YIELD_SAMPLES == 0 then yieldIfOverBudget() end
	end

	for i = 1, count do
		local at = i * 3
		local x, y, z = samples[at - 2], samples[at - 1], samples[at]
		local key = cellKey(x, y, z, REFINE_CELL)
		cellOf[i] = key
		local rep = reps[key]
		if not rep then
			reps[key] = i
			compute(i)
		else
			local ra = rep * 3
			local dx, dy, dz = x - samples[ra - 2], y - samples[ra - 1], z - samples[ra]
			local dist = dx * dx + dy * dy + dz * dz
			if not far[key] or dist > farDist[key] then
				far[key], farDist[key] = i, dist
			end
		end
	end

	for key, i in pairs(reps) do
		local light, other = lights[i], far[key]
		if other then
			compute(other)
			refine[key] = lightDiff(light, lights[other]) > REFINE_DIFF
		end

		if not refine[key] then
			for _, offset in ipairs(NEIGHBOURS) do
				local nb = reps[key + offset]
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
				compute(i)
			else
				lights[i] = lights[reps[key]]
			end
		end
	end

	for o = 6, tris * 3 * STRIDE, STRIDE do
		verts[o] = lights[verts[o]] or 0
	end

	ch.samples = nil
end
