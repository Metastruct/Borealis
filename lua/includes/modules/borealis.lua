if SERVER then AddCSLuaFile() end

require("bspdata")

local FILES = {
	"core/sh_shaderpack",
	"core/sh_depthslices",
	"core/cl_wind",
	"sky/sh_sky",
	"sky/sh_sunshafts",
	"core/cl_chunks",
	"core/sh_trails",
	"core/cl_skywall",
	"core/cl_dynamic_lights",
	"core/cl_depth_hacks",
	"core/sh_cover",
	"core/cl_local_lights",
	"core/sh_skybox3d",
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
	"weather/sh_drips",
	"weather/snow/sh_core",
	"liquids/sh_lava",
	"liquids/sh_lava_splash",
	"sky/sh_vcloud_shadows",
	"lighting/sh_ssao",
	"lighting/sh_grade",
	"core/cl_bench",
	"menu/cl_credits",
	"menu/cl_menu",
	"menu/sv_menu",
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

if CLIENT then hook.Add("InitPostEntity", "borealis_migrate_convars", shaderpack.MigrateConVars) end
