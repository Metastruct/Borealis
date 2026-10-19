if SERVER then AddCSLuaFile() end

local FILES = {
	"core/sh_shaderpack",
	"core/sh_depthslices",
	"core/cl_wind",
	"sky/sh_sky",
	"sky/sh_sunshafts",
	"core/sh_bsp",
	"core/cl_depth_hacks",
	"core/sh_cover",
	"sky/sh_vclouds",
	"sky/sh_cheap_clouds",
	"sky/sh_aurora",
	"liquids/sh_water",
	"foliage/cl_foliage",
	"foliage/sh_grass",
	"foliage/sh_seagrass",
	"foliage/sh_kelp",
	"foliage/sh_leaves",
	"weather/sh_precipitations",
	"weather/sh_fog",
	"weather/sh_wetness",
	"liquids/sh_lava",
	"liquids/sh_lava_splash",
	"sky/sh_vcloud_shadows",
	"lighting/sh_ssao",
	"core/cl_bench",
}

for _, name in ipairs(FILES) do
	local path = "borealis/" .. name .. ".lua"
	local clientOnly = name:match("[^/]+$"):sub(1, 3) == "cl_"

	if SERVER then
		AddCSLuaFile(path)
		if not clientOnly then include(path) end
	else
		include(path)
	end
end
