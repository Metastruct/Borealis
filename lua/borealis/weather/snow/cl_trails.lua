local snow = shaderpack.snow
local shared = shaderpack.trails
local trails = snow.trails or {}
snow.trails = trails

local REFILL_TIME, SNOWFALL_TIME = 1200, 120
local SKY_CELL = 16

local cellKey = snow.CellKey

local function reachesSky(x, y, z, rays)
	local key = cellKey(x, y, z, SKY_CELL)
	local open = rays[key]
	if open == nil then
		local solid
		open, solid = snow.SeesSky(x, y, z)
		if solid then return false end

		rays[key] = open
	end

	return open
end

local user = {
	channel = 1,
	slices = { snow.DEPTH },
	recover = function()
		local amount = tod and tod.snow and tod.snow.amount or 0

		return 1 / REFILL_TIME + amount / SNOWFALL_TIME
	end,
	accept = function(_, x, y, ground, cache)
		return reachesSky(x, y, ground + snow.RAY_HEIGHT, cache)
	end,
}

function trails.Texture()
	return shared.Texture()
end

function trails.Window()
	return shared.Window()
end

function trails.Start()
	return shared.Use("snow", user)
end

function trails.Stamp(x, y, radius, depth)
	shared.Stamp("snow", x, y, radius, depth)
end

function trails.Stop()
	shared.Use("snow", nil)
end
