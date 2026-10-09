local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

if SERVER then
	if not resource.AddShader then return end

	resource.AddShader("grass_vs30")
	resource.AddShader("grass_ps30")
	resource.AddShader("grassdepth_ps30")

	return
end

local GRASS_ENABLED = CreateClientConVar("cl_draw_grass", "0", true, false, "draw grass tufts on grass surfaces")
local GRASS_DISTANCE = CreateClientConVar("cl_draw_grass_distance", "3072", true, false, "grass draw distance in units", 1024, 16384)

local month = tonumber(os.date("%m")) or 0
local WINTER = month >= 12 or month <= 2
local AUTUMN = false
local DENSITY, HEIGHT, DRYNESS, ROOT_COLOR, TIP_COLOR, DRY_COLOR

local function setSeason(winter, autumn)
	WINTER, AUTUMN = winter, autumn
	DENSITY = winter and 0.35 or 1 -- share of the tufts kept
	HEIGHT = winter and 0.7 or 1
	DRYNESS = winter and 1 or autumn and 0.6 or 0.15 -- 0 green .. 1 golden
	ROOT_COLOR = winter and { 0.09, 0.085, 0.06 } or autumn and { 0.07, 0.06, 0.02 } or { 0.06, 0.075, 0.02 }
	TIP_COLOR = autumn and { 0.13, 0.15, 0.045 } or { 0.15, 0.19, 0.05 }
	DRY_COLOR = winter and { 0.28, 0.25, 0.17 } or autumn and { 0.32, 0.2, 0.06 } or { 0.24, 0.21, 0.09 } -- tip colour of dry blades
end

setSeason(WINTER, AUTUMN)

local MAX_SLOPE_Z = 0.7 -- skip faces steeper than this normal z
local WIND_ANGLE = math.atan2(0.6, 0.8)
local WIND = 0.45 -- bend at the tip, in quad widths
local TRANSLUCENCY = 0.35

local packColor = foliage.PackColor

local function grassMode(name)
	local mat = Material(name)
	local sp = (mat:GetString("$surfaceprop") or ""):lower()
	local sp2 = (mat:GetString("$surfaceprop2") or ""):lower()
	if sp == "grass" and (sp2 == "" or sp2 == "grass") then
		return 1
	elseif sp == "grass" then
		return 2
	elseif sp2 == "grass" then
		return 3
	end
end

local basePos = Vector()
local function keep(x, y, z, r)
	if r > DENSITY then return false end
	basePos:SetUnpacked(x, y, z + 1)

	return bit.band(util.PointContents(basePos), MASK_WATER) == 0
end

local lastWet = 0
local function palette(mat, depthMat)
	mat:SetFloat("$c1_x", WIND_ANGLE)
	mat:SetFloat("$c1_z", WIND)
	mat:SetFloat("$c2_y", packColor(unpack(ROOT_COLOR)))
	mat:SetFloat("$c2_z", packColor(unpack(TIP_COLOR)))
	mat:SetFloat("$c3_x", TRANSLUCENCY)
	mat:SetFloat("$c3_y", DRYNESS)
	mat:SetFloat("$c3_z", packColor(unpack(DRY_COLOR)))
	if depthMat then
		depthMat:SetFloat("$c1_x", WIND_ANGLE)
		depthMat:SetFloat("$c1_z", WIND)
	end

	lastWet = -1
end

local function frame(mat)
	local wet = tod and tod.rain and tod.rain.amount or 0
	if wet == lastWet then return end
	lastWet = wet
	local k = 1 - 0.3 * wet
	mat:SetFloat("$c2_y", packColor(ROOT_COLOR[1] * k, ROOT_COLOR[2] * k, ROOT_COLOR[3] * k))
	mat:SetFloat("$c2_z", packColor(TIP_COLOR[1] * k, TIP_COLOR[2] * (1 - 0.2 * wet), TIP_COLOR[3] * k))
	mat:SetFloat("$c3_z", packColor(DRY_COLOR[1] * k, DRY_COLOR[2] * k, DRY_COLOR[3] * k))
end

local layer = foliage.Layer({
	name = "grass",
	pixelShader = "grass_ps30", vertexShader = "grass_vs30", depthShader = "grassdepth_ps30",
	classify = grassMode, minNormalZ = MAX_SLOPE_Z,
	spacing = 18, jitter = 8, quadW = 26, quadH = 40,
	keep = keep, palette = palette, frame = frame,
})
layer.height = HEIGHT

local function setDistance()
	layer:SetDistance(math.Clamp(GRASS_DISTANCE:GetInt(), 1024, 16384))
end

setDistance()

local function shadersAvailable()
	return file.Exists("shaders/fxc/grass_ps30.vcs", "GAME") and file.Exists("shaders/fxc/grass_vs30.vcs", "GAME")
end

local function apply()
	if not GRASS_ENABLED:GetBool() then
		layer:Stop()
		return
	end

	if shadersAvailable() then
		layer:Start()
	elseif HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
		hook.Add("ShaderMounted", "ms_grass", function()
			hook.Remove("ShaderMounted", "ms_grass")
			if GRASS_ENABLED:GetBool() and shadersAvailable() then
				layer:Start()
			end
		end)
	end
end

cvars.RemoveChangeCallback("cl_draw_grass", "ms_grass")
cvars.AddChangeCallback("cl_draw_grass", apply, "ms_grass")
cvars.RemoveChangeCallback("cl_draw_grass_distance", "ms_grass")
cvars.AddChangeCallback("cl_draw_grass_distance", setDistance, "ms_grass")
hook.Remove("ShaderMounted", "ms_grass")

hook.Add("TOD_WinterRemoved", "ms_grass", function()
	if not WINTER then return end
	setSeason(false, AUTUMN)
	layer.height = HEIGHT
	apply()
end)

hook.Add("TOD_Autumn", "ms_grass", function()
	if WINTER or AUTUMN then return end
	setSeason(false, true)
	if layer.mat then
		layer.mat:SetFloat("$c3_y", DRYNESS)
		lastWet = -1
	end
end)

if LocalPlayer and IsValid(LocalPlayer()) then
	apply()
else
	hook.Add("InitPostEntity", "ms_grass", function()
		hook.Remove("InitPostEntity", "ms_grass")
		apply()
	end)
end
