local opacity = shaderpack.opacity or {}
shaderpack.opacity = opacity
local bspdata = shaderpack.bspdata

local WIREFRAME = 268435456
local ADDITIVE = 128
local TRANSLUCENT = 2097152
local ALPHATEST = 256
local NOCULL = 8192
local DECAL = 65536
local CUTOUT_MAX_BETWEEN = 0.25
local CUTOUT_MIN_HOLES = 0.05
local ALPHA_SAMPLES = 128
local SEE_THROUGH = WIREFRAME + ADDITIVE + TRANSLUCENT
local SEE = 1
local CYCLE = 4
local HIDDEN_MIN, HIDDEN_MAX = Vector(0, 0, -100001), Vector(0, 0, -100000)
local HOLDER_EXTENT = Vector(32768, 32768, 32768)

local STATE_RESET = CreateMaterial("ms_opacity_alphatestreset", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$alphatest"] = 1,
	["$alphatestreference"] = 0.001,
})

opacity.fixed = opacity.fixed or setmetatable({}, { __mode = "k" })
opacity.depth = opacity.depth or setmetatable({}, { __mode = "k" })
opacity.brushes = opacity.brushes or setmetatable({}, { __mode = "k" })
opacity.world = opacity.world or {}
opacity.cutouts = opacity.cutouts or {}
local fixed, depth, brushes = opacity.fixed, opacity.depth, opacity.brushes

local materialInfo = {}
local modelMaterials = {}
local queue, cursor = {}, 1

local function depthMaterial(name, mat, flags)
	local tex = mat:GetTexture("$basetexture")
	if not tex or tex:IsError() then return false end

	local params = {
		["$color_depth"] = 1,
		["$alphatest"] = 1,
		["$nocull"] = bit.band(flags, NOCULL) ~= 0 and 1 or 0,
	}
	local ref = mat:GetFloat("$alphatestreference")
	if ref and ref > 0 then
		params["$alphatestreference"] = ref
	end

	local dw = CreateMaterial("ms_opacity_depth/" .. name, "DepthWrite", params)
	dw:SetTexture("$basetexture", tex)

	return dw
end

local function classify(name)
	if name == nil or name == "" then return false end

	local known = materialInfo[name]
	if known ~= nil then return known end

	local mat = Material(name)
	local result = false
	if not mat:IsError() then
		local flags = mat:GetInt("$flags") or 0
		if bit.band(flags, SEE_THROUGH) ~= 0 or mat:GetShader():find("^Sprite") or (mat:GetFloat("$alpha") or 1) < 1 then
			result = SEE
		elseif bit.band(flags, ALPHATEST) ~= 0 then
			result = depthMaterial(name, mat, flags)
		end
	end

	materialInfo[name] = result

	return result
end

local function materialsOf(ent, model)
	local mats = modelMaterials[model]
	if not mats then
		mats = ent:GetMaterials()
		modelMaterials[model] = mats
	end

	return mats
end

local function inspect(ent)
	local overrideName = ent:GetMaterial()
	local override = classify(overrideName)
	if override == SEE then return true end

	local model = ent:GetModel()
	if not model then return false end

	local mats = materialsOf(ent, model)
	local plan
	for i = 1, #mats do
		local sub = ent:GetSubMaterial(i - 1)
		local info
		if sub ~= "" then
			info = classify(sub)
			if info == SEE then return true end
		elseif overrideName ~= "" then
			info = override
		else
			info = classify(mats[i])
			if info == SEE then
				info = false
			end
		end

		if info then
			plan = plan or {}
			plan[i - 1] = info
		end
	end

	return false, plan
end

opacity.wrappers = opacity.wrappers or setmetatable({}, { __mode = "k" })
local wrappers = opacity.wrappers

local function wrap(prev)
	local function draw(self, flags)
		local plan = depth[self]
		if plan and bit.band(flags, STUDIO_SSAODEPTHTEXTURE) ~= 0 then
			for i, dw in pairs(plan) do
				render.MaterialOverrideByIndex(i, dw)
			end

			if prev then prev(self, flags) else self:DrawModel(flags) end
			render.MaterialOverrideByIndex()

			return
		end

		if prev then prev(self, flags) else self:DrawModel(flags) end
	end

	wrappers[draw] = prev or false

	return draw
end

local function isWrapper(fn)
	return fn ~= nil and wrappers[fn] ~= nil
end

for ent in pairs(depth) do
	local current = IsValid(ent) and ent.RenderOverride
	if isWrapper(current) then
		ent.RenderOverride = wrap(wrappers[current] or nil)
	end
end

local function setDepthPlan(ent, plan)
	local current = ent.RenderOverride
	if not plan then
		if depth[ent] then
			depth[ent] = nil
			if isWrapper(current) then
				ent.RenderOverride = wrappers[current] or nil
			end
		end

		return
	end

	depth[ent] = plan
	if not isWrapper(current) then
		ent.RenderOverride = wrap(current)
	end
end

local function overridable(ent)
	return ent:EntIndex() > 0 and ent.Draw == nil and not ent:IsPlayer() and not ent:IsWeapon()
end

local function drawBrushes(_, flags)
	local drew = false
	for ent in pairs(brushes) do
		if IsValid(ent) and not ent:GetNoDraw() and not ent:IsDormant() then
			ent:DrawModel(flags)
			drew = true
		end
	end

	if drew then
		local p = EyePos()
		render.SetMaterial(STATE_RESET)
		render.DrawQuad(p, p, p, p)
	end
end

local function updateHolder()
	local holder = opacity.holder
	if not next(brushes) then
		if IsValid(holder) then
			holder:Remove()
		end

		opacity.holder = nil

		return
	end

	if not IsValid(holder) then
		holder = ClientsideModel("models/hunter/plates/plate.mdl", RENDERGROUP_OPAQUE)
		holder:SetRenderBounds(-HOLDER_EXTENT, HOLDER_EXTENT)
		opacity.holder = holder
	end

	holder.RenderOverride = drawBrushes
end

local function isBrush(ent)
	local model = ent:GetModel()

	return model ~= nil and model:sub(1, 1) == "*" and not ent:IsWorld()
end

local function setBrush(ent, alphaTested)
	local saved = brushes[ent]
	if alphaTested then
		if not saved then
			local mins, maxs = ent:GetRenderBounds()
			brushes[ent] = { mins, maxs }
		end

		ent:SetRenderBounds(HIDDEN_MIN, HIDDEN_MAX)
	elseif saved then
		ent:SetRenderBounds(saved[1], saved[2])
		brushes[ent] = nil
	else
		return
	end

	updateHolder()
end

local function update(ent)
	if not IsValid(ent) then return end

	if isBrush(ent) then
		local _, plan = inspect(ent)
		setBrush(ent, plan ~= nil)

		return
	end

	local see, plan = inspect(ent)
	local mode = ent:GetRenderMode()
	if fixed[ent] then
		if mode ~= RENDERMODE_TRANSALPHA then
			fixed[ent] = nil
		elseif not see then
			ent:SetRenderMode(RENDERMODE_NORMAL)
			fixed[ent] = nil
			mode = RENDERMODE_NORMAL
		end
	end

	if see and not fixed[ent] and mode == RENDERMODE_NORMAL and ent:GetRenderGroup() ~= RENDERGROUP_TRANSLUCENT then
		ent:SetRenderMode(RENDERMODE_TRANSALPHA)
		fixed[ent] = true
	end

	if see or not overridable(ent) then
		plan = nil
	end

	setDepthPlan(ent, plan)
end

local SKIP_PREFIXES = { "tools/", "decals/", "overlays/", "signs/" }
local CACHE_DIR = "shaderpack/opacity"
local alphaRT, alphaProbe
local worldQueue = {}
local verdictCache, cacheDirty = {}, false

local function cachePath()
	return CACHE_DIR .. "/" .. game.GetMap() .. ".json"
end

local function textureKey(tex)
	return tex:GetName() .. ":" .. tex:Width() .. "x" .. tex:Height()
end

local function loadCache()
	verdictCache = util.JSONToTable(file.Read(cachePath(), "DATA") or "") or {}
	cacheDirty = false
end

local function saveCache()
	if not cacheDirty then return end

	file.CreateDir(CACHE_DIR)
	file.Write(cachePath(), util.TableToJSON(verdictCache))
	cacheDirty = false
end

local function worldMaterialNames()
	local f, lump = bspdata.OpenLumps()
	if not f then return {} end

	local data = lump(43)
	local tbl, len = lump(44)
	f:Close()

	local names = {}
	for i = 0, len / 4 - 1 do
		names[#names + 1] = data:match("^[^%z]*", bspdata.I32(tbl, i * 4 + 1) + 1)
	end

	return names
end

local function cutoutTexture(name)
	local path = name:lower():gsub("^maps/[^/]+/", "")
	for _, prefix in ipairs(SKIP_PREFIXES) do
		if path:sub(1, #prefix) == prefix then return nil end
	end

	local mat = Material(name)
	if mat:IsError() then return nil end

	local flags = mat:GetInt("$flags") or 0
	if bit.band(flags, TRANSLUCENT) == 0 or bit.band(flags, ADDITIVE + DECAL + ALPHATEST) ~= 0 then return nil end

	local shader = mat:GetShader()
	if shader:find("^Water") or shader:find("^Refract") then return nil end

	local tex = mat:GetTexture("$basetexture")
	if not tex or tex:IsError() then return nil end

	return tex
end

local function measureAlpha(tex)
	local tw, th = math.min(tex:Width(), 1024), math.min(tex:Height(), 1024)
	alphaProbe:SetTexture("$basetexture", tex)

	render.PushRenderTarget(alphaRT)
	render.Clear(0, 0, 0, 0)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	render.PushFilterMag(TEXFILTER.POINT)
	render.PushFilterMin(TEXFILTER.POINT)
	cam.Start2D()
	surface.SetMaterial(alphaProbe)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawTexturedRect(0, 0, tw, th)
	cam.End2D()
	render.PopFilterMin()
	render.PopFilterMag()
	render.OverrideBlend(false)
	render.CapturePixels()

	local stride = math.max(1, math.floor(math.max(tw, th) / ALPHA_SAMPLES))
	if stride % 2 == 0 then
		stride = stride - 1
	end

	local holes, between, n = 0, 0, 0
	for y = 0, th - 1, stride do
		for x = 0, tw - 1, stride do
			local _, _, _, a = render.ReadPixel(x, y)
			n = n + 1
			if a <= 25 then
				holes = holes + 1
			elseif a < 230 then
				between = between + 1
			end
		end
	end
	render.PopRenderTarget()

	return holes / n, between / n
end

local function convertWorld(name)
	if opacity.world[name] then return end

	local mat = Material(name)
	local flags = mat:GetInt("$flags")
	opacity.world[name] = { flags = flags, ref = mat:GetFloat("$alphatestreference") or 0 }
	mat:SetInt("$flags", bit.bor(bit.band(flags, bit.bnot(TRANSLUCENT)), ALPHATEST))
	mat:SetFloat("$alphatestreference", 0.5)
end

local function restoreWorld()
	for name, saved in pairs(opacity.world) do
		local mat = Material(name)
		mat:SetInt("$flags", saved.flags)
		mat:SetFloat("$alphatestreference", saved.ref)
		opacity.world[name] = nil
	end
end

local function scanStep()
	local name = worldQueue[#worldQueue]
	if not name then
		hook.Remove("PostRender", "ms_opacity_world")
		saveCache()
		return
	end

	if not shaderpack.UsableRT(alphaRT, 1024, 1024) then
		alphaRT = GetRenderTargetEx("ms_opacity_alpha", 1024, 1024, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
		return
	end

	alphaProbe = alphaProbe or CreateMaterial("ms_opacity_alphaprobe", "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$vertexalpha"] = 1,
		["$translucent"] = 1,
	})

	worldQueue[#worldQueue] = nil
	local tex = cutoutTexture(name)
	local verdict = false
	if tex then
		local holes, between = measureAlpha(tex)
		verdict = between <= CUTOUT_MAX_BETWEEN and holes >= CUTOUT_MIN_HOLES
		verdictCache[name] = { key = textureKey(tex), cutout = verdict }
		cacheDirty = true
	end

	opacity.cutouts[name] = verdict
	if verdict then
		convertWorld(name)
	end
end

local function scanWorld()
	loadCache()
	worldQueue = {}
	for _, name in ipairs(worldMaterialNames()) do
		local verdict = opacity.cutouts[name]
		if verdict then
			convertWorld(name)
		elseif verdict == nil then
			local tex = cutoutTexture(name)
			local cached = tex and verdictCache[name]
			if not tex then
				opacity.cutouts[name] = false
			elseif cached and cached.key == textureKey(tex) then
				opacity.cutouts[name] = cached.cutout
				if cached.cutout then
					convertWorld(name)
				end
			else
				worldQueue[#worldQueue + 1] = name
			end
		end
	end

	if worldQueue[1] then
		hook.Add("PostRender", "ms_opacity_world", scanStep)
	end
end

local function step()
	if cursor > #queue then
		local _, list = ents.Iterator()
		queue, cursor = list, 1
	end

	local batch = math.ceil(#queue * math.min(RealFrameTime(), 0.1) / CYCLE)
	local last = math.min(cursor + batch - 1, #queue)
	for i = cursor, last do
		local ent = queue[i]
		if IsValid(ent) and not ent:IsDormant() then
			update(ent)
		end
	end

	cursor = last + 1
end

local function entered(ent, transmit)
	if transmit then
		update(ent)
	end
end

local function stop()
	hook.Remove("Think", "ms_opacity")
	hook.Remove("NotifyShouldTransmit", "ms_opacity")
	hook.Remove("NetworkEntityCreated", "ms_opacity")
	hook.Remove("PostRender", "ms_opacity_world")
	hook.Remove("InitPostEntity", "ms_opacity_world")
	worldQueue = {}
	restoreWorld()

	for ent in pairs(fixed) do
		if IsValid(ent) and ent:GetRenderMode() == RENDERMODE_TRANSALPHA then
			ent:SetRenderMode(RENDERMODE_NORMAL)
		end

		fixed[ent] = nil
	end

	for ent in pairs(depth) do
		if IsValid(ent) then
			setDepthPlan(ent, nil)
		end

		depth[ent] = nil
	end

	for ent in pairs(brushes) do
		if IsValid(ent) then
			setBrush(ent, false)
		end

		brushes[ent] = nil
	end

	updateHolder()
	queue, cursor = {}, 1
end

local function start()
	updateHolder()
	queue, cursor = {}, 1
	hook.Add("Think", "ms_opacity", step)
	hook.Add("NotifyShouldTransmit", "ms_opacity", entered)
	hook.Add("NetworkEntityCreated", "ms_opacity", update)
	shaderpack.AfterWorld("ms_opacity_world", scanWorld)
end

shaderpack.Toggle("ms_opacity", nil, {}, start, stop)()
