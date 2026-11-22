local snow = shaderpack.snow
local flashlight = snow.flashlight or {}
snow.flashlight = flashlight

local RT_FLAGS = 1 + 4 + 8
local NO_TEXTURE = "vgui/black"
local ALBEDO = "[0.6 0.6 0.62]"

local material, rt
local meshes, count = {}, 0
local anyFlashlight = false

local function drawMeshes()
	render.SetMaterial(material)
	for i = 1, count do
		meshes[i]:Draw()
	end
end

local function noteFlashlight()
	anyFlashlight = true
end

local function ensureRT()
	local w, h = ScrW(), ScrH()
	if not shaderpack.UsableRT(rt, w, h) then
		rt = GetRenderTargetEx("borealis_snow_flashlight_" .. w .. "x" .. h, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA16161616F)
		if not shaderpack.UsableRT(rt, w, h) then
			rt = nil

			return
		end
	end

	return rt
end

function flashlight.Start(suffix)
	material = CreateMaterial("borealis_snow_flashlight_" .. suffix, "VertexLitGeneric", {
		["$basetexture"] = "color/white",
		["$color2"] = ALBEDO,
		["$model"] = 1,
		["$nocull"] = 1,
	})
end

function flashlight.Render(visible, nvis)
	meshes, count = visible, nvis
	anyFlashlight = false
	render.RenderFlashlights(noteFlashlight)
	if not anyFlashlight or not ensureRT() then return NO_TEXTURE, 0, 0 end

	render.PushRenderTarget(rt)
	render.Clear(0, 0, 0, 0, true, true)
	render.OverrideColorWriteEnable(true, false)
	render.OverrideDepthEnable(true, true)
	drawMeshes()
	render.OverrideDepthEnable(false, false)
	render.OverrideColorWriteEnable(false, false)
	render.RenderFlashlights(drawMeshes)
	render.PopRenderTarget()

	return rt, 1 / rt:Width(), 1 / rt:Height()
end
