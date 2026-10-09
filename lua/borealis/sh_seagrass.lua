local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

if SERVER then
	if not resource.AddShader then return end

	resource.AddShader("seagrass_ps30")
	resource.AddShader("seagrassdepth_ps30")

	return
end

local SEAGRASS_ENABLED = CreateClientConVar("cl_draw_seagrass", "0", true, false, "draw seagrass meadows on sunlit sandy water beds")

local PIXEL_SHADER, DEPTH_SHADER, VERTEX_SHADER = "seagrass_ps30", "seagrassdepth_ps30", "grass_vs30"
local RADIUS = 2048
local MIN_DEPTH, MAX_DEPTH, DEPTH_FADE = 40, 350, 60
local WARP_CELL, WARP = 1200, 900
local PATCH_CELL, DETAIL_CELL, FINE_CELL = 1000, 350, 120
local PATCH_FROM, PATCH_TO = 0.5, 0.66
local MAX_DENSITY = 0.3
local STRAY = 0.015
local MIN_LIGHT = 0.15
local SWAY = 0.22
local SURFACE_PROBE = 4096
local ROOT_COLOR = { 0.03, 0.05, 0.02 }
local TIP_COLOR = { 0.09, 0.14, 0.05 }

local SAND = { sand = true, antlionsand = true }

local packColor = foliage.PackColor

local function sandMode(name)
	local mat = Material(name)
	local sp = (mat:GetString("$surfaceprop") or ""):lower()
	local sp2 = (mat:GetString("$surfaceprop2") or ""):lower()
	if SAND[sp] and (sp2 == "" or SAND[sp2]) then
		return 1
	elseif SAND[sp] then
		return 2
	elseif SAND[sp2] then
		return 3
	end
end

local function lattice(ix, iy)
	local h = (ix * 73856093 + iy * 19349663) % 2147483648
	h = (h * 1103515245 + 12345) % 2147483648
	h = (h * 1103515245 + 12345) % 2147483648

	return h / 2147483648
end

local function valueNoise(x, y, cell)
	local fx, fy = x / cell, y / cell
	local ix, iy = math.floor(fx), math.floor(fy)
	local tx, ty = fx - ix, fy - iy
	tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
	local a, b = lattice(ix, iy), lattice(ix + 1, iy)
	local c, d = lattice(ix, iy + 1), lattice(ix + 1, iy + 1)
	local top = a + (b - a) * tx

	return top + (c + (d - c) * tx - top) * ty
end

local function smoothstep(e0, e1, v)
	local t = math.Clamp((v - e0) / (e1 - e0), 0, 1)

	return t * t * (3 - 2 * t)
end

local function patchDensity(x, y)
	local wx = valueNoise(x + 1700, y - 900, WARP_CELL) - 0.5
	local wy = valueNoise(x - 2300, y + 4100, WARP_CELL) - 0.5
	x, y = x + wx * WARP, y + wy * WARP
	local n = valueNoise(x, y, PATCH_CELL) * 0.6 + valueNoise(x + 5000, y - 3000, DETAIL_CELL) * 0.3 + valueNoise(x - 7000, y + 2000, FINE_CELL) * 0.1

	return smoothstep(PATCH_FROM, PATCH_TO, n)
end

local basePos = Vector()
local function keep(x, y, z, r)
	basePos:SetUnpacked(x, y, z + 1)
	if bit.band(util.PointContents(basePos), CONTENTS_WATER) == 0 then return false end

	local surface = bspdata.WaterSurfaceAt(x, y, z + 1)
	if not surface then return false end

	local depth = surface - z
	if depth < MIN_DEPTH or depth > MAX_DEPTH then return false end

	local fade = smoothstep(MIN_DEPTH, MIN_DEPTH + DEPTH_FADE, depth) * (1 - smoothstep(MAX_DEPTH - DEPTH_FADE, MAX_DEPTH, depth))
	local density = patchDensity(x, y) * fade
	if r <= density * MAX_DENSITY then return 0.35 + 0.65 * density end
	if r <= STRAY * fade then return 0.3 end

	return false
end

local function palette(mat, depthMat)
	mat:SetFloat("$c1_z", SWAY)
	mat:SetFloat("$c2_y", packColor(unpack(ROOT_COLOR)))
	mat:SetFloat("$c2_z", packColor(unpack(TIP_COLOR)))
	if depthMat then depthMat:SetFloat("$c1_z", SWAY) end
end

local probeRes = {}
local probe = { mask = MASK_WATER, output = probeRes }
local probeEnd = Vector()
local function surfaceNear(eye)
	if bit.band(util.PointContents(eye), CONTENTS_WATER) ~= 0 then return bspdata.WaterSurfaceAt(eye.x, eye.y, eye.z) end

	probeEnd:SetUnpacked(eye.x, eye.y, eye.z - SURFACE_PROBE)
	probe.start, probe.endpos = eye, probeEnd
	util.TraceLine(probe)

	return probeRes.Hit and probeRes.HitPos.z or nil
end

local lastNormalMap
local function frame(mat)
	local eye = EyePos()
	local surfaceZ = surfaceNear(eye)
	local normalmap, sun, sunlit
	if surfaceZ and surfacewater and surfacewater.CausticSource then
		normalmap, sun, sunlit = surfacewater.CausticSource(eye, surfaceZ)
	end

	if normalmap and normalmap ~= lastNormalMap then
		lastNormalMap = normalmap
		mat:SetTexture("$basetexture", normalmap)
	end

	local k = normalmap and (tonumber(sunlit) or (sunlit and 1 or 0)) or 0
	mat:SetFloat("$c1_x", surfaceZ or -1e6)
	mat:SetFloat("$c3_x", sun and sun.x * k or 0)
	mat:SetFloat("$c3_y", sun and sun.y * k or 0)
	mat:SetFloat("$c3_z", sun and sun.z * k or 0)
end

local layer = foliage.Layer({
	name = "seagrass",
	pixelShader = PIXEL_SHADER, vertexShader = VERTEX_SHADER, depthShader = DEPTH_SHADER,
	classify = sandMode, minNormalZ = 0.7,
	spacing = 14, jitter = 7, quadW = 26, quadH = 72,
	keep = keep, minLight = MIN_LIGHT, timeWrap = 3600,
	palette = palette, frame = frame,
})
layer:SetDistance(RADIUS)

local function shadersAvailable()
	return file.Exists("shaders/fxc/" .. PIXEL_SHADER .. ".vcs", "GAME") and file.Exists("shaders/fxc/" .. VERTEX_SHADER .. ".vcs", "GAME")
end

local function apply()
	if not SEAGRASS_ENABLED:GetBool() then
		layer:Stop()
		return
	end

	lastNormalMap = nil
	if shadersAvailable() then
		layer:Start()
	elseif HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
		hook.Add("ShaderMounted", "ms_seagrass", function()
			hook.Remove("ShaderMounted", "ms_seagrass")
			if SEAGRASS_ENABLED:GetBool() and shadersAvailable() then
				layer:Start()
			end
		end)
	end
end

cvars.RemoveChangeCallback("cl_draw_seagrass", "ms_seagrass")
cvars.AddChangeCallback("cl_draw_seagrass", apply, "ms_seagrass")
hook.Remove("ShaderMounted", "ms_seagrass")

if LocalPlayer and IsValid(LocalPlayer()) then
	apply()
else
	hook.Add("InitPostEntity", "ms_seagrass", function()
		hook.Remove("InitPostEntity", "ms_seagrass")
		apply()
	end)
end
