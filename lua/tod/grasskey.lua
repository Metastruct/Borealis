require("bspdata")

local DIR = "tod_grasskey"
local MIN_NZ = 0.5
local MIN_UP_AREA = 128 * 128
local MIN_UP_SHARE = 0.25
local PROBE = 64
local HUE_IN0, HUE_IN1 = 42, 52
local HUE_OUT0, HUE_OUT1 = 110, 140
local SAT0, SAT1 = 0.18, 0.28
local DARK0, DARK1 = 10, 30
local GRASS_SHARE = 0.12
local FULL_SHARE = 0.6
local MASK_RADIUS = 2
local MASK_GAIN = 1.6
local SCALE = 0.5
local MAX_SIZE = 1024
local FORMAT_RGBA8888, FORMAT_RGB888 = 0, 2
local VTF_EIGHTBITALPHA = 0x2000
local SELFILLUM, ALPHATEST, BASEALPHAENVMAPMASK, TRANSLUCENT = 0x40, 0x100, 0x100000, 0x200000
local ALPHA_FLAGS = bit.bor(SELFILLUM, ALPHATEST, BASEALPHAENVMAPMASK, TRANSLUCENT)
local CUTOUT_FLAGS = bit.bor(ALPHATEST, TRANSLUCENT)
local GROUND_PROPS = { "default", "dirt", "grass", "gravel", "mud", "sand", "rock", "boulder", "concrete", "snow", "foliage" }
local SKY_TRACE = 65536
local GAMMA_INV = 1 / 2.2
local LAYERS = { "$basetexture", "$basetexture2" }
local KEY_VERSION = util.CRC(table.concat({ HUE_IN0, HUE_IN1, HUE_OUT0, HUE_OUT1, SAT0, SAT1, DARK0, DARK1, FULL_SHARE, SCALE, MASK_RADIUS, MASK_GAIN }, ","))

tod.grasskey = tod.grasskey or {}
local grasskey = tod.grasskey

local drawMat = CreateMaterial("tod_grasskey_draw", "UnlitGeneric", {
	["$basetexture"] = "",
	["$ignorez"] = 1,
})

local drawAlphaMat = CreateMaterial("tod_grasskey_draw_alpha", "UnlitGeneric", {
	["$basetexture"] = "",
	["$ignorez"] = 1,
	["$translucent"] = 1,
})

local function capture(tex, w, h, alpha)
	local rt = GetRenderTargetEx("tod_grasskey_" .. w .. "x" .. h, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
	local mat = alpha and drawAlphaMat or drawMat
	mat:SetTexture("$basetexture", tex)

	render.PushRenderTarget(rt)
	if alpha then
		render.OverrideAlphaWriteEnable(true, true)
		render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	end
	render.SetMaterial(mat)
	render.DrawScreenQuad()
	if alpha then
		render.OverrideBlend(false)
		render.OverrideAlphaWriteEnable(false)
	end
	render.CapturePixels()

	local out, read, i = {}, render.ReadPixel, 1
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			if alpha then
				out[i], out[i + 1], out[i + 2], out[i + 3] = read(x, y)
				i = i + 4
			else
				out[i], out[i + 1], out[i + 2] = read(x, y)
				i = i + 3
			end
		end
	end
	render.PopRenderTarget()

	return out
end

local function smooth(a, b, x)
	local t = math.Clamp((x - a) / (b - a), 0, 1)

	return t * t * (3 - 2 * t)
end

local function grassWeight(r, g, b)
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	if mx == mn then return 0 end

	local d = mx - mn
	local h
	if mx == r then
		h = ((g - b) / d) % 6
	elseif mx == g then
		h = (b - r) / d + 2
	else
		h = (r - g) / d + 4
	end
	h = h * 60

	return smooth(HUE_IN0, HUE_IN1, h) * (1 - smooth(HUE_OUT0, HUE_OUT1, h)) * smooth(SAT0, SAT1, d / mx) * smooth(DARK0, DARK1, mx)
end

local function grassShare(tex, alpha)
	local px = capture(tex, PROBE, PROBE, alpha)
	local stride = alpha and 4 or 3
	local sum, total = 0, 0
	for i = 1, #px, stride do
		local cover = alpha and px[i + 3] / 255 or 1
		sum = sum + grassWeight(px[i], px[i + 1], px[i + 2]) * cover
		total = total + cover
	end

	return total > 0 and sum / total or 0
end

local function isGroundProp(prop)
	prop = (prop or "default"):lower()
	for _, word in ipairs(GROUND_PROPS) do
		if prop:find(word, 1, true) then return true end
	end

	return false
end

local function layerProp(mat, layer)
	return layer == 2 and mat:GetString("$surfaceprop2") or mat:GetString("$surfaceprop")
end

local function isWorldMaterial(mat)
	local shader = mat:GetShader():lower()

	return (shader:find("lightmappedgeneric", 1, true) or shader:find("worldvertextransition", 1, true))
		and bit.band(mat:GetInt("$flags") or 0, ALPHA_FLAGS) == 0
end

local function isFoliageMaterial(mat)
	return mat:GetShader():lower():find("vertexlitgeneric", 1, true)
		and bit.band(mat:GetInt("$flags") or 0, CUTOUT_FLAGS) ~= 0
end

local skyTrace = { mask = MASK_SOLID_BRUSHONLY }

local function seesSky(x, y, z)
	skyTrace.start = Vector(x, y, z + 8)
	skyTrace.endpos = Vector(x, y, z + SKY_TRACE)

	return util.TraceLine(skyTrace).HitSky
end

local function le16(v)
	return string.char(v % 256, math.floor(v / 256) % 256)
end

local function le32(v)
	return le16(v % 65536) .. le16(math.floor(v / 65536))
end

local function vtfHeader(w, h, mips, alpha)
	local format, flags = alpha and FORMAT_RGBA8888 or FORMAT_RGB888, alpha and VTF_EIGHTBITALPHA or 0
	local header = "VTF\0" .. le32(7) .. le32(2) .. le32(80) .. le16(w) .. le16(h) .. le32(flags) .. le16(1) .. le16(0) .. le32(0)
		.. "\0\0\0\63\0\0\0\63\0\0\0\63" .. le32(0) .. "\0\0\128\63" .. le32(format) .. string.char(mips) .. "\255\255\255\255" .. string.char(0, 0) .. le16(1)

	return header .. string.rep("\0", 80 - #header)
end

local function levelBytes(px, w, h, stride, budget)
	local rows, row = {}, {}
	local rowSize = w * stride
	for y = 0, h - 1 do
		local base = y * rowSize
		for i = 1, rowSize do
			row[i] = px[base + i]
		end
		rows[y + 1] = string.char(unpack(row, 1, rowSize))
		budget()
	end

	return table.concat(rows)
end

local function halve(px, w, h, stride, budget)
	local nw, nh = math.max(1, math.floor(w / 2)), math.max(1, math.floor(h / 2))
	local out = {}
	for y = 0, nh - 1 do
		budget()
		local y0, y1 = math.min(y * 2, h - 1), math.min(y * 2 + 1, h - 1)
		for x = 0, nw - 1 do
			local x0, x1 = math.min(x * 2, w - 1), math.min(x * 2 + 1, w - 1)
			local a, b, c, d = (y0 * w + x0) * stride, (y0 * w + x1) * stride, (y1 * w + x0) * stride, (y1 * w + x1) * stride
			local o = (y * nw + x) * stride
			for k = 1, stride do
				out[o + k] = math.floor((px[a + k] + px[b + k] + px[c + k] + px[d + k]) * 0.25 + 0.5)
			end
		end
	end

	return out, nw, nh
end

local function boxBlur(src, w, h, dx, dy, budget)
	local out = {}
	local scale = 1 / (MASK_RADIUS * 2 + 1)
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local sum = 0
			for k = -MASK_RADIUS, MASK_RADIUS do
				sum = sum + src[((y + k * dy) % h) * w + (x + k * dx) % w + 1]
			end
			out[y * w + x + 1] = sum * scale
		end
		budget()
	end

	return out
end

local function grassMask(px, w, h, stride, budget)
	local weights = {}
	for i = 1, w * h do
		local p = (i - 1) * stride + 1
		weights[i] = grassWeight(px[p], px[p + 1], px[p + 2])
	end

	local mask = boxBlur(boxBlur(weights, w, h, 1, 0, budget), w, h, 0, 1, budget)
	for i = 1, w * h do
		mask[i] = math.min(mask[i] * MASK_GAIN, 1)
	end

	return mask
end

local function bake(job, path, opts)
	local tex, alpha = job.tex, job.alpha
	local stride = alpha and 4 or 3
	local w = math.Clamp(math.floor(tex:Width() * SCALE), 1, MAX_SIZE)
	local h = math.Clamp(math.floor(tex:Height() * SCALE), 1, MAX_SIZE)
	local budget = bspdata.FrameBudget()
	local px = capture(tex, w, h, alpha)
	coroutine.yield()
	local over = opts.overlay and capture(opts.overlay, w, h, alpha)
	coroutine.yield()

	local mask = not job.full and grassMask(px, w, h, stride, budget)
	local compose = opts.compose
	for p = 1, w * h do
		local i = (p - 1) * stride + 1
		local r, g, b = px[i], px[i + 1], px[i + 2]
		local m = job.full and 1 or mask[p]
		if m > 0 then
			local nr, ng, nb = compose(r, g, b, over and over[i], over and over[i + 1], over and over[i + 2])
			px[i] = math.Clamp(math.floor(r + (nr - r) * m + 0.5), 0, 255)
			px[i + 1] = math.Clamp(math.floor(g + (ng - g) * m + 0.5), 0, 255)
			px[i + 2] = math.Clamp(math.floor(b + (nb - b) * m + 0.5), 0, 255)
		end
		if p % w == 0 then budget() end
	end

	local levels = { levelBytes(px, w, h, stride, budget) }
	local lw, lh = w, h
	while lw > 1 or lh > 1 do
		px, lw, lh = halve(px, lw, lh, stride, budget)
		table.insert(levels, 1, levelBytes(px, lw, lh, stride, budget))
	end

	file.Write(path, vtfHeader(w, h, #levels, alpha) .. table.concat(levels))
end

local function jobFor(state, tex, alpha)
	local texName = tex:GetName():lower()
	local job = state.byTexture[texName]
	if job ~= nil then return job end

	local share = grassShare(tex, alpha)
	job = share >= GRASS_SHARE and {
		tex = tex,
		name = texName,
		share = share,
		alpha = alpha,
		full = state.allowFull and share >= FULL_SHARE,
		layers = {},
	} or false
	state.byTexture[texName] = job
	if job then state.found[#state.found + 1] = job end
	coroutine.yield()

	return job
end

local function addLayer(state, path, mat, key, alpha, color)
	local tex = mat:GetTexture(key)
	if not tex or tex:IsError() or state.skip(path, key) then return end

	local job = jobFor(state, tex, alpha)
	if job then
		table.insert(job.layers, { path = path, mat = mat, key = key, color = color })
	end
end

local function worldCandidates(state)
	local upArea, totalArea = bspdata.UpFacingArea(MIN_NZ, seesSky)
	for name, area in pairs(upArea) do
		local path = name:lower()
		local mat = area >= MIN_UP_AREA and area >= totalArea[name] * MIN_UP_SHARE and not path:find("^tools/") and Material(path)
		if mat and not mat:IsError() and isWorldMaterial(mat) then
			for i, key in ipairs(LAYERS) do
				if isGroundProp(layerProp(mat, i)) then
					addLayer(state, path, mat, key, false)
				end
			end
		end
	end
end

local function propMaterials()
	local seen, materials = {}, {}
	for _, model in ipairs(bspdata.StaticPropModels()) do
		if not seen[model] then
			seen[model] = true
			local ent = ClientsideModel(model)
			if IsValid(ent) then
				for _, name in ipairs(ent:GetMaterials()) do
					materials[name:lower()] = true
				end
				ent:Remove()
			end
			coroutine.yield()
		end
	end

	return materials
end

local function neutralColor(mat, light)
	local c = mat:GetVector("$color") or Vector(1, 1, 1)
	local peak = math.max(light.x, light.y, light.z, 1e-3)
	local lr, lg, lb = math.max(light.x / peak, 1e-2), math.max(light.y / peak, 1e-2), math.max(light.z / peak, 1e-2)
	local lum = c.x ^ 2.2 * lr * 0.2126 + c.y ^ 2.2 * lg * 0.7152 + c.z ^ 2.2 * lb * 0.0722

	return Vector((lum / lr) ^ GAMMA_INV, (lum / lg) ^ GAMMA_INV, (lum / lb) ^ GAMMA_INV)
end

local function detailCandidate(state)
	local detail = bspdata.DetailSprites()
	if not detail then return end

	local mat = Material(detail.material)
	if not mat:IsError() and bit.band(mat:GetInt("$flags") or 0, CUTOUT_FLAGS) ~= 0 then
		addLayer(state, detail.material, mat, "$basetexture", true, neutralColor(mat, detail.light))
	end
end

local function propCandidates(state)
	for path in pairs(propMaterials()) do
		local mat = Material(path)
		if not mat:IsError() and isFoliageMaterial(mat) then
			addLayer(state, path, mat, "$basetexture", true)
		end
	end

	detailCandidate(state)
end

function grasskey.Run(id, opts)
	local hookName = "tod_grasskey_" .. id
	local co = coroutine.create(function()
		local state = { found = {}, byTexture = {}, skip = opts.skip, allowFull = opts.source ~= "props" }
		if opts.source == "props" then
			propCandidates(state)
		else
			worldCandidates(state)
		end

		file.CreateDir(DIR)
		for _, job in ipairs(state.found) do
			local fileName = job.name:gsub("[^%w_]", "_") .. "_" .. id .. "_" .. util.CRC(opts.version .. KEY_VERSION)
			local path = DIR .. "/" .. fileName .. ".vtf"
			local fresh = not file.Exists(path, "DATA")
			if fresh then
				bake(job, path, opts)
				coroutine.yield()
			end

			local tex = CreateMaterial("tod_grasskey_" .. fileName, "UnlitGeneric", { ["$basetexture"] = "../data/" .. DIR .. "/" .. fileName }):GetTexture("$basetexture")
			if fresh then tex:Download() end

			for _, layer in ipairs(job.layers) do
				opts.apply(layer, tex)
			end
		end

		if opts.done then opts.done(state.found) end
	end)

	hook.Add("PostRender", hookName, function()
		local ok, why = coroutine.resume(co)
		if not ok then
			hook.Remove("PostRender", hookName)
			ErrorNoHalt("[tod grasskey] " .. tostring(why) .. "\n")
		elseif coroutine.status(co) == "dead" then
			hook.Remove("PostRender", hookName)
		end
	end)
end

function grasskey.Stop(id)
	hook.Remove("PostRender", "tod_grasskey_" .. id)
end
