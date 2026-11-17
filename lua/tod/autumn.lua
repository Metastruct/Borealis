local DIR = "tod_autumn"
local TINT = Vector(1.7, 1.35, 0.85)
local KEEP = 0.25
local SCALE = 0.5
local LAYERS = { "$basetexture", "$basetexture2" }
local SURFACEPROPS = { ["$basetexture"] = "$surfaceprop", ["$basetexture2"] = "$surfaceprop2" }

tod.autumn = tod.autumn or { originals = {} }
local state = tod.autumn

local function restoreGrass()
	for path, keys in pairs(state.originals) do
		local mat = Material(path)
		for key, tex in pairs(keys) do
			mat:SetTexture(key, tex)
		end
	end
end

local function stop()
	hook.Remove("PostRender", "tod_autumn")
	hook.Remove("ShutDown", "tod_autumn")
end

stop()

local function renderTarget(name, w, h)
	return GetRenderTargetEx(name .. "_" .. w .. "x" .. h, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
end

local srcMat = CreateMaterial("tod_autumn_src", "UnlitGeneric", {
	["$basetexture"] = "",
	["$ignorez"] = 1,
})

local keepMat = CreateMaterial("tod_autumn_keep", "UnlitGeneric", {
	["$basetexture"] = "",
	["$ignorez"] = 1,
	["$translucent"] = 1,
	["$alpha"] = KEEP,
})

local tintMat = CreateMaterial("tod_autumn_tint", "UnlitGeneric", {
	["$basetexture"] = "",
	["$ignorez"] = 1,
})

local greyMat = CreateMaterial("tod_autumn_grey", "g_colourmodify", {
	["$fbtexture"] = "",
	["$ignorez"] = 1,
	["$pp_colour_addr"] = 0,
	["$pp_colour_addg"] = 0,
	["$pp_colour_addb"] = 0,
	["$pp_colour_brightness"] = 0,
	["$pp_colour_contrast"] = 1,
	["$pp_colour_colour"] = 0,
	["$pp_colour_mulr"] = 0,
	["$pp_colour_mulg"] = 0,
	["$pp_colour_mulb"] = 0,
})

local function bakeGrass(tex, path)
	local w, h = math.max(1, math.floor(tex:Width() * SCALE)), math.max(1, math.floor(tex:Height() * SCALE))
	local a, b = renderTarget("tod_autumn_a", w, h), renderTarget("tod_autumn_b", w, h)
	srcMat:SetTexture("$basetexture", tex)
	keepMat:SetTexture("$basetexture", tex)
	keepMat:SetFloat("$alpha", KEEP)
	greyMat:SetTexture("$fbtexture", a)
	tintMat:SetTexture("$basetexture", b)
	tintMat:SetVector("$color", TINT)

	render.PushRenderTarget(a)
	render.SetMaterial(srcMat)
	render.DrawScreenQuad()
	render.PopRenderTarget()

	render.PushRenderTarget(b)
	render.SetMaterial(greyMat)
	render.DrawScreenQuad()
	render.PopRenderTarget()

	render.PushRenderTarget(a)
	render.SetMaterial(tintMat)
	render.DrawScreenQuad()
	render.SetMaterial(keepMat)
	render.DrawScreenQuad()
	local data = render.Capture({ format = "jpeg", quality = 94, x = 0, y = 0, w = w, h = h })
	render.PopRenderTarget()

	file.Write(path, data)
end

local function isGrassLayer(mat, key, tex)
	local name = tex:GetName():lower()
	if name:find(DIR, 1, true) then return false end
	if name:find("grass", 1, true) then return true end

	local prop = mat:GetString(SURFACEPROPS[key])

	return prop ~= nil and prop:lower() == "grass"
end

local function grassJobs()
	local jobs, order = {}, {}
	for _, path in pairs(tod.GetMapTextures()) do
		path = path:lower()
		local mat = Material(path)
		if not mat:IsError() then
			for _, key in ipairs(LAYERS) do
				local saved = state.originals[path]
				local tex = saved and saved[key] or mat:GetTexture(key)
				if tex and not tex:IsError() and isGrassLayer(mat, key, tex) then
					state.originals[path] = saved or {}
					state.originals[path][key] = tex

					local name = tex:GetName():lower()
					if not jobs[name] then
						jobs[name] = { tex = tex, layers = {} }
						order[#order + 1] = jobs[name]
					end

					table.insert(jobs[name].layers, { mat = mat, key = key })
				end
			end
		end
	end

	return order
end

local function baked(name, ext, params, bake, arg)
	local path = DIR .. "/" .. name:gsub("[^%w_]", "_") .. "." .. ext
	local fresh = not file.Exists(path, "DATA")
	if fresh then
		file.CreateDir(DIR)
		bake(arg, path)
	end

	local tex = Material("../data/" .. path, params):GetTexture("$basetexture")
	if fresh then
		tex:Download()
	end

	return tex
end

local function start()
	if not tod or not tod.GetMapTextures then return end
	local jobs = grassJobs()
	local autumnTextures = {}

	hook.Add("PostRender", "tod_autumn", function()
		local job = table.remove(jobs, 1)
		if not job then
			hook.Remove("PostRender", "tod_autumn")
			hook.Run("TOD_Autumn", autumnTextures)

			return
		end

		local tex = baked(job.tex:GetName() .. "_" .. util.CRC(tostring(TINT) .. KEEP .. SCALE), "jpg", "mips smooth noclamp", bakeGrass, job.tex)
		autumnTextures[job.tex:GetName():lower()] = tex
		for _, layer in ipairs(job.layers) do
			layer.mat:SetTexture(layer.key, tex)
		end
	end)

	hook.Add("ShutDown", "tod_autumn", restoreGrass)
end

if IsValid(LocalPlayer()) then
	start()
else
	hook.Add("InitPostEntity", "tod_autumn", function()
		hook.Remove("InitPostEntity", "tod_autumn")
		start()
	end)
end
