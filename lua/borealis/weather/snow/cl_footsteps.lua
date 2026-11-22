local snow = shaderpack.snow
local footsteps = snow.footsteps or {}
snow.footsteps = footsteps

local DEPTH, STRIDE = snow.DEPTH, snow.STRIDE
local CELL = 32

local cellKey = snow.CellKey

function footsteps.SetGrid(g)
	footsteps.grid = g
end

function footsteps.MarkCells(snowCells, verts, o)
	local a, b, c = o, o + STRIDE, o + STRIDE * 2
	local x0, x1 = math.min(verts[a + 1], verts[b + 1], verts[c + 1]), math.max(verts[a + 1], verts[b + 1], verts[c + 1])
	local y0, y1 = math.min(verts[a + 2], verts[b + 2], verts[c + 2]), math.max(verts[a + 2], verts[b + 2], verts[c + 2])
	local z0, z1 = math.min(verts[a + 3], verts[b + 3], verts[c + 3]), math.max(verts[a + 3], verts[b + 3], verts[c + 3])
	local ix, iy = math.floor(x0 / CELL), math.floor(y0 / CELL)
	for x = ix, math.max(ix, math.ceil(x1 / CELL) - 1) do
		for y = iy, math.max(iy, math.ceil(y1 / CELL) - 1) do
			for z = math.floor(z0 / CELL), math.floor(z1 / CELL) do
				snowCells[cellKey(x * CELL, y * CELL, z * CELL, CELL)] = true
			end
		end
	end
end

function footsteps.OnSnow(pos)
	local grid = footsteps.grid
	local ch = grid and grid.chunks and grid.chunks[snow.ChunkKey(snow.ChunkAt(pos.x, pos.y))]
	local snowCells = ch and ch.snowCells

	return snowCells ~= nil and (snowCells[cellKey(pos.x, pos.y, pos.z, CELL)] or snowCells[cellKey(pos.x, pos.y, pos.z + DEPTH, CELL)]) == true
end

local function snowTextured(sound)
	sound = sound:lower()

	return (sound:find("grass", 1, true) or sound:find("dirt", 1, true)) and shaderpack.Season() == "winter"
end

hook.Add("PlayerFootstep", "borealis_snow", function(ply, pos, _, sound, volume)
	if not footsteps.OnSnow(pos) and not snowTextured(sound) then return end

	ply:EmitSound("player/footsteps/snow" .. math.random(6) .. ".wav", 75, math.random(95, 105), volume)

	return true
end)
