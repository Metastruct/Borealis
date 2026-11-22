local skywall = shaderpack.skywall or {}
shaderpack.skywall = skywall

local bspdata = bspdata
local VS, PS = "borealis_water_vs30", "borealis_waterdepth_ps30"
local MESH_TRIS = 10000
local RT_FLAGS = 1 + 4 + 8
local NO_TEXTURE = "vgui/black"
local IDENTITY = Matrix()

local meshes, mat, rt, renderedFrame
local invW, invH = 0, 0

local function destroy()
	for _, m in ipairs(meshes or {}) do
		m:Destroy()
	end

	meshes = nil
end

local function build()
	destroy()
	if not shaderpack.Available({ VS, PS }) then return end

	mat = mat or CreateShaderMaterial("borealis_skywall_" .. os.time(), {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
		["$ignorez"] = 0,
		["$depthtest"] = 1,
	})

	meshes = {}
	local tris = bspdata.SkyTriangles()
	local total = #tris / 9
	local pos = Vector()
	for first = 0, total - 1, MESH_TRIS do
		local count = math.min(MESH_TRIS, total - first)
		local m = Mesh()
		mesh.Begin(m, MATERIAL_TRIANGLES, count)
		for v = first * 3, (first + count) * 3 - 1 do
			pos:SetUnpacked(tris[v * 3 + 1], tris[v * 3 + 2], tris[v * 3 + 3])
			mesh.Position(pos)
			mesh.TexCoord(0, 0, 0)
			mesh.Color(255, 255, 255, 255)
			mesh.AdvanceVertex()
		end
		mesh.End()
		meshes[#meshes + 1] = m
	end
end

local function ensureRT()
	local w, h = ScrW(), ScrH()
	if not shaderpack.UsableRT(rt, w, h) then
		rt = GetRenderTargetEx("borealis_skywall_" .. w .. "x" .. h, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA16161616F)
		if not shaderpack.UsableRT(rt, w, h) then return end
	end

	invW, invH = 1 / w, 1 / h

	return rt
end

function skywall.Texture()
	if not meshes or #meshes == 0 then return NO_TEXTURE end
	if renderedFrame == FrameNumber() then return rt end
	if render.GetRenderTarget() ~= nil or not ensureRT() then return NO_TEXTURE end

	render.PushRenderTarget(rt)
	render.Clear(0, 0, 0, 0, true, true)
	render.SetMaterial(mat)
	render.OverrideDepthEnable(true, true)
	cam.PushModelMatrix(IDENTITY, false)
	for _, m in ipairs(meshes) do
		m:Draw()
	end
	cam.PopModelMatrix()
	render.OverrideDepthEnable(false, false)
	render.PopRenderTarget()
	renderedFrame = FrameNumber()

	return rt
end

function skywall.InvSize()
	return invW, invH
end

shaderpack.AfterWorld("borealis_skywall", build)
