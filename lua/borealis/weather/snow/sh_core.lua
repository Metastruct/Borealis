local snow = shaderpack.snow or {}
shaderpack.snow = snow

snow.PS, snow.VS, snow.DEPTH_PS = "borealis_snowcover_ps30", "borealis_water_vs30", "borealis_waterdepth_ps30"
snow.NOISE = "shaderpack/procsky/fognoise"
snow.SHADERS = { snow.PS, snow.VS, snow.DEPTH_PS, "borealis_trailstamp_ps30" }

if SERVER then
	shaderpack.AddResources(snow.SHADERS, { snow.NOISE })
end

snow.IMPACT_NET = "borealis_snow_impact"
snow.DEPTH = 10
snow.CHUNK = 512
snow.STRIDE = 7
snow.SKY_DISTANCE = 16384
snow.RAY_HEIGHT = 4
snow.SKY_BAND = 3072
snow.SEAM_OFFSET = 8

local bakeStart, bakeBudget = 0, math.huge
local skyTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = {} }
local waterPos = Vector()
function snow.BandChunks()
	local band = bspdata.SkyBand(snow.SKY_BAND)
	if not band then return -math.huge, -math.huge, math.huge, math.huge end

	local size = snow.CHUNK

	return math.floor(band[1] / size), math.floor(band[2] / size), math.floor(band[3] / size), math.floor(band[4] / size)
end

function snow.ClusterAt(x, y, z)
	if bspdata.BeyondWorld(x, y, z) then return bspdata.SKY_CLUSTER end

	return math.max(bspdata.ClusterAt(x, y, z), -1)
end

function snow.ChunkKey(cx, cy)
	return cx * 65536 + cy
end

function snow.ChunkAt(x, y)
	return math.floor(x / snow.CHUNK), math.floor(y / snow.CHUNK)
end

function snow.CellKey(x, y, z, size)
	return (math.floor(x / size) + 4096) * 67108864 + (math.floor(y / size) + 4096) * 8192 + math.floor(z / size) + 4096
end

function snow.SetBakeBudget(ms)
	bakeStart, bakeBudget = SysTime(), ms
end

function snow.Yield()
	local chunks = shaderpack.chunks
	if chunks then
		chunks.YieldIfOverBudget()
	elseif (SysTime() - bakeStart) * 1000 > bakeBudget then
		coroutine.yield()
	end
end

local function skyRay(x, y, z)
	skyTrace.start:SetUnpacked(x, y, z)
	skyTrace.endpos:SetUnpacked(x, y, z + snow.SKY_DISTANCE)

	return bspdata.TraceLine(skyTrace)
end

local function coveredRay(x, y, z)
	local tr = skyRay(x, y, z)

	return not tr.StartSolid and tr.Hit and not tr.HitSky
end

function snow.SeamLeak(x, y, z)
	local o = snow.SEAM_OFFSET

	return coveredRay(x + o, y, z) and coveredRay(x - o, y, z) or coveredRay(x, y + o, z) and coveredRay(x, y - o, z)
end

function snow.SeesSky(x, y, z)
	local tr = skyRay(x, y, z)
	if tr.StartSolid then return false, true end
	if tr.Hit and not tr.HitSky then return false, false end

	return not snow.SeamLeak(x, y, z), false
end

function snow.Submerged(x, y, z)
	waterPos:SetUnpacked(x, y, z + 2)

	return bit.band(bspdata.PointContents(waterPos), MASK_WATER) ~= 0
end

local FILES = {
	"sh_geometry",
	"sh_heightfield",
	"sh_surface",
	"cl_heightfield_debug",
	"sh_mesh_builder",
	"sh_cache",
	"sv_bake",
	"cl_download",
	"cl_lighting",
	"cl_trails",
	"cl_flashlight",
	"cl_footsteps",
	"cl_powder",
	"cl_breath",
	"cl_impacts",
	"sv_impacts",
	"cl_render",
}

for _, name in ipairs(FILES) do
	local path = "borealis/weather/snow/" .. name .. ".lua"
	local prefix = name:sub(1, 3)

	if SERVER then
		if prefix ~= "sv_" then AddCSLuaFile(path) end
		if prefix ~= "cl_" then include(path) end
	elseif prefix ~= "sv_" then
		include(path)
	end
end
