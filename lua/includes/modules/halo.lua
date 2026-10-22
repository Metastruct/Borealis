module("halo", package.seeall)

local ROWS_PS, OUTLINE_PS, QUAD_VS = "halo_rows_ps30", "halo_ps30", "aurora_vs30"
local SHADERS = { ROWS_PS, OUTLINE_PS, QUAD_VS }

local FLAGS = bit.bor(STUDIO_RENDER, STUDIO_SKIP_DECALS or 0)
local MAX_WIDTH = 15
local GROUPS_PER_PASS = 6
local CODE_BASE, CODE_STEP = 225, 5
local RETRY = 5

local mat_Copy = CreateMaterial("halo_copy", "UnlitGeneric", {
	["$ignorez"] = 1,
	["$writez"] = 0,
	["$linearwrite"] = 0,
	["$basetexture"] = "_rt_FullFrameFB",
})
local mat_Add = CreateMaterial("halo_add", "UnlitGeneric", {
	["$basetexture"] = "_rt_FullFrameFB",
	["$ignorez"] = 1,
	["$additive"] = 1,
})
local mat_Sub = CreateMaterial("halo_sub", "Modulate", {
	["$ignorez"] = 1,
	["$writez"] = 0,
	["$basetexture"] = "_rt_FullFrameFB",
})

local rt_Store = render.GetScreenEffectTexture(0)
local rt_Blur = render.GetScreenEffectTexture(1)
local colWhite = Vector(1, 1, 1)

local List = {}
local RenderEnt = NULL
local rendering = false

function Add(entities, color, blurx, blury, passes, add, ignorez)
	if table.IsEmpty(entities) then return end
	if add == nil then add = true end
	if ignorez == nil then ignorez = false end

	List[#List + 1] = {
		Ents = entities,
		Color = color,
		BlurX = blurx or 2,
		BlurY = blury or 2,
		DrawPasses = passes or 1,
		Additive = add,
		IgnoreZ = ignorez,
	}
end

function RenderedEntity()
	return RenderEnt
end

local drawing = {}
local reported = {}
local rect = { full = false }
local corner = Vector()

local function resetRect()
	rect.full = false
	rect.x1, rect.y1, rect.x2, rect.y2 = math.huge, math.huge, -math.huge, -math.huge
end

resetRect()

local function growRect(ent)
	if rect.full then return end

	local mins, maxs = ent:GetRenderBounds()
	for i = 0, 7 do
		corner:SetUnpacked(i % 2 == 0 and mins.x or maxs.x, i % 4 < 2 and mins.y or maxs.y, i < 4 and mins.z or maxs.z)
		local s = ent:LocalToWorld(corner):ToScreen()
		if not s.visible then
			rect.full = true
			return
		end
		rect.x1 = math.min(rect.x1, s.x)
		rect.y1 = math.min(rect.y1, s.y)
		rect.x2 = math.max(rect.x2, s.x)
		rect.y2 = math.max(rect.y2, s.y)
	end
end

local function drawPac(ent)
	local pac = _G.pac
	if not (pac and pac.RenderOverride and pac.drawn_entities and pac.drawn_entities[ent] and ent.pac_is_drawing) then return end

	rect.full = true
	local times = ent.pac_rendertime
	local opaque, translucent = times and times.opaque, times and times.translucent
	local exceeded = ent.pac_render_time_exceeded

	pac.RenderOverride(ent, "opaque")
	pac.RenderOverride(ent, "translucent")

	if times then
		times.opaque, times.translucent = opaque, translucent
	end
	ent.pac_rendertime = times
	ent.pac_render_time_exceeded = exceeded
end

local function drawEntity(ent)
	if drawing[ent] or ent:IsDormant() then return end
	drawing[ent] = true
	RenderEnt = ent

	if not ent:GetNoDraw() then
		growRect(ent)

		local override = ent.RenderOverride
		if override then
			override(ent, FLAGS)
		elseif ent:IsWeapon() and ent.DrawWorldModel then
			ent:DrawWorldModel(FLAGS)
		else
			local draw = ent.RenderGroup == RENDERGROUP_TRANSLUCENT and ent.DrawTranslucent or ent.Draw
			if draw then
				draw(ent, FLAGS)
			else
				ent:DrawModel(FLAGS)
			end
		end
	end

	drawPac(ent)

	for _, child in ipairs(ent:GetChildren()) do
		if IsValid(child) and (child:EntIndex() == -1 or child:IsEffectActive(EF_BONEMERGE)) then
			drawEntity(child)
		end
	end

	RenderEnt = NULL
end

local function drawEntities(entities)
	for _, ent in pairs(entities) do
		if IsValid(ent) then
			local ok, err = pcall(drawEntity, ent)
			if not ok then
				RenderEnt = NULL
				local class = IsValid(ent) and ent:GetClass() or "?"
				if not reported[class] then
					reported[class] = true
					ErrorNoHalt("halo: drawing " .. class .. ": " .. tostring(err) .. "\n")
				end
			end
		end
	end
	table.Empty(drawing)
end

local function beginStencil()
	render.SetStencilEnable(true)
	render.SetStencilWriteMask(255)
	render.SetStencilTestMask(255)
	render.SetStencilCompareFunction(STENCIL_ALWAYS)
	render.SetStencilPassOperation(STENCIL_REPLACE)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_KEEP)
end

local function endStencil()
	render.SetStencilEnable(false)
	render.SetStencilTestMask(0)
	render.SetStencilWriteMask(0)
	render.SetStencilReferenceValue(0)
end

local function restoreScene(rt)
	mat_Copy:SetTexture("$basetexture", rt)
	mat_Copy:SetVector("$color", colWhite)
	render.SetMaterial(mat_Copy)
	render.DrawScreenQuad()
end

local function renderBlur(entry)
	local target = render.GetRenderTarget()
	render.CopyRenderTargetToTexture(rt_Store)

	if entry.Additive then
		render.Clear(0, 0, 0, 255, false, true)
	else
		render.Clear(255, 255, 255, 255, false, true)
	end

	cam.Start3D()
		beginStencil()
		render.SetStencilReferenceValue(1)
		render.SuppressEngineLighting(true)
		cam.IgnoreZ(entry.IgnoreZ)
		drawEntities(entry.Ents)
		cam.IgnoreZ(false)
		render.SuppressEngineLighting(false)

		render.SetStencilCompareFunction(STENCIL_EQUAL)
		render.SetStencilPassOperation(STENCIL_KEEP)
		cam.Start2D()
			surface.SetDrawColor(entry.Color)
			surface.DrawRect(0, 0, ScrW(), ScrH())
		cam.End2D()
		render.SetStencilEnable(false)
	cam.End3D()

	render.CopyRenderTargetToTexture(rt_Blur)
	render.BlurRenderTarget(rt_Blur, entry.BlurX, entry.BlurY, 1)
	render.SetRenderTarget(target)
	restoreScene(rt_Store)

	render.SetStencilEnable(true)
	render.SetStencilCompareFunction(STENCIL_NOTEQUAL)
	local mat = entry.Additive and mat_Add or mat_Sub
	mat:SetTexture("$basetexture", rt_Blur)
	render.SetMaterial(mat)
	for _ = 0, entry.DrawPasses do
		render.DrawScreenQuad()
	end
	endStencil()
end

local MASK, ROWS, ROWS_MAT, OUTLINE_MAT
local fillColor = Color(0, 0, 0, 0)
local corners = { Vector(), Vector(), Vector(), Vector() }
local retryAt = 0
local serial = 0
local master

local function setConstant(mat, reg, x, y, z, w)
	mat:SetFloat(reg .. "_x", x)
	mat:SetFloat(reg .. "_y", y)
	mat:SetFloat(reg .. "_z", z)
	mat:SetFloat(reg .. "_w", w)
end

local function constants()
	local t = {}
	for i = 0, 3 do
		for _, c in ipairs({ "x", "y", "z", "w" }) do
			t["$c" .. i .. "_" .. c] = 0
		end
	end
	return t
end

local function shaderReady(w, h)
	master = master or GetConVar("cl_shaderpack")
	if not master or not master:GetBool() or not CreateShaderMaterial then return false end
	if rt_Store:Width() ~= w or rt_Store:Height() ~= h or rt_Blur:Width() ~= w or rt_Blur:Height() ~= h then return false end
	if OUTLINE_MAT then return true end
	if RealTime() < retryAt then return false end
	retryAt = RealTime() + RETRY

	for _, name in ipairs(SHADERS) do
		if not file.Exists("shaders/fxc/" .. name .. ".vcs", "GAME") then return false end
	end

	local mask, rows = rt_Store, rt_Blur
	serial = serial + 1
	local stamp = os.time() .. "_" .. serial
	local rowsParams = constants()
	rowsParams["$pixshader"] = ROWS_PS
	rowsParams["$vertexshader"] = QUAD_VS
	rowsParams["$basetexture"] = mask:GetName()
	rowsParams["$alpha_blend"] = 0
	local outlineParams = constants()
	outlineParams["$pixshader"] = OUTLINE_PS
	outlineParams["$vertexshader"] = QUAD_VS
	outlineParams["$basetexture"] = rows:GetName()
	outlineParams["$alpha_blend"] = 0

	MASK, ROWS = mask, rows
	ROWS_MAT = CreateShaderMaterial("halo_rows_" .. stamp, rowsParams)
	OUTLINE_MAT = CreateShaderMaterial("halo_outline_" .. stamp, outlineParams)

	return true
end

local function groupWidth(entry)
	return math.Clamp(math.Round(math.max(entry.BlurX, entry.BlurY)), 1, MAX_WIDTH)
end

local function groupParams(entry)
	local c = entry.Color
	local color = math.floor(c.r) * 65536 + math.floor(c.g) * 256 + math.floor(c.b)
	local params = groupWidth(entry) + (entry.Additive and 16 or 0) + math.floor(c.a or 255) * 32

	return color, params
end

local function clampRect(pad, w, h)
	if rect.full then return 0, 0, w, h end

	return math.max(0, math.floor(rect.x1) - pad), math.max(0, math.floor(rect.y1) - pad), math.min(w, math.ceil(rect.x2) + pad), math.min(h, math.ceil(rect.y2) + pad)
end

local function renderOutlines(list, first, last)
	local w, h = ScrW(), ScrH()
	local width = 1
	for i = first, last do
		width = math.max(width, groupWidth(list[i]))
	end
	corners[2]:SetUnpacked(w, 0, 0)
	corners[3]:SetUnpacked(w, h, 0)
	corners[4]:SetUnpacked(0, h, 0)

	render.ClearStencil()
	resetRect()

	cam.Start3D()
		beginStencil()
		render.SuppressEngineLighting(true)
		render.OverrideColorWriteEnable(true, false)
		render.OverrideAlphaWriteEnable(true, false)
		for i = first, last do
			render.SetStencilReferenceValue(i - first + 1)
			cam.IgnoreZ(list[i].IgnoreZ)
			drawEntities(list[i].Ents)
		end
		cam.IgnoreZ(false)
		render.SuppressEngineLighting(false)

		local drawn = rect.full or rect.x1 <= rect.x2
		if drawn then
			local fx1, fy1, fx2, fy2 = clampRect(width * 3 + 1, w, h)
			render.SetScissorRect(fx1, fy1, fx2, fy2, true)
			render.SetStencilCompareFunction(STENCIL_EQUAL)
			render.SetStencilPassOperation(STENCIL_KEEP)
			render.OverrideAlphaWriteEnable(false, false)
			render.OverrideAlphaWriteEnable(true, true)
			render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
			render.SetColorMaterialIgnoreZ()
			cam.Start2D()
				for id = 0, last - first + 1 do
					render.SetStencilReferenceValue(id)
					fillColor.a = id > 0 and CODE_BASE + id * CODE_STEP or 0
					render.DrawQuad(corners[1], corners[2], corners[3], corners[4], fillColor)
				end
			cam.End2D()
			render.OverrideBlend(false)
			render.SetScissorRect(0, 0, 0, 0, false)
		end
		render.OverrideAlphaWriteEnable(false, false)
		render.OverrideColorWriteEnable(false, false)
		endStencil()
	cam.End3D()

	if not drawn then return end

	render.CopyRenderTargetToTexture(MASK)

	local hx1, hy1, hx2, hy2 = clampRect(width * 2 + 1, w, h)
	setConstant(ROWS_MAT, "$c0", 1 / w, 1 / h, width, 0)
	render.PushRenderTarget(ROWS)
	render.SetScissorRect(hx1, hy1, hx2, hy2, true)
	render.SetMaterial(ROWS_MAT)
	render.DrawScreenQuad()
	render.SetScissorRect(0, 0, 0, 0, false)
	render.PopRenderTarget()

	setConstant(OUTLINE_MAT, "$c0", 1 / w, 1 / h, width, 0)
	local params = {}
	for i = first, first + GROUPS_PER_PASS - 1 do
		local color, packed = 0, 0
		if i <= last then
			color, packed = groupParams(list[i])
		end
		params[#params + 1] = color
		params[#params + 1] = packed
	end
	setConstant(OUTLINE_MAT, "$c1", params[1], params[2], params[3], params[4])
	setConstant(OUTLINE_MAT, "$c2", params[5], params[6], params[7], params[8])
	setConstant(OUTLINE_MAT, "$c3", params[9], params[10], params[11], params[12])

	local vx1, vy1, vx2, vy2 = clampRect(width + 1, w, h)
	render.SetScissorRect(vx1, vy1, vx2, vy2, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD)
	render.SetMaterial(OUTLINE_MAT)
	render.DrawScreenQuad()
	render.OverrideBlend(false)
	render.SetScissorRect(0, 0, 0, 0, false)
end

local function renderList(list)
	if shaderReady(ScrW(), ScrH()) then
		for first = 1, #list, GROUPS_PER_PASS do
			renderOutlines(list, first, math.min(#list, first + GROUPS_PER_PASS - 1))
		end
	else
		for _, entry in ipairs(list) do
			renderBlur(entry)
		end
	end
end

function Render(entry)
	renderList({ entry })
end

hook.Add("PostDrawEffects", "RenderHalos", function()
	if rendering then return end

	hook.Run("PreDrawHalos")
	if #List == 0 then return end

	local list = List
	List = {}
	rendering = true
	local ok, err = pcall(renderList, list)
	rendering = false
	if not ok then
		ErrorNoHalt("halo: " .. tostring(err) .. "\n")
	end
end)
