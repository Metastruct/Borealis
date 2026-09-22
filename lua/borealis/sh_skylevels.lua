if SERVER then return end

skylevels = skylevels or {}

local SEEDS = {
	{ landmark = "land_build", floor = -13096, ceiling = 511 },
	{ landmark = "land_fish1", floor = 12217, ceiling = 15375 },
	{ landmark = "zen", floor = 8018, ceiling = 8651 },
	{ landmark = "hevn", floor = 6512, ceiling = 8307, clouds = 1500 }, -- cloud is relative
	-- Add more landmarks here if we have more outside areas...
}

local SLACK_BELOW, SLACK_ABOVE = 1000, 64
local RETRY = 0.5

local function band(seed, floor, ceiling, pos)
	return {
		floor = floor,
		ceiling = ceiling,
		clouds = seed.clouds and floor + seed.clouds or nil,
		x = pos and pos.x,
		y = pos and pos.y,
		min = floor - SLACK_BELOW,
		max = ceiling + SLACK_ABOVE,
	}
end

local fallback = {}
for i = 1, #SEEDS do
	fallback[i] = band(SEEDS[i], SEEDS[i].floor, SEEDS[i].ceiling)
end

local levels = {}
local pending = #SEEDS
local nextTry = 0

local function seedLevel(seed)
	local pos = landmark and landmark.get and landmark.get(seed.landmark)
	if not pos then return end

	local up = util.TraceLine({ start = pos, endpos = pos + Vector(0, 0, 20000), mask = MASK_SOLID_BRUSHONLY })
	if not up.Hit or not up.HitSky then return end
	local down = util.TraceLine({ start = pos, endpos = pos - Vector(0, 0, 8000), mask = MASK_SOLID_BRUSHONLY })

	return band(seed, down.Hit and down.HitPos.z or pos.z, up.HitPos.z, pos)
end

local function resolve()
	if pending == 0 then return end
	local now = RealTime()
	if now < nextTry then return end
	nextTry = now + RETRY

	for i = 1, #SEEDS do
		if not levels[i] then
			local l = seedLevel(SEEDS[i])
			if l then
				levels[i] = l
				pending = pending - 1
			end
		end
	end
end

function skylevels.Get()
	resolve()
	local eye = EyePos()
	local best, nearest

	for i = 1, #SEEDS do
		local l = levels[i] or fallback[i]
		if eye.z >= l.min and eye.z <= l.max then
			local dist = l.x and (eye.x - l.x) ^ 2 + (eye.y - l.y) ^ 2 or math.huge
			if not best or dist < nearest then
				best, nearest = l, dist
			end
		end
	end

	return best
end
