local dynamiclights = shaderpack.dynamiclights or {}
shaderpack.dynamiclights = dynamiclights

local CELL, CELLS = 64, 24
local SLICES = 4
local SLICE_ROWS = CELLS / SLICES
local HEIGHT_CACHE_LIMIT = 16384
local HEIGHT_BAND, HEIGHT_BANDS = 64, 1024
local TRACE_UP, TRACE_DOWN = 128, 1024
local SAMPLE_HEIGHT = 12
local PROJECTED_TEXELS = 256
local PROJECTED_VIEW_HEIGHT = 4096
local PROJECTED_ALBEDO = "[0.5 0.5 0.5]"

local UP = Vector(0, 0, 1)
local samplePos = Vector()
local exitPos = Vector()
local heightRes = {}
local heightTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = heightRes }

local rt, updatedFrame, gridX, gridY
local nextSlice = 0
local sliceLit = {}
local heights, heightCount = {}, 0
local litX, litY, litR, litG, litB = {}, {}, {}, {}, {}

local function heightBand(z)
	return math.floor(z / HEIGHT_BAND)
end

local function groundHeight(cx, cy, x, y, z)
	local band = heightBand(z)
	local key = shaderpack.chunks.Key(cx, cy) * HEIGHT_BANDS + band
	local height = heights[key]
	if height then return height end

	local base = band * HEIGHT_BAND
	local top, bottom = base + TRACE_UP, base - TRACE_DOWN
	heightTrace.start:SetUnpacked(x, y, top)
	heightTrace.endpos:SetUnpacked(x, y, bottom)
	util.TraceLine(heightTrace)
	if heightRes.StartSolid and not heightRes.AllSolid then
		local exit = top + (bottom - top) * heightRes.FractionLeftSolid - 1
		exitPos:SetUnpacked(x, y, exit)
		if bit.band(util.PointContents(exitPos), CONTENTS_SOLID) == 0 then
			heightTrace.start:SetUnpacked(x, y, exit)
			util.TraceLine(heightTrace)
		end
	end
	height = heightRes.AllSolid and base or heightRes.HitPos.z

	if heightCount >= HEIGHT_CACHE_LIMIT then
		heights, heightCount = {}, 0
	end

	heights[key] = height
	heightCount = heightCount + 1

	return height
end

function dynamiclights.Texture()
	if not rt then
		rt = GetRenderTargetEx("borealis_dynamiclights_" .. CELLS, CELLS, CELLS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
		if not shaderpack.UsableRT(rt, CELLS) then
			rt = nil

			return
		end

		render.PushRenderTarget(rt)
		render.Clear(0, 0, 0, 255)
		render.PopRenderTarget()
	end

	return rt
end

local function updateSlice(slice, x0, y0, z)
	local compute = render.ComputeDynamicLighting
	local floor = math.floor
	local row0 = slice * SLICE_ROWS
	local lit = 0
	for iy = row0, row0 + SLICE_ROWS - 1 do
		local cy = y0 + iy
		local y = (cy + 0.5) * CELL
		for ix = 0, CELLS - 1 do
			local cx = x0 + ix
			local x = (cx + 0.5) * CELL
			samplePos:SetUnpacked(x, y, groundHeight(cx, cy, x, y, z) + SAMPLE_HEIGHT)
			local l = compute(samplePos, UP)
			if l.x > 0 or l.y > 0 or l.z > 0 then
				lit = lit + 1
				litX[lit], litY[lit], litR[lit], litG[lit], litB[lit] = ix, iy, l.x, l.y, l.z
			end
		end
	end

	if lit == 0 and not sliceLit[slice] then return end
	sliceLit[slice] = lit > 0

	render.PushRenderTarget(rt)
	render.SetViewPort(0, row0, CELLS, SLICE_ROWS)
	render.Clear(0, 0, 0, 255)
	for i = 1, lit do
		render.SetViewPort(litX[i], litY[i], 1, 1)
		render.Clear(math.min(floor(litR[i] * 127.5), 255), math.min(floor(litG[i] * 127.5), 255), math.min(floor(litB[i] * 127.5), 255), 255)
	end

	render.SetViewPort(0, 0, CELLS, CELLS)
	render.PopRenderTarget()
end

function dynamiclights.Update(eye)
	local frame = FrameNumber()
	if not rt or updatedFrame == frame then return end
	updatedFrame = frame

	local x0, y0 = math.floor(eye.x / CELL + 0.5) - CELLS / 2, math.floor(eye.y / CELL + 0.5) - CELLS / 2
	local first, last = nextSlice, nextSlice
	if x0 ~= gridX or y0 ~= gridY then
		gridX, gridY = x0, y0
		first, last = 0, SLICES - 1
	end
	nextSlice = (nextSlice + 1) % SLICES

	for slice = first, last do
		updateSlice(slice, x0, y0, eye.z)
	end
end

local projectedRT, projectedMat, groundMesh, groundMeshX, groundMeshY, groundMeshBand, projectedFrame, projectedLit
local anyProjected = false
local vertexPos = Vector()
local projectedView = { type = "3D", origin = Vector(), angles = Angle(90, 90, 0), x = 0, y = 0, w = PROJECTED_TEXELS, h = PROJECTED_TEXELS, znear = 1, zfar = PROJECTED_VIEW_HEIGHT * 2, ortho = {} }

function dynamiclights.ProjectedTexture()
	if not projectedRT then
		projectedRT = GetRenderTargetEx("borealis_projectedlights_" .. PROJECTED_TEXELS, PROJECTED_TEXELS, PROJECTED_TEXELS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
		if not shaderpack.UsableRT(projectedRT, PROJECTED_TEXELS) then
			projectedRT = nil

			return
		end

		projectedMat = CreateMaterial("borealis_projectedlights_" .. os.time(), "VertexLitGeneric", {
			["$basetexture"] = "color/white",
			["$color2"] = PROJECTED_ALBEDO,
			["$model"] = 1,
			["$nocull"] = 1,
		})

		render.PushRenderTarget(projectedRT)
		render.Clear(0, 0, 0, 255)
		render.PopRenderTarget()
	end

	return projectedRT
end

local function buildGroundMesh(x0, y0, z)
	if groundMesh then groundMesh:Destroy() end

	local function vertex(cx, cy)
		local x, y = (cx + 0.5) * CELL, (cy + 0.5) * CELL
		vertexPos:SetUnpacked(x, y, groundHeight(cx, cy, x, y, z) + SAMPLE_HEIGHT)
		mesh.Position(vertexPos)
		mesh.Normal(UP)
		mesh.TexCoord(0, 0, 0)
		mesh.Color(255, 255, 255, 255)
		mesh.AdvanceVertex()
	end

	groundMesh = Mesh()
	mesh.Begin(groundMesh, MATERIAL_QUADS, (CELLS - 1) * (CELLS - 1))
	for iy = 0, CELLS - 2 do
		for ix = 0, CELLS - 2 do
			local cx, cy = x0 + ix, y0 + iy
			vertex(cx, cy)
			vertex(cx + 1, cy)
			vertex(cx + 1, cy + 1)
			vertex(cx, cy + 1)
		end
	end
	mesh.End()
	groundMeshX, groundMeshY, groundMeshBand = x0, y0, heightBand(z)
end

local function markProjected()
	anyProjected = true
end

local function drawGroundMesh()
	render.SetMaterial(projectedMat)
	groundMesh:Draw()
end

function dynamiclights.UpdateProjected(eye)
	local frame = FrameNumber()
	if not projectedRT or projectedFrame == frame then return end
	projectedFrame = frame

	anyProjected = false
	render.RenderFlashlights(markProjected)
	if not anyProjected and not projectedLit then return end
	projectedLit = anyProjected

	render.PushRenderTarget(projectedRT)
	render.Clear(0, 0, 0, 255)
	if anyProjected then
		local x0, y0 = math.floor(eye.x / CELL + 0.5) - CELLS / 2, math.floor(eye.y / CELL + 0.5) - CELLS / 2
		if not groundMesh or x0 ~= groundMeshX or y0 ~= groundMeshY or heightBand(eye.z) ~= groundMeshBand then
			buildGroundMesh(x0, y0, eye.z)
		end

		local half = CELLS * CELL * 0.5
		local ortho = projectedView.ortho
		ortho.left, ortho.right, ortho.top, ortho.bottom = -half, half, -half, half
		projectedView.origin:SetUnpacked((x0 + CELLS / 2) * CELL, (y0 + CELLS / 2) * CELL, eye.z + PROJECTED_VIEW_HEIGHT)
		cam.Start(projectedView)
		cam.IgnoreZ(true)
		render.RenderFlashlights(drawGroundMesh)
		cam.IgnoreZ(false)
		cam.End()
	end
	render.PopRenderTarget()
end
