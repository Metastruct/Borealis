local opacity = shaderpack.opacity or {}
shaderpack.opacity = opacity
local bspdata = shaderpack.bspdata

local WIREFRAME = 268435456
local ADDITIVE = 128
local TRANSLUCENT = 2097152
local ALPHATEST = 256
local NOCULL = 8192
local DECAL = 65536
local VERTEXALPHA = 32
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
opacity.sents = opacity.sents or setmetatable({}, { __mode = "k" })
opacity.screens = opacity.screens or setmetatable({}, { __mode = "k" })
opacity.regrouped = opacity.regrouped or setmetatable({}, { __mode = "k" })
opacity.world = opacity.world or {}
opacity.cutouts = opacity.cutouts or {}
opacity.models = opacity.models or {}
local fixed, depth, brushes, screens = opacity.fixed, opacity.depth, opacity.brushes, opacity.screens

local materialInfo = {}
local modelMaterials = {}
local queue, cursor = {}, 1
local queueModel

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
		local sprite = mat:GetShader():find("^Sprite") ~= nil
		local alpha = mat:GetFloat("$alpha") or 1
		if bit.band(flags, SEE_THROUGH) ~= 0 or sprite or alpha < 1 then
			result = SEE
			if bit.band(flags, SEE_THROUGH + VERTEXALPHA) == TRANSLUCENT and not sprite and alpha >= 1 and queueModel(name, mat) then
				return classify(name)
			end
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

local DEPTH_QUAD = CreateMaterial("ms_opacity_depth_quad", "DepthWrite", {
	["$color_depth"] = 1,
	["$nocull"] = 1,
})

local function drawBrush(proxy, flags)
	local ent = proxy.brush
	if not IsValid(ent) or ent:GetNoDraw() or ent:IsDormant() then return end

	ent:DrawModel(flags)
	local p = EyePos()
	render.SetMaterial(STATE_RESET)
	render.DrawQuad(p, p, p, p)
end

opacity.screenArgs = opacity.screenArgs or setmetatable({}, { __mode = "k" })
local screenArgs = opacity.screenArgs

local function screenRender(gpu, ...)
	local args = screenArgs[gpu]
	if not args then return end

	local n = select("#", ...)
	args.n = n
	for i = 1, n do
		args[i] = (select(i, ...))
	end
end

for ent in pairs(screens) do
	local gpu = IsValid(ent) and ent.GPU
	if istable(gpu) and screenArgs[gpu] then
		rawset(gpu, "Render", screenRender)
	end
end

local function drawScreenDepth(ent, gpu)
	local monitor = gpu.RT and gpu.translucent ~= true and gpu.Entity == ent and WireGPU_Monitors[ent:GetModel()]
	if not monitor then return end

	local pos = ent:LocalToWorld(monitor.offset)
	local ang = ent:LocalToWorldAngles(monitor.rot)
	local f = ang:Forward() * (512 * monitor.RS / monitor.RatioX)
	local r = ang:Right() * (512 * monitor.RS)
	render.SetMaterial(DEPTH_QUAD)
	render.DrawQuad(pos - f - r, pos + f - r, pos + f + r, pos - f + r)
end

local function drawScreens(depthPass)
	for ent in pairs(screens) do
		local gpu = IsValid(ent) and not ent:GetNoDraw() and not ent:IsDormant() and ent.GPU
		local args = gpu and screenArgs[gpu]
		if args then
			if depthPass then
				drawScreenDepth(ent, gpu)
			else
				GPULib.GPU.Render(gpu, unpack(args, 1, args.n))
			end
		end
	end
end

local function drawHolder(_, flags)
	drawScreens(bit.band(flags, STUDIO_SSAODEPTHTEXTURE) ~= 0)
end

local function updateHolder()
	local holder = opacity.holder
	if not next(screens) then
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

	holder.RenderOverride = drawHolder
end

local function setScreen(ent, wanted)
	if wanted == (screens[ent] ~= nil) then return end

	local gpu = ent.GPU
	if wanted then
		screenArgs[gpu] = { n = 0 }
		rawset(gpu, "Render", screenRender)
		screens[ent] = true
	else
		if istable(gpu) and rawget(gpu, "Render") == screenRender then
			rawset(gpu, "Render", nil)
		end

		screens[ent] = nil
	end

	updateHolder()
end

local function opaqueScreen(ent)
	local gpu = ent.GPU
	if not GPULib or not istable(gpu) or getmetatable(gpu) ~= GPULib.GPU then return false end
	if gpu.Entity ~= ent or gpu.translucent == true or ent:GetRenderGroup() ~= RENDERGROUP_TRANSLUCENT then return false end

	local monitor = WireGPU_Monitors and WireGPU_Monitors[ent:GetModel()]

	return monitor ~= nil and not monitor.translucent
end

local NO_DRAW = CreateMaterial("ms_opacity_nodraw", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$no_draw"] = 1,
})

local function baseTranslucent()
	local base = scripted_ents.GetStored("base_anim")

	return base and base.t.DrawTranslucent
end

local function opaqueIndices(ent, model)
	local list = {}
	local mats = materialsOf(ent, model)
	for i = 1, #mats do
		local sub = ent:GetSubMaterial(i - 1)
		local name = sub ~= "" and sub or ent:GetMaterial() ~= "" and ent:GetMaterial() or mats[i]
		if classify(name) ~= SEE then
			list[#list + 1] = i - 1
		end
	end

	return list
end

local function translucentRedraw(self, flags)
	local state = opacity.sents[self]
	if not state then return end

	for _, i in ipairs(state.opaque) do
		render.MaterialOverrideByIndex(i, NO_DRAW)
	end

	local ok, err = pcall(state.orig, self, flags)
	render.MaterialOverrideByIndex()
	if not ok then
		ErrorNoHalt(err, "\n")
	end
end

for ent, state in pairs(opacity.sents) do
	if IsValid(ent) and ent.DrawTranslucent ~= state.orig then
		ent.DrawTranslucent = translucentRedraw
	end
end

local function setSent(ent, wanted)
	local state = opacity.sents[ent]
	if not wanted then
		if state then
			if ent.DrawTranslucent == translucentRedraw then
				ent.DrawTranslucent = state.orig
			end

			opacity.sents[ent] = nil
		end

		return
	end

	local model = ent:GetModel()
	if not state then
		state = { orig = ent.DrawTranslucent }
		opacity.sents[ent] = state
	end

	state.opaque = opaqueIndices(ent, model)
	ent.DrawTranslucent = translucentRedraw
end

local function updateSent(ent)
	local model = ent:GetModel()
	local state = opacity.sents[ent]
	local current = state and state.orig or ent.DrawTranslucent
	local base = baseTranslucent()
	local wanted = model ~= nil and model:find("%.mdl$") ~= nil and base ~= nil and current == base
		and ent:GetRenderGroup() == RENDERGROUP_BOTH and (ent.DrawTranslucent == base or ent.DrawTranslucent == translucentRedraw)
		and ent:GetRenderMode() == RENDERMODE_NORMAL and ent:GetColor().a == 255

	setSent(ent, wanted)
end

opacity.drawn = opacity.drawn or setmetatable({}, { __mode = "k" })
opacity.drawWrappers = opacity.drawWrappers or setmetatable({}, { __mode = "k" })
local drawn, drawWrappers = opacity.drawn, opacity.drawWrappers

local DEPTH_SOLID = CreateMaterial("ms_opacity_depth_solid", "DepthWrite", { ["$color_depth"] = 1 })
local entityMeta = FindMetaTable("Entity")
local innerDrawModel = entityMeta.DrawModel
local modelPlans = {}

local function depthPlan(ent, model, override)
	local mats = materialsOf(ent, model)
	local plan = {}
	for i = 1, #mats do
		local sub = ent:GetSubMaterial(i - 1)
		local info = classify(sub ~= "" and sub or override ~= "" and override or mats[i])
		plan[i] = info == SEE and NO_DRAW or info or DEPTH_SOLID
	end

	return plan
end

local function fullPlan(ent)
	local model = ent:GetModel()
	if not model then return nil end

	local plan
	for i, mat in ipairs(depthPlan(ent, model, ent:GetMaterial())) do
		plan = plan or {}
		plan[i - 1] = mat
	end

	return plan
end

local function planOf(ent)
	local state = drawn[ent]
	if state and state.plan then return state.plan end

	local model = ent:GetModel()
	if not model then return nil end

	local plan = modelPlans[model]
	if not plan then
		plan = depthPlan(ent, model, "")
		modelPlans[model] = plan
	end

	return plan
end

local innerSetMaterial = render.SetMaterial
local innerSetRenderTarget = render.SetRenderTarget
local innerPushRenderTarget = render.PushRenderTarget
local innerPopRenderTarget = render.PopRenderTarget
local depthShaders = setmetatable({}, { __mode = "k" })
local depthTarget
local onDepth, materialWrites = false, false

local function setWrites(on)
	if on then
		render.OverrideColorWriteEnable(false)
		render.OverrideDepthEnable(false)
	else
		render.OverrideColorWriteEnable(true, false)
		render.OverrideDepthEnable(true, false)
	end
end

local function applyWrites()
	setWrites(materialWrites or not onDepth)
end

local function syncTarget()
	local target = render.GetRenderTarget()
	onDepth = target ~= nil and target:GetName() == depthTarget
	applyWrites()
end

local function isDepthWrite(mat)
	local known = depthShaders[mat]
	if known == nil then
		known = mat:GetShader() == "DepthWrite"
		depthShaders[mat] = known
	end

	return known
end

local function depthSetMaterial(mat)
	innerSetMaterial(mat)
	materialWrites = mat ~= nil and isDepthWrite(mat)
	applyWrites()
end

local function depthSetRenderTarget(...)
	innerSetRenderTarget(...)
	syncTarget()
end

local function depthPushRenderTarget(...)
	innerPushRenderTarget(...)
	syncTarget()
end

local function depthPopRenderTarget(...)
	innerPopRenderTarget(...)
	syncTarget()
end

local function depthDrawModel(ent, flags)
	if not onDepth then
		return innerDrawModel(ent, flags)
	end

	setWrites(true)

	local plan = not ent.GetRenderMesh and planOf(ent)
	if not plan or #plan == 0 then
		local r = innerDrawModel(ent, flags)
		applyWrites()

		return r
	end

	for i = 1, #plan do
		render.MaterialOverrideByIndex(i - 1, plan[i])
	end

	local r = innerDrawModel(ent, flags)
	render.MaterialOverrideByIndex()
	applyWrites()

	return r
end

local function depthDraw(self, flags)
	local state = drawn[self]
	local orig = state and state.orig
	if not orig then return end

	if not flags or bit.band(flags, STUDIO_SSAODEPTHTEXTURE) == 0 then
		return orig(self, flags)
	end

	local prevDrawModel, prevSetMaterial = entityMeta.DrawModel, render.SetMaterial
	local prevSetTarget, prevPushTarget, prevPopTarget = render.SetRenderTarget, render.PushRenderTarget, render.PopRenderTarget
	local prevTarget, prevOnDepth, prevMaterialWrites = depthTarget, onDepth, materialWrites
	if prevDrawModel ~= depthDrawModel then
		innerDrawModel = prevDrawModel
		innerSetMaterial = prevSetMaterial
		innerSetRenderTarget = prevSetTarget
		innerPushRenderTarget = prevPushTarget
		innerPopRenderTarget = prevPopTarget
	end

	entityMeta.DrawModel = depthDrawModel
	render.SetMaterial = depthSetMaterial
	render.SetRenderTarget = depthSetRenderTarget
	render.PushRenderTarget = depthPushRenderTarget
	render.PopRenderTarget = depthPopRenderTarget

	local target = render.GetRenderTarget()
	depthTarget = target and target:GetName()
	onDepth, materialWrites = depthTarget ~= nil, false
	applyWrites()

	local ok, err = pcall(orig, self, flags)

	entityMeta.DrawModel = prevDrawModel
	render.SetMaterial = prevSetMaterial
	render.SetRenderTarget = prevSetTarget
	render.PushRenderTarget = prevPushTarget
	render.PopRenderTarget = prevPopTarget
	depthTarget, onDepth, materialWrites = prevTarget, prevOnDepth, prevMaterialWrites
	applyWrites()
	render.MaterialOverrideByIndex()
	if not ok then
		ErrorNoHalt(err, "\n")
	end
end

drawWrappers[depthDraw] = true

for ent, state in pairs(drawn) do
	if IsValid(ent) and ent.Draw ~= depthDraw and drawWrappers[ent.Draw] then
		ent.Draw = depthDraw
	end
end

local function setDrawn(ent, wanted)
	local state = drawn[ent]
	local current = ent.Draw
	if not wanted then
		if state then
			if drawWrappers[current] then
				ent.Draw = state.orig
			end

			drawn[ent] = nil
		end

		return
	end

	if current ~= depthDraw then
		if not (state and drawWrappers[current]) then
			state = { orig = current }
			drawn[ent] = state
		end

		ent.Draw = depthDraw
	end

	local model = ent:GetModel()
	state.plan = model and depthPlan(ent, model, ent:GetMaterial()) or nil
end

local function isBrush(ent)
	local model = ent:GetModel()

	return model ~= nil and model:sub(1, 1) == "*" and not ent:IsWorld()
end

opacity.proxies = opacity.proxies or {}
local proxies = opacity.proxies

local function removeProxy(proxy)
	if IsValid(proxy) then
		proxy:Remove()
	end

	proxies[proxy] = nil
end

local function sweepProxies()
	for proxy in pairs(proxies) do
		if not IsValid(proxy) or not IsValid(proxy.brush) or brushes[proxy.brush] == nil then
			removeProxy(proxy)
		end
	end
end

local function setBrush(ent, alphaTested)
	local saved = brushes[ent]
	if alphaTested then
		if not saved then
			local mins, maxs = ent:GetRenderBounds()
			saved = { mins, maxs }
			brushes[ent] = saved
		end

		local proxy = saved[3]
		if not IsValid(proxy) then
			proxy = ClientsideModel("models/hunter/plates/plate.mdl", RENDERGROUP_OPAQUE)
			proxy:SetRenderBounds(saved[1], saved[2])
			proxy.brush = ent
			proxies[proxy] = true
			saved[3] = proxy
		end

		proxy:SetPos(ent:GetPos())
		proxy:SetAngles(ent:GetAngles())
		proxy.RenderOverride = drawBrush
		ent:SetRenderBounds(HIDDEN_MIN, HIDDEN_MAX)
	elseif saved then
		removeProxy(saved[3])
		ent:SetRenderBounds(saved[1], saved[2])
		brushes[ent] = nil
	end
end

opacity.pac = opacity.pac or setmetatable({}, { __mode = "k" })
opacity.pacWrappers = opacity.pacWrappers or setmetatable({}, { __mode = "k" })
local pacOverrides = opacity.pac
local pacSources = setmetatable({}, { __mode = "k" })

local function pacDraw(self, flags)
	local prev = pacOverrides[self]
	if not prev then return end

	if not flags or bit.band(flags, STUDIO_SSAODEPTHTEXTURE) == 0 then
		return prev(self, flags)
	end

	if self.pac_hide_entity then return end

	local model = self:GetModel()
	local plan = model and depthPlan(self, model, self:GetMaterial())
	if plan then
		for i = 1, #plan do
			render.MaterialOverrideByIndex(i - 1, plan[i])
		end
	end

	self:DrawModel(flags)
	render.MaterialOverrideByIndex()
end

opacity.pacWrappers[pacDraw] = true

for ent in pairs(pacOverrides) do
	if IsValid(ent) and ent.RenderOverride ~= pacDraw and opacity.pacWrappers[ent.RenderOverride] then
		ent.RenderOverride = pacDraw
	end
end

local function isPac(fn)
	local known = pacSources[fn]
	if known == nil then
		known = debug.getinfo(fn, "S").short_src:find("pac3/", 1, true) ~= nil
		pacSources[fn] = known
	end

	return known
end

local function updatePac(ent)
	local current = ent.RenderOverride
	if current == pacDraw then
		if ent.pac_hide_entity then
			ent.RenderOverride = pacOverrides[ent]
			pacOverrides[ent] = nil
		end

		return
	end

	if pacOverrides[ent] then
		pacOverrides[ent] = nil
	end

	if isfunction(current) and not ent.pac_hide_entity and not ent:IsWeapon() and isPac(current) then
		pacOverrides[ent] = current
		ent.RenderOverride = pacDraw
	end
end

local function convertedOpaque(ent)
	local stored = scripted_ents.GetStored(ent:GetClass())
	if not stored or stored.t.RenderGroup ~= nil then return false end
	if ent:GetRenderMode() ~= RENDERMODE_NORMAL or ent:GetColor().a < 255 then return false end

	local model = ent:GetModel()
	if not model then return false end

	local override = ent:GetMaterial()
	local converted = false
	for i, mat in ipairs(materialsOf(ent, model)) do
		local sub = ent:GetSubMaterial(i - 1)
		local name = sub ~= "" and sub or override ~= "" and override or mat
		if classify(name) == SEE then return false end

		converted = converted or opacity.models[name] ~= nil
	end

	return converted
end

local function setGroup(ent, wanted)
	if wanted then
		if not opacity.regrouped[ent] then
			opacity.regrouped[ent] = true
			ent.RenderGroup = RENDERGROUP_OPAQUE
		end
	elseif opacity.regrouped[ent] then
		opacity.regrouped[ent] = nil
		ent.RenderGroup = nil
	end
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
	elseif IsValid(ent:GetParent()) then
		plan = fullPlan(ent)
	end

	updatePac(ent)
	setDepthPlan(ent, plan)

	if ent.Draw ~= nil then
		setGroup(ent, not see and convertedOpaque(ent))
		updateSent(ent)
		setDrawn(ent, not see and ent:EntIndex() > 0 and not ent:IsPlayer() and not ent:IsWeapon())
		setScreen(ent, opaqueScreen(ent))
	end
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

local function alphaReady()
	if not shaderpack.UsableRT(alphaRT, 1024, 1024) then
		alphaRT = GetRenderTargetEx("ms_opacity_alpha", 1024, 1024, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
		return false
	end

	alphaProbe = alphaProbe or CreateMaterial("ms_opacity_alphaprobe", "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$vertexalpha"] = 1,
		["$translucent"] = 1,
	})

	return true
end

local function scanStep()
	local name = worldQueue[#worldQueue]
	if not name then
		hook.Remove("PostRender", "ms_opacity_world")
		saveCache()
		return
	end

	if not alphaReady() then return end

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

local MODEL_CACHE = CACHE_DIR .. "/models.json"
local modelQueue, modelQueued = {}, {}
local modelCache, modelCacheDirty = nil, false

local function convertModel(name)
	if opacity.models[name] then return end

	local mat = Material(name)
	local flags = mat:GetInt("$flags")
	opacity.models[name] = flags
	mat:SetInt("$flags", bit.band(flags, bit.bnot(TRANSLUCENT)))
	materialInfo[name] = nil
	modelPlans = {}
end

local function restoreModels()
	for name, flags in pairs(opacity.models) do
		Material(name):SetInt("$flags", flags)
		opacity.models[name] = nil
		materialInfo[name] = nil
	end

	modelPlans = {}
end

local function saveModelCache()
	if not modelCacheDirty then return end

	file.CreateDir(CACHE_DIR)
	file.Write(MODEL_CACHE, util.TableToJSON(modelCache))
	modelCacheDirty = false
end

local function modelStep()
	local name = modelQueue[#modelQueue]
	if not name then
		hook.Remove("PostRender", "ms_opacity_models")
		saveModelCache()
		return
	end

	if not alphaReady() then return end

	modelQueue[#modelQueue] = nil
	modelQueued[name] = nil

	local tex = Material(name):GetTexture("$basetexture")
	if not tex or tex:IsError() then return end

	local holes, between = measureAlpha(tex)
	local opaque = holes == 0 and between == 0
	modelCache[name] = { key = textureKey(tex), opaque = opaque }
	modelCacheDirty = true
	if opaque then
		convertModel(name)
	end
end

function queueModel(name, mat)
	if opacity.models[name] or modelQueued[name] then return false end

	local tex = mat:GetTexture("$basetexture")
	if not tex or tex:IsError() then return false end

	modelCache = modelCache or util.JSONToTable(file.Read(MODEL_CACHE, "DATA") or "") or {}
	local cached = modelCache[name]
	if cached and cached.key == textureKey(tex) then
		if not cached.opaque then return false end

		convertModel(name)

		return true
	end

	modelQueued[name] = true
	modelQueue[#modelQueue + 1] = name
	hook.Add("PostRender", "ms_opacity_models", modelStep)

	return false
end

local function step()
	if cursor > #queue then
		sweepProxies()
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
	hook.Remove("PostRender", "ms_opacity_models")
	worldQueue = {}
	restoreWorld()
	saveModelCache()
	modelQueue, modelQueued = {}, {}
	restoreModels()

	for ent in pairs(opacity.regrouped) do
		if IsValid(ent) then
			setGroup(ent, false)
		end

		opacity.regrouped[ent] = nil
	end

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

	sweepProxies()

	for ent in pairs(opacity.sents) do
		if IsValid(ent) then
			setSent(ent, false)
		end

		opacity.sents[ent] = nil
	end

	for ent in pairs(drawn) do
		if IsValid(ent) then
			setDrawn(ent, false)
		end

		drawn[ent] = nil
	end

	for ent in pairs(screens) do
		if IsValid(ent) then
			setScreen(ent, false)
		end

		screens[ent] = nil
	end

	for ent, prev in pairs(pacOverrides) do
		if IsValid(ent) and ent.RenderOverride == pacDraw then
			ent.RenderOverride = prev
		end

		pacOverrides[ent] = nil
	end

	modelPlans = {}
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
