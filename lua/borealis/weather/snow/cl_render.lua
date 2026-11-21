local snow = shaderpack.snow
local bspdata, depthslices, foliage, chunks, dynamiclights = bspdata, shaderpack.depthslices, shaderpack.foliage, shaderpack.chunks, shaderpack.dynamiclights
local geometry, meshBuilder, cache, download, lighting, trails, flashlight, footsteps = snow.geometry, snow.meshBuilder, snow.cache, snow.download, snow.lighting, snow.trails, snow.flashlight, snow.footsteps

local ENABLED = CreateClientConVar("borealis_snow", "1", true, false, "draw deep snow with footprints in winter")
local DISTANCE = CreateClientConVar("borealis_snow_distance", "3072", true, false, "snow draw distance in units", 1024, 16384)

local CHUNK, STRIDE = snow.CHUNK, snow.STRIDE
local SKY_CLUSTER = bspdata.SKY_CLUSTER
local NO_WALL = "vgui/black"
local MESH_TRIS = 10000
local MESH_CACHE_TRIS = jit.arch == "x64" and math.huge or 300000
local PRELOAD = jit.arch == "x64"
local FILL_K = 0.5
local TOD_MATCH = 0.29
local TOD_SUN_GAIN = 1.05
local TOD_STYLE_GAIN = 1
local TOD_RETINT = 0.02

local setConstant, packColor, toLinear = shaderpack.SetConstant, shaderpack.PackColor, shaderpack.ToLinear

local paused, running = false, false
local fadeStart, fadeEnd
local cacheDir
local grid

function snow.SetPaused(state)
	paused = state
	grid:SetPaused(state)
	if not running then return end

	if state then
		trails.Stop()
	else
		trails.Start()
	end
end

function snow.Running()
	return running and not paused
end

local function readChunk(ch)
	if download.Active() then return cache.Decode(ch, download.Read(ch)) end
	if not cacheDir then return end

	return cache.Decode(ch, file.Read(cache.ChunkPath(cacheDir, ch), "DATA"))
end

local function writeChunk(ch, verts, tris)
	if not cacheDir or download.Active() then return end

	file.Write(cache.ChunkPath(cacheDir, ch), cache.Encode(ch, verts, tris))
end

local vpos, vnormal = Vector(), Vector()

local function buildChunk(ch)
	local verts, tris = readChunk(ch)
	if not verts then
		if not geometry.Triangles() then
			local ok, why = geometry.Load()
			if not ok then error(why) end
		end

		verts, tris = meshBuilder.Build(ch)
		writeChunk(ch, verts, tris)
	end

	if tris > 0 then lighting.Resolve(ch, verts, tris) end

	local groups, steps = {}, {}
	ch.groups = groups
	local o = 0
	for i, cluster in ipairs(tris > 0 and ch.clusters or {}) do
		local left = ch.clusterTris[i]
		local g = { cluster = cluster, meshes = {} }
		groups[i] = g

		while left > 0 do
			chunks.YieldIfOverBudget()
			local count = math.min(left, MESH_TRIS)
			local m = Mesh()
			mesh.Begin(m, MATERIAL_TRIANGLES, count)
			for k = 1, count * 3 do
				local light = verts[o + 6]
				local nx, ny = verts[o + 4], verts[o + 5]
				vpos:SetUnpacked(verts[o + 1], verts[o + 2], verts[o + 3])
				if k % 3 == 1 then footsteps.Mark(steps, verts, o) end
				vnormal:SetUnpacked(nx, ny, math.sqrt(math.max(1 - nx * nx - ny * ny, 0)))
				mesh.Position(vpos)
				mesh.Normal(vnormal)
				mesh.TexCoord(0, nx, ny)
				mesh.Color(math.floor(light / 65536), math.floor(light / 256) % 256, light % 256, math.floor(verts[o + 7] * 255 + 0.5))
				mesh.AdvanceVertex()
				o = o + STRIDE
			end
			mesh.End()
			g.meshes[#g.meshes + 1] = m
			left = left - count
		end
	end
	ch.steps = steps

	return tris
end

local function load()
	local vis, why = bspdata.WaitVis()
	if not vis then return false, why end

	local key = cache.Key()
	cacheDir = key and cache.DIR .. "/" .. key or nil
	if key then
		file.CreateDir(cacheDir)
		cache.Prune(key)
	end

	return true
end

local function destroyChunk(ch)
	for _, g in ipairs(ch.groups or {}) do
		for _, m in ipairs(g.meshes) do
			m:Destroy()
		end
	end
	ch.groups, ch.steps = nil, nil
end

local MAT, DEPTH_MAT
local materialSerial = 0
local extra = Matrix()

local function skyTint(tonemap)
	local procsky = shaderpack.procsky
	if procsky and procsky.GetSkyColors then
		local _, z = procsky.GetSkyColors()

		return z[1] * tonemap, z[2] * tonemap, z[3] * tonemap
	end

	local r, g, b = render.GetFogColor()

	return toLinear(r) * tonemap, toLinear(g) * tonemap, toLinear(b) * tonemap
end

local visible = {}
local sight = chunks.Sight()
local matchedScale, matchedR, matchedG, matchedB

local function todChannel(light, amb, scale)
	local world = tod.light_environment_named and amb + TOD_SUN_GAIN * math.max(light - amb, 0) * scale or TOD_STYLE_GAIN * light * scale

	return TOD_MATCH * (light * scale + amb * FILL_K) / math.max(world, 1e-3)
end

local function matchTodSnow(scale, amb)
	local setTint = tod and tod.snow and tod.snow.SetTint
	if not setTint then return end

	local r, g, b = lighting.Average()
	if not r then return end
	if scale == matchedScale and math.abs(r - matchedR) + math.abs(g - matchedG) + math.abs(b - matchedB) < TOD_RETINT then return end

	matchedScale, matchedR, matchedG, matchedB = scale, r, g, b
	setTint(Vector(todChannel(r, amb.x, scale), todChannel(g, amb.y, scale), todChannel(b, amb.z, scale)))
end

local function releaseTodSnow()
	matchedScale = nil
	if tod and tod.snow and tod.snow.SetTint then tod.snow.SetTint() end
end

local function collect(shown, sky, n)
	for _, ch in ipairs(shown) do
		for _, g in ipairs(ch.groups) do
			if (g.cluster == SKY_CLUSTER) == sky and sight:Shows(g) then
				for _, m in ipairs(g.meshes) do
					n = n + 1
					visible[n] = m
				end
			end
		end
	end

	return n
end

local function drawRange(mat, first, last, wallTex)
	if first > last then return end

	mat:SetTexture("$texture3", wallTex)
	render.SetMaterial(mat)
	for i = first, last do
		visible[i]:Draw()
	end
end

local function draw(depth, _, sky3d)
	if paused or not grid.ready or depth or sky3d or render.GetRenderTarget() then return end

	local amb = render.GetAmbientLightColor()
	matchTodSnow(foliage.WorldLightScale(), amb)

	local view = chunks.View()
	local eye = view.eye
	sight:Begin(eye)

	local shown = grid:Visible(view)
	local nworld = collect(shown, false, 0)
	local nvis = collect(shown, true, nworld)

	for i = #visible, nvis + 1, -1 do
		visible[i] = nil
	end

	if nvis == 0 then return end

	dynamiclights.Update(eye)
	cam.PushModelMatrix(Matrix(), false)
	local flashlightTex, flashInvW, flashInvH = flashlight.Render(visible, nvis)
	MAT:SetTexture("$texture4", flashlightTex)
	MAT:SetTexture("$basetexture", trails.Texture())
	MAT:SetTexture("$texture2", dynamiclights.Texture())
	local wallTex = shaderpack.skywall.Texture()
	local invW, invH = shaderpack.skywall.InvSize()

	local tonemap = shaderpack.ToneMapScale()
	local sun = bspdata.BakedSun()
	setConstant(MAT, "$c0", eye.x, eye.y, eye.z, CurTime() % 1000)
	setConstant(MAT, "$c1", trails.Window())
	setConstant(MAT, "$c2", sun.x, sun.y, sun.z, foliage.WorldLightScale())
	setConstant(MAT, "$c3", packColor(amb.x * FILL_K, amb.y * FILL_K, amb.z * FILL_K), tonemap, fadeStart, fadeEnd)

	local fr, fg, fb = render.GetFogColor()
	local fogStart, fogEnd = render.GetFogDistances()
	local fogMax = render.GetFogMode() == MATERIAL_FOG_NONE and 0 or render.GetFogMaxDensity()
	local sr, sg, sb = skyTint(tonemap)
	extra:SetUnpacked(
		toLinear(fr) * tonemap, toLinear(fg) * tonemap, toLinear(fb) * tonemap, fogStart,
		fogEnd, fogMax, 0, 0,
		sr, sg, sb, 0,
		invW, invH, flashInvW, flashInvH
	)
	MAT:SetMatrix("$viewprojmat", extra)

	render.OverrideDepthEnable(true, true)
	drawRange(MAT, 1, nworld, wallTex)
	drawRange(MAT, nworld + 1, nvis, NO_WALL)
	render.OverrideDepthEnable(false, false)

	if DEPTH_MAT and depthslices.BeginDepthWrite() then
		render.SetMaterial(DEPTH_MAT)
		for i = 1, nvis do
			visible[i]:Draw()
		end
		depthslices.EndDepthWrite()
	end
	cam.PopModelMatrix()
end

local winterRemoved = false

local function stop()
	running = false
	releaseTodSnow()
	hook.Remove("PostDrawOpaqueRenderables", "borealis_snow")
	trails.Stop()
	grid:Stop()
	geometry.Clear()
end

grid = chunks.Grid({
	name = "snow", size = CHUNK, cacheLimit = MESH_CACHE_TRIS,
	load = load, build = buildChunk, destroy = destroyChunk, failed = stop,
})
footsteps.SetGrid(grid)

if PRELOAD then
	download.OnLoaded(function(list)
		grid:Preload(list)
	end)
end

function snow.SetDistance(radius)
	radius = math.Clamp(radius, 1024, chunks.MAX_DISTANCE)
	grid.radius = radius
	fadeStart, fadeEnd = radius * 0.75, radius * 0.95
end

snow.SetDistance(DISTANCE:GetInt())

local function start()
	stop()
	if winterRemoved or shaderpack.Season() ~= "winter" then return end
	if not dynamiclights.Texture() then return end

	materialSerial = materialSerial + 1
	local suffix = os.time() .. "_" .. materialSerial
	if not trails.Start() then return end

	MAT = CreateShaderMaterial("borealis_snow_" .. suffix, {
		["$pixshader"] = snow.PS,
		["$vertexshader"] = snow.VS,
		["$texture1"] = snow.NOISE,
		["$linearread_basetexture"] = 1,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
		["$linearread_texture4"] = 1,
		["$linearwrite"] = 0,
		["$alpha_blend"] = 0,
		["$additive"] = 0,
		["$ignorez"] = 0,
		["$depthtest"] = 1,
		["$nocull"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	}, "screenspace_general_8tex")
	DEPTH_MAT = CreateShaderMaterial("borealis_snow_depth_" .. suffix, {
		["$pixshader"] = snow.DEPTH_PS,
		["$vertexshader"] = snow.VS,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
	})
	flashlight.Start(suffix)

	grid:Start()
	running = true
	hook.Add("PostDrawOpaqueRenderables", "borealis_snow", draw)
end

local apply = shaderpack.Toggle("borealis_snow", ENABLED, snow.SHADERS, start, stop, { snow.NOISE })
shaderpack.AfterWorld("borealis_snow", apply)

cvars.RemoveChangeCallback("borealis_snow_distance", "borealis_snow")
cvars.AddChangeCallback("borealis_snow_distance", function()
	snow.SetDistance(DISTANCE:GetInt())
end, "borealis_snow")

hook.Add("TOD_WinterRemoved", "borealis_snow", function()
	winterRemoved = true
	stop()
end)
