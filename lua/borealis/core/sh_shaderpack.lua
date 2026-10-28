shaderpack = shaderpack or {}

local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

local function le16(v)
	return string.char(v % 256, math.floor(v / 256) % 256)
end

local function le32(v)
	return le16(v % 65536) .. le16(math.floor(v / 65536))
end

function shaderpack.VTFHeader(w, h, format, flags)
	local header = "VTF\0" .. le32(7) .. le32(2) .. le32(80) .. le16(w) .. le16(h) .. le32(flags) .. le16(1) .. le16(0) .. le32(0)
		.. "\0\0\0\63\0\0\0\63\0\0\0\63" .. le32(0) .. "\0\0\128\63" .. le32(format) .. string.char(1) .. "\255\255\255\255" .. string.char(0, 0) .. le16(1)

	return header .. string.rep("\0", 80 - #header)
end

if SERVER then
	function shaderpack.AddResources(shaders, textures)
		if resource.AddShader then
			for _, name in ipairs(shaders) do
				resource.AddShader(name)
			end
		end

		for _, tex in ipairs(textures or {}) do
			resource.AddFile("materials/" .. tex .. ".vtf")
		end
	end

	return
end

local mountedShaders = {}
local presentTextures, missingTextures = {}, {}

function shaderpack.Available(shaders, textures)
	for _, name in ipairs(shaders) do
		if not mountedShaders[name] then
			if not file.Exists("shaders/fxc/" .. name .. ".vcs", "GAME") then return false end
			mountedShaders[name] = true
		end
	end

	for _, tex in ipairs(textures or {}) do
		if not presentTextures[tex] then
			if not file.Exists("materials/" .. tex .. ".vtf", "GAME") then
				if not missingTextures[tex] then
					missingTextures[tex] = true
					MsgN("shaderpack: materials/" .. tex .. ".vtf is missing, check cl_downloadfilter")
				end

				return false
			end
			presentTextures[tex] = true
		end
	end

	return true
end

function shaderpack.WhenMounted(id, shaders, start, textures)
	hook.Remove("ShaderMounted", id)
	if shaderpack.Available(shaders, textures) then
		start()
		return true
	end

	if HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
		hook.Add("ShaderMounted", id, function()
			hook.Remove("ShaderMounted", id)
			if shaderpack.Available(shaders, textures) then
				start()
			end
		end)
	end

	return false
end

local MASTER = CreateClientConVar("cl_shaderpack", "1", true, false, "draw the shaderpack effects, overrides every cl_draw_* convar when off")

shaderpack.toggles = shaderpack.toggles or { order = {}, apply = {} }

function shaderpack.Enabled()
	return MASTER:GetBool()
end

function shaderpack.Toggle(id, convar, shaders, start, stop, textures)
	local toggles = shaderpack.toggles

	local function apply()
		if not toggles.apply[id] then
			toggles.order[#toggles.order + 1] = id
		end
		toggles.apply[id] = apply

		if not MASTER:GetBool() or (convar and not convar:GetBool()) then
			hook.Remove("ShaderMounted", id)
			stop()
			return
		end

		shaderpack.WhenMounted(id, shaders, start, textures)
	end

	if convar then
		cvars.RemoveChangeCallback(convar:GetName(), id)
		cvars.AddChangeCallback(convar:GetName(), apply, id)
	end

	return apply
end

local pendingToggles = {}

local function applyNextToggle()
	local id = table.remove(pendingToggles, 1)
	if not id then
		hook.Remove("Think", "shaderpack_toggles")
		return
	end

	local ok, err = pcall(shaderpack.toggles.apply[id])
	if not ok then
		ErrorNoHalt("shaderpack: " .. id .. ": " .. tostring(err) .. "\n")
	end
end

cvars.RemoveChangeCallback("cl_shaderpack", "shaderpack")
cvars.AddChangeCallback("cl_shaderpack", function()
	pendingToggles = table.Add({}, shaderpack.toggles.order)
	hook.Add("Think", "shaderpack_toggles", applyNextToggle)
end, "shaderpack")

function shaderpack.AfterWorld(id, fn)
	if LocalPlayer and IsValid(LocalPlayer()) then
		fn()
		return
	end

	hook.Add("InitPostEntity", id, function()
		hook.Remove("InitPostEntity", id)
		fn()
	end)
end

function shaderpack.UsableRT(t, w, h)
	if t == nil or t:IsError() then return false end
	if w then return t:Width() == w and (h == nil or t:Height() == h) end

	return t:Width() > 64
end

function shaderpack.PackColor(r, g, b)
	return math.floor(math.Clamp(r, 0, 1) * 255) * 65536 + math.floor(math.Clamp(g, 0, 1) * 255) * 256 + math.floor(math.Clamp(b, 0, 1) * 255)
end

function shaderpack.ToLinear(c)
	c = c / 255

	return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

function shaderpack.SunDir()
	local procsky = shaderpack.procsky
	if procsky and procsky.GetLights then
		return procsky.GetLights()
	elseif tod and tod.CurrentParams and isangle(tod.CurrentParams.sun_angles) then
		return -tod.CurrentParams.sun_angles:Forward()
	end

	return Vector(0, 0, 1)
end

function shaderpack.Season()
	if tod and tod.GetSeason then return tod.GetSeason() end

	local month = tonumber(os.date("%m")) or 0
	if month >= 12 or month <= 2 then return "winter" end
	if month == 10 or month == 11 then return "autumn" end

	return "summer"
end

function shaderpack.Elevation(dir)
	return math.deg(math.asin(math.Clamp(dir.z, -1, 1)))
end

function shaderpack.Overcast()
	local procsky = shaderpack.procsky

	return procsky and procsky.GetOvercast and procsky.GetOvercast() or 0
end

function shaderpack.ViewTan()
	local vs = render.GetViewSetup()
	local halfW = math.tan(math.rad(vs.fov) * 0.5)

	return halfW, halfW / vs.aspect, vs
end

local KEYS = {}
for i = 0, 3 do
	local reg = "$c" .. i
	KEYS[reg] = { reg .. "_x", reg .. "_y", reg .. "_z", reg .. "_w" }
end

function shaderpack.SetConstant(mat, reg, x, y, z, w)
	local keys = KEYS[reg]
	if x then mat:SetFloat(keys[1], x) end
	if y then mat:SetFloat(keys[2], y) end
	if z then mat:SetFloat(keys[3], z) end
	if w then mat:SetFloat(keys[4], w) end
end

local cubeModel
function shaderpack.SetVertexConstants(rows)
	if not IsValid(cubeModel) then
		cubeModel = ClientsideModel("models/shadertest/vertexlit.mdl")
		cubeModel:SetNoDraw(true)
		cubeModel:SetModelScale(0)
	end

	render.SuppressEngineLighting(true)
	for i = 0, 5 do
		local r = rows[i + 1]
		if r then
			render.SetModelLighting(i, r[1], r[2], r[3])
		else
			render.SetModelLighting(i, 0, 0, 0)
		end
	end

	cubeModel:DrawModel()
	render.SuppressEngineLighting(false)
end
