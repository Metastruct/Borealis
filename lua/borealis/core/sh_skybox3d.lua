local VS, DEPTH_PS, COMPOSITE_PS, QUAD_VS = "borealis_water_vs30", "borealis_waterdepth_ps30", "borealis_skydepth_ps30", "borealis_passthrough_vs30"

if SERVER then
	shaderpack.AddResources({ VS, DEPTH_PS, COMPOSITE_PS, QUAD_VS })

	return
end

local skybox3d = shaderpack.skybox3d or {}
shaderpack.skybox3d = skybox3d

local bspdata, depthslices = bspdata, shaderpack.depthslices
local ENABLED = CreateClientConVar("borealis_skybox3d", "1", true, false, "give the 3D skybox depth so effects reach into it")
local SKY_3D = GetConVar("r_3dsky")
local SKIP_FLAGS = bit.bor(SURF_SKY2D, SURF_SKY, SURF_WARP, SURF_TRANS, SURF_NODRAW, SURF_HINT, SURF_SKIP)
local CUTOUT_FLAGS = 128 + 256 + 2097152
local EDGE = 1
local MESH_TRIS = 10000
local RT_FLAGS = 1 + 4 + 8
local R32F = 27
local IDENTITY = Matrix()

local meshes, skyClusters, building, bounds
local cutouts = {}
local depthView = { type = "3D", x = 0, y = 0 }
local depthMat, compositeMat, skyRT, copyRT
local visibleCluster, visibleResult = -2, false

skybox3d.Camera = bspdata.SkyCamera

function skybox3d.ToWorldVector(v)
	return Vector(bspdata.SkyToWorld(v.x, v.y, v.z))
end

local function destroy()
	for _, m in ipairs(meshes or {}) do
		m:Destroy()
	end

	for _, c in ipairs(cutouts) do
		if IsValid(c.ent) then c.ent:Remove() end
	end
	cutouts = {}

	meshes = nil
end

local function writeMeshes(tris)
	local toWorld, beyond = bspdata.SkyToWorld, bspdata.BeyondWorld
	local kept, n = {}, 0
	for i = 1, #tris, 9 do
		local ax, ay, az = toWorld(tris[i], tris[i + 1], tris[i + 2])
		local bx, by, bz = toWorld(tris[i + 3], tris[i + 4], tris[i + 5])
		local cx, cy, cz = toWorld(tris[i + 6], tris[i + 7], tris[i + 8])
		if beyond(ax, ay, az, EDGE) or beyond(bx, by, bz, EDGE) or beyond(cx, cy, cz, EDGE) then
			kept[n + 1], kept[n + 2], kept[n + 3] = ax, ay, az
			kept[n + 4], kept[n + 5], kept[n + 6] = bx, by, bz
			kept[n + 7], kept[n + 8], kept[n + 9] = cx, cy, cz
			n = n + 9
		end
	end

	local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
	for i = 1, n, 3 do
		local x, y, z = kept[i], kept[i + 1], kept[i + 2]
		if x < x0 then x0 = x end
		if x > x1 then x1 = x end
		if y < y0 then y0 = y end
		if y > y1 then y1 = y end
		if z < z0 then z0 = z end
		if z > z1 then z1 = z end
	end
	bounds = { x0, y0, z0, x1, y1, z1 }

	meshes = {}
	local total = n / 9
	local pos = Vector()
	for first = 0, total - 1, MESH_TRIS do
		local count = math.min(MESH_TRIS, total - first)
		local m = Mesh()
		mesh.Begin(m, MATERIAL_TRIANGLES, count)
		for v = first * 3, (first + count) * 3 - 1 do
			pos:SetUnpacked(kept[v * 3 + 1], kept[v * 3 + 2], kept[v * 3 + 3])
			mesh.Position(pos)
			mesh.TexCoord(0, 0, 0)
			mesh.Color(255, 255, 255, 255)
			mesh.AdvanceVertex()
		end
		mesh.End()
		meshes[#meshes + 1] = m
		coroutine.yield()
	end
end

local function opaqueMaterial(name)
	local mat = Material(name)

	return not mat:IsError() and bit.band(mat:GetInt("$flags"), CUTOUT_FLAGS) == 0
end

local function addCutoutProp(prop)
	local ent = ClientsideModel(prop.model, RENDERGROUP_OPAQUE)
	if not IsValid(ent) then return end

	local scale = bspdata.SkyCamera().scale * prop.scale
	local m = Matrix()
	m:Scale(Vector(scale, scale, scale))
	ent:SetNoDraw(true)
	ent:SetPos(Vector(bspdata.SkyToWorld(prop.origin:Unpack())))
	ent:SetAngles(prop.angles)
	ent:EnableMatrix("RenderMultiply", m)
	cutouts[#cutouts + 1] = { ent = ent, pos = ent:GetPos(), radius = ent:GetModelRadius() * scale }
end

local function addProps(out)
	local cache = {}
	local m, scale = Matrix(), Vector()
	for _, prop in ipairs(bspdata.StaticProps()) do
		local o = prop.origin
		if prop.model and bspdata.InSkybox(o.x, o.y, o.z) then
			local parts = cache[prop.model]
			if parts == nil then
				parts = util.GetModelMeshes(prop.model, 0) or false
				cache[prop.model] = parts
			end

			m:Identity()
			m:SetTranslation(o)
			m:SetAngles(prop.angles)
			scale:SetUnpacked(prop.scale, prop.scale, prop.scale)
			m:Scale(scale)
			local cutout = false
			for _, part in ipairs(parts or {}) do
				if opaqueMaterial(part.material) then
					for _, v in ipairs(part.triangles) do
						local p = m * v.pos
						local n = #out
						out[n + 1], out[n + 2], out[n + 3] = p.x, p.y, p.z
					end
				else
					cutout = true
				end
			end

			if cutout then addCutoutProp(prop) end
			coroutine.yield()
		end
	end

	return out
end

local function buildRoutine()
	if not bspdata.WaitVis() then return end

	local skybox = bspdata.SkyboxPVS()
	if not skybox then return end

	skyClusters = bspdata.SkyClusters(skybox)
	writeMeshes(addProps(bspdata.SkyboxTriangles(SKIP_FLAGS)))
	hook.Run("Skybox3DReady")
end

local function stepBuild()
	if not building then return end

	local ok, why = coroutine.resume(building)
	if not ok then
		building = nil
		hook.Remove("Think", "borealis_skybox3d_build")
		ErrorNoHalt("[skybox3d] " .. tostring(why) .. "\n")
	elseif coroutine.status(building) == "dead" then
		building = nil
		hook.Remove("Think", "borealis_skybox3d_build")
	end
end

function skybox3d.Ready()
	return meshes ~= nil and #meshes > 0
end

function skybox3d.Visible(eye)
	if not skybox3d.Ready() or not SKY_3D:GetBool() then return false end

	local cluster = bspdata.ClusterAt(eye.x, eye.y, eye.z)
	if cluster == visibleCluster then return visibleResult end
	visibleCluster = cluster

	local pvs = cluster >= 0 and bspdata.PVS(cluster)
	visibleResult = not pvs
	if pvs then
		for c in pairs(skyClusters) do
			if pvs[c] then
				visibleResult = true
				break
			end
		end
	end

	return visibleResult
end

local function drawMeshes()
	cam.PushModelMatrix(IDENTITY, false)
	for _, m in ipairs(meshes) do
		m:Draw()
	end
	cam.PopModelMatrix()
end

local function targets()
	local w, h = ScrW(), ScrH()
	if not shaderpack.UsableRT(skyRT, w, h) then
		skyRT = GetRenderTargetEx("borealis_skybox3d_depth_" .. w .. "x" .. h, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA16161616F)
		copyRT = GetRenderTargetEx("borealis_skybox3d_copy_" .. w .. "x" .. h, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, R32F)
		if not shaderpack.UsableRT(skyRT, w, h) or not shaderpack.UsableRT(copyRT, w, h) then return false end
	end

	return true, w, h
end

local function farthest(eye)
	local ex, ey, ez = eye:Unpack()
	local dx = math.max(math.abs(bounds[1] - ex), math.abs(bounds[4] - ex))
	local dy = math.max(math.abs(bounds[2] - ey), math.abs(bounds[5] - ey))
	local dz = math.max(math.abs(bounds[3] - ez), math.abs(bounds[6] - ez))

	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function writeDepthTexture(eye)
	if not depthslices.DepthPassFresh() then return end

	local ok, w, h = targets()
	if not ok then return end

	local vs = render.GetViewSetup()
	depthView.w, depthView.h = w, h
	depthView.origin, depthView.angles = vs.origin, vs.angles
	depthView.fov, depthView.aspect = vs.fov, vs.aspect
	depthView.znear, depthView.zfar = vs.znear, math.max(vs.zfar, farthest(eye))

	render.PushRenderTarget(skyRT)
	render.Clear(0, 0, 0, 0, true, true)
	cam.Start(depthView)
	render.SetMaterial(depthMat)
	render.OverrideDepthEnable(true, true)
	drawMeshes()
	render.OverrideDepthEnable(false, false)
	cam.End3D()
	render.PopRenderTarget()

	render.PushRenderTarget(render.GetResolvedFullFrameDepth())
	render.CopyRenderTargetToTexture(copyRT)
	compositeMat:SetTexture("$basetexture", copyRT)
	compositeMat:SetTexture("$texture1", skyRT)
	compositeMat:SetFloat("$c0_x", 1 / w)
	compositeMat:SetFloat("$c0_y", 1 / h)
	render.SetMaterial(compositeMat)
	render.DrawScreenQuad()
	render.PopRenderTarget()
end

local function reach()
	local r = 0
	for _, grid in pairs(shaderpack.chunks.grids) do
		if grid.started then r = math.max(r, grid.radius) end
	end

	return r
end

local function drawCutouts(eye)
	local r = reach()
	if r <= 0 or #cutouts == 0 then return end

	render.SuppressEngineLighting(true)
	for _, c in ipairs(cutouts) do
		local limit = r + c.radius
		if c.pos:DistToSqr(eye) < limit * limit and IsValid(c.ent) then
			c.ent:DrawModel()
		end
	end
	render.SuppressEngineLighting(false)
end

local function writeHardwareDepth(eye)
	render.SetMaterial(depthMat)
	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, false)
	render.OverrideDepthEnable(true, true)
	drawMeshes()
	render.OverrideDepthEnable(false, false)
	drawCutouts(eye)
	render.OverrideAlphaWriteEnable(false, false)
	render.OverrideColorWriteEnable(false, false)
end

local function draw(bDepth, bSkybox, b3DSky)
	if bDepth or b3DSky or render.GetRenderTarget() ~= nil then return end
	local eye = EyePos()
	if not skybox3d.Visible(eye) then return end

	writeDepthTexture(eye)
	writeHardwareDepth(eye)
end

local function stop()
	hook.Remove("PreDrawOpaqueRenderables", "borealis_skybox3d")
	hook.Remove("Think", "borealis_skybox3d_build")
	building = nil
	destroy()
	visibleCluster = -2
end

local function start()
	stop()

	depthMat = CreateShaderMaterial("borealis_skybox3d_depth_" .. os.time(), {
		["$pixshader"] = DEPTH_PS,
		["$vertexshader"] = VS,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
		["$ignorez"] = 0,
		["$depthtest"] = 1,
	})
	compositeMat = CreateShaderMaterial("borealis_skybox3d_composite_" .. os.time(), {
		["$pixshader"] = COMPOSITE_PS,
		["$vertexshader"] = QUAD_VS,
		["$alpha_blend"] = 0,
		["$linearread_basetexture"] = 1,
		["$linearread_texture1"] = 1,
		["$linearwrite"] = 1,
		["$ignorez"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
	})

	shaderpack.AfterWorld("borealis_skybox3d", function()
		if not skybox3d.Camera() then return end

		building = coroutine.create(buildRoutine)
		hook.Add("Think", "borealis_skybox3d_build", stepBuild)
		hook.Add("PreDrawOpaqueRenderables", "borealis_skybox3d", draw)
	end)
end

shaderpack.Toggle("borealis_skybox3d", ENABLED, { VS, DEPTH_PS, COMPOSITE_PS, QUAD_VS }, start, stop)()
