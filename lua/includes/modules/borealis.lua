if SERVER then AddCSLuaFile() end

local FILES = {
	"core/sh_shaderpack",
	"core/sh_depthslices",
	"core/cl_wind",
	"sky/sh_sky",
	"sky/sh_sunshafts",
	"core/sh_bsp",
	"core/cl_chunks",
	"core/cl_skywall",
	"core/cl_dynamic_lights",
	"core/cl_depth_hacks",
	"core/sh_cover",
	"core/sv_halo",
	"sky/sh_vclouds",
	"sky/sh_cheap_clouds",
	"sky/sh_aurora",
	"liquids/sh_water",
	"liquids/sh_ice",
	"foliage/cl_foliage",
	"foliage/sh_grass",
	"foliage/sh_seagrass",
	"foliage/sh_kelp",
	"foliage/sh_leaves",
	"weather/sh_precipitations",
	"weather/sh_fog",
	"weather/sh_wetness",
	"weather/sh_snowspans",
	"weather/sh_snowcover",
	"liquids/sh_lava",
	"liquids/sh_lava_splash",
	"sky/sh_vcloud_shadows",
	"lighting/sh_ssao",
	"lighting/sh_grade",
	"core/cl_bench",
}

for _, name in ipairs(FILES) do
	local path = "borealis/" .. name .. ".lua"
	local prefix = name:match("[^/]+$"):sub(1, 3)

	if SERVER then
		if prefix ~= "sv_" then AddCSLuaFile(path) end
		if prefix ~= "cl_" then include(path) end
	elseif prefix ~= "sv_" then
		include(path)
	end
end

if CLIENT then shaderpack.MigrateConVars() end
