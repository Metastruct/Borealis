local snow = shaderpack.snow
local geometry = snow.geometry or {}
snow.geometry = geometry

local bspdata = bspdata
local CHUNK = snow.CHUNK
local MIN_NZ = 0.3

local triangles, edges

local function classify(name)
	if name:lower():find("^tools/") or Material(name):GetShader():lower():find("water", 1, true) then return end

	return 1
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

local submerged = snow.Submerged

function geometry.Load()
	local grid, why = bspdata.Triangles(classify, MIN_NZ, true, SURF_TRANS)
	if not grid then return false, why end

	grid = bspdata.RemoveSkybox(grid)

	local yieldIfOverBudget = bspdata.FrameBudget()
	local seen, open, normals, up = {}, {}, {}, {}
	for _, cell in pairs(grid) do
		for _, t in ipairs(cell) do
			if not seen[t] then
				seen[t] = true
				t.nx, t.ny, t.nz = triNormal(t)
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
						if open[key] == nil then
							open[key] = { t, e }
						else
							open[key] = false
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
	for _, rec in pairs(open) do
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
						local key = snow.ChunkKey(cx, cy)
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

	triangles, edges = grid, egrid

	return true
end

function geometry.Triangles()
	return triangles
end

function geometry.Edges(cx, cy)
	return edges and edges[snow.ChunkKey(cx, cy)] or {}
end

function geometry.Clear()
	triangles, edges = nil, nil
end
