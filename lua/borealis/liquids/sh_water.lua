local NOISE = "shaderpack/procsky/fognoise"

if SERVER then
	shaderpack.AddResources({ "borealis_water_vs30", "borealis_water_ps30", "borealis_underwater_ps30", "borealis_water_skyfill_ps30", "borealis_water_sun_ps30", "borealis_waterdepth_ps30", "borealis_wakesim_ps30" }, { NOISE })

	return
end

local surfacewater = shaderpack.surfacewater or {}
shaderpack.surfacewater = surfacewater
surfacewater.above = surfacewater.above or {}
local procsky, bspdata, depthslices, cover = shaderpack.procsky, bspdata, shaderpack.depthslices, shaderpack.cover

require("skyboxer")

local MURK_REF_FOG_END, MURK_MIN, MURK_MAX = 1000, 0.25, 4

local WATER_ENABLED = CreateClientConVar("borealis_water", "1", true, false, "draw the custom water surface and underwater effects")


local function bodyKey(name)
	name = name:lower():gsub("^maps/[^/]+/", "")

	return (name:gsub("_%-?%d+_%-?%d+_%-?%d+$", ""))
end

local SUN_DEFAULT_MATERIAL = "sprites/light_glow02_add_noz"
local function readSunMaterials()
	local f, lump = bspdata.OpenLumps()
	if not f then return {} end

	local entities = lump(0)
	f:Close()

	local names = {}
	for block in entities:gmatch("%b{}") do
		local kv = {}
		for k, v in block:gmatch("\"([^\"]+)\"%s+\"([^\"]*)\"") do
			kv[k:lower()] = v
		end

		if kv.classname == "env_sun" then
			for _, key in ipairs({"material", "overlaymaterial"}) do
				local name = (kv[key] and kv[key] ~= "" and kv[key] or SUN_DEFAULT_MATERIAL):lower():gsub("%.vmt$", "")
				names[name] = true
			end
		end
	end

	local mats = {}
	for name in pairs(names) do
		mats[#mats + 1] = Material(name)
	end

	return mats
end

local function readSurfaceWaterBrushes()
	local vis = bspdata.LoadVis()
	local function visibleClusters(pos)
		if not vis then return end

		return bspdata.PVS(bspdata.ClusterAt(pos.x, pos.y, pos.z))
	end

	local ice = shaderpack.ice
	local winter = ice and ice.Winter()
	local skyboxPVS = vis and shaderpack.skybox3d and shaderpack.skybox3d.Camera() and bspdata.SkyboxPVS()
	local groups = {}
	for _, face in ipairs(bspdata.WaterFaces(true)) do
		local name = face.name
		local frozen = winter and ice.FaceFreezes(face) or false
		local sky = false
		if skyboxPVS and face.model == 0 then
			for cluster in pairs(face.clusters) do
				if skyboxPVS[cluster] then
					sky = true
					break
				end
			end
		end

		local key = string.format("%s|%.5f|%.5f|%.5f|%.5f|%d|%s|%s", bodyKey(name), face.su, face.ou, face.sv, face.ov, math.Round(face.dist), tostring(frozen), tostring(sky))
		local g = groups[key]
		if not g then
			g = { body = bodyKey(name), materials = {name}, model = face.model, su = face.su, ou = face.ou, sv = face.sv, ov = face.ov, verts = {}, clusters = {}, frozen = frozen, sky = sky }
			groups[key] = g
		else
			g.materials[#g.materials + 1] = name
		end

		for cluster in pairs(face.clusters) do
			g.clusters[cluster] = true
		end

		local poly, t = face.poly, g.verts
		for n = 2, #poly - 1 do
			t[#t + 1] = poly[1]
			t[#t + 1] = poly[n]
			t[#t + 1] = poly[n + 1]
		end
	end

	return groups, visibleClusters
end

local function getWaterBrushEntity(mi)
	if mi == 0 then return end

	local want = "*" .. mi
	for _, e in ents.Iterator() do
		if e:GetModel() == want then return e end
	end
end

surfacewater.originals = surfacewater.originals or {}

local function rememberOriginal(mat)
	local name = mat:GetName()
	local original = surfacewater.originals[name]
	if not original then
		original = {
			forcecheap = mat:GetInt("$forcecheap") or 0,
			forceexpensive = mat:GetInt("$forceexpensive") or 0,
			fogend = mat:GetFloat("$fogend"),
			alpha = mat:GetFloat("$alpha") or 1,
			flags = mat:GetInt("$flags") or 0,
			underwateroverlay = mat:GetString("$underwateroverlay"),
		}
		surfacewater.originals[name] = original
	end

	local fogEnd = original.fogend
	return fogEnd and fogEnd > 0 and fogEnd < 1e5 and fogEnd or nil
end

local function restoreWaterMaterials()
	for name, original in pairs(surfacewater.originals) do
		local mat = Material(name)
		mat:SetInt("$forcecheap", original.forcecheap)
		mat:SetInt("$forceexpensive", original.forceexpensive)
		if original.fogend then mat:SetFloat("$fogend", original.fogend) end
		mat:SetFloat("$alpha", original.alpha)
		mat:SetInt("$flags", original.flags)
		if original.underwateroverlay then mat:SetString("$underwateroverlay", original.underwateroverlay) end
	end
end

local MATERIAL_VAR_TRANSLUCENT = 2097152
local function prepareWaterBodyMaterials(matNames)
	local fogEnd
	for _, surfaceMatName in ipairs(matNames) do
		local surfaceMat = Material(surfaceMatName)
		fogEnd = fogEnd or rememberOriginal(surfaceMat)
		surfaceMat:SetInt("$forcecheap", 1)
		surfaceMat:SetInt("$forceexpensive", 0)

		surfaceMat:SetInt("$fogend", 1e6)
		surfaceMat:SetFloat("$alpha", 0.99)
		surfaceMat:SetInt("$flags", bit.bor(surfaceMat:GetInt("$flags"), 4, MATERIAL_VAR_TRANSLUCENT))

		local underWaterMatName = surfaceMat:GetString("$bottommaterial")
		if not underWaterMatName or underWaterMatName == "" then continue end

		local underWaterMat = Material(underWaterMatName)
		local bottomFogEnd = rememberOriginal(underWaterMat)
		fogEnd = fogEnd or bottomFogEnd
		underWaterMat:SetInt("$fogend", 1e6)
		underWaterMat:SetString("$underwateroverlay", "")

		underWaterMat:SetInt("$forcecheap", 1)
		underWaterMat:SetInt("$forceexpensive", 0)

		underWaterMat:SetFloat("$alpha", 0.99)
		underWaterMat:SetInt("$flags", bit.bor(underWaterMat:GetInt("$flags"), 4, MATERIAL_VAR_TRANSLUCENT))
	end

	return fogEnd
end

local SURF_MAT, DEPTH_MAT
local meshes = {}
local visibleClusters = function() end

local function removeMeshes()
	for k, m in pairs(meshes) do
		if m.mesh then m.mesh:Destroy() end
		meshes[k] = nil
	end
end

local OPENNESS_GRID = 6
local OPENNESS_HEIGHT = 4
local OPENNESS_LENGTH = 32768
local opennessTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = {} }

local function bodyOpenness(g)
	local start, endpos = opennessTrace.start, opennessTrace.endpos
	local open, total = 0, 0
	for x = 0, OPENNESS_GRID - 1 do
		for y = 0, OPENNESS_GRID - 1 do
			start:SetUnpacked(
				g.minX + (x + 0.5) / OPENNESS_GRID * (g.maxX - g.minX),
				g.minY + (y + 0.5) / OPENNESS_GRID * (g.maxY - g.minY),
				g.surfaceZ + OPENNESS_HEIGHT
			)
			endpos:Set(start)
			endpos.z = endpos.z + OPENNESS_LENGTH
			local tr = util.TraceLine(opennessTrace)
			if not tr.StartSolid then
				total = total + 1
				if not tr.Hit or tr.HitSky then open = open + 1 end
			end
		end
	end

	return total > 0 and open / total or 1
end

local LIGHT_SAMPLES, LIGHT_LIFT = 16, 4
local LIGHT_UP = Vector(0, 0, 1)
local lightPos = Vector()

local function bodyLight(g, ent)
	local verts = g.verts
	local tris = #verts / 3
	local stride = math.max(1, math.floor(tris / LIGHT_SAMPLES))
	local r, gr, b, n = 0, 0, 0, 0
	for t = 0, tris - 1, stride do
		local a, bv, c = verts[t * 3 + 1], verts[t * 3 + 2], verts[t * 3 + 3]
		lightPos:SetUnpacked((a.x + bv.x + c.x) / 3, (a.y + bv.y + c.y) / 3, (a.z + bv.z + c.z) / 3 + LIGHT_LIFT)
		if ent then lightPos:Set(ent:LocalToWorld(lightPos)) end
		if bit.band(util.PointContents(lightPos), CONTENTS_SOLID) == 0 then
			local l, d = render.ComputeLighting(lightPos, LIGHT_UP), render.ComputeDynamicLighting(lightPos, LIGHT_UP)
			r, gr, b, n = r + l.x - d.x, gr + l.y - d.y, b + l.z - d.z, n + 1
		end
	end
	if n == 0 then return { 0, 0, 0 } end

	return {
		math.Clamp(math.floor(r / n * 127.5), 0, 255),
		math.Clamp(math.floor(gr / n * 127.5), 0, 255),
		math.Clamp(math.floor(b / n * 127.5), 0, 255),
	}
end

local function writeBodyMesh(g, ent)
	if g.mesh then g.mesh:Destroy() end

	local msh = Mesh(SURF_MAT)
	mesh.Begin(msh, MATERIAL_TRIANGLES, #g.verts / 3)
	local murkByte = math.floor(g.murk / MURK_MAX * 255 + 0.5)
	local minX, minY, maxX, maxY, maxZ = math.huge, math.huge, -math.huge, -math.huge, -math.huge
	local lights = g.lights
	local flat = not lights and bodyLight(g, ent)
	local skybox3d = g.sky and shaderpack.skybox3d
	for i, v in ipairs(g.verts) do
		if ent then v = ent:LocalToWorld(v) end
		local light = flat or lights[i]
		mesh.Position(skybox3d and skybox3d.ToWorldVector(v) or v)
		mesh.TexCoord(0, 0, 0)
		mesh.Color(murkByte, light[1], light[2], light[3])
		mesh.AdvanceVertex()
		minX, minY = math.min(minX, v.x), math.min(minY, v.y)
		maxX, maxY, maxZ = math.max(maxX, v.x), math.max(maxY, v.y), math.max(maxZ, v.z)
	end

	mesh.End()
	g.mesh = msh
	g.minX, g.minY, g.maxX, g.maxY, g.surfaceZ = minX, minY, maxX, maxY, maxZ
	g.center = nil
	g.openness = bodyOpenness(g)
end

local WATER_SURFACEPROPS = { water = true, slime = true, wade = true }

local function isWaterMaterial(name)
	local prop = Material(name):GetString("$surfaceprop")

	return not prop or WATER_SURFACEPROPS[prop:lower()] == true
end

local function buildMeshes()
	removeMeshes()

	if not SURF_MAT then return end

	local groups, visibility = readSurfaceWaterBrushes()
	visibleClusters = visibility or function() end

	for key, g in pairs(groups) do
		if #g.verts >= 3 then
			local nonWater = not isWaterMaterial(g.materials[1])
			local fogEnd = not nonWater and prepareWaterBodyMaterials(g.materials) or nil
			local normalmap = Material(g.materials[1]):GetString("$normalmap") or "dev/water_normal"
			local murk = fogEnd and math.Clamp(MURK_REF_FOG_END / fogEnd, MURK_MIN, MURK_MAX) or 1

			local body = {
				verts = g.verts, model = g.model, normalmap = normalmap, body = g.body, su = g.su, ou = g.ou, sv = g.sv, ov = g.ov,
				murk = math.floor(murk / MURK_MAX * 255 + 0.5) / 255 * MURK_MAX, clusters = g.clusters, nonWater = nonWater,
				frozen = g.frozen, sky = g.sky,
			}
			if g.frozen then body.verts, body.lights = shaderpack.ice.Bake(g.verts) end
			if g.model == 0 then writeBodyMesh(body) end
			meshes[key] = body
		end
	end
end

local ENTITY_LOOKUP_INTERVAL = 1

local function updateEntityBodies()
	local now = RealTime()
	for _, g in pairs(meshes) do
		if g.model == 0 then continue end

		if not IsValid(g.ent) and (not g.lookupAt or now - g.lookupAt > ENTITY_LOOKUP_INTERVAL) then
			g.lookupAt = now
			g.ent = getWaterBrushEntity(g.model)
		end

		local ent = g.ent
		g.hidden = not IsValid(ent) or ent:IsDormant()
		if g.hidden then continue end

		local pos, ang = ent:GetPos(), ent:GetAngles()
		if not g.mesh or pos ~= g.pos or ang ~= g.ang then
			g.pos, g.ang = pos, ang
			writeBodyMesh(g, ent)
		end
	end
end

local function bodyDrawable(g, pvs, skyVisible)
	if not g.mesh or g.hidden or g.nonWater then return false end
	if g.sky then return skyVisible end
	if g.model ~= 0 or not pvs then return true end

	for cluster in pairs(g.clusters) do
		if pvs[cluster] then return true end
	end

	return false
end

local UNDER_MAT
local SKY_MAT
local SUN_MAT

local SHADERS = { "borealis_water_vs30", "borealis_water_ps30", "borealis_underwater_ps30", "borealis_water_skyfill_ps30", "borealis_water_sun_ps30", "borealis_wakesim_ps30" }
local materialSerial = 0

local function initialize()
	materialSerial = materialSerial + 1
	local suffix = os.time() .. "_" .. materialSerial
	local px, vs = "borealis_water_ps30", "borealis_water_vs30"
	UNDER_MAT = CreateShaderMaterial("water_underwater_" .. suffix, {
		["$pixshader"] = "borealis_underwater_ps30",
		["$vertexshader"] = vs,
		["$alpha_blend"] = 0,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$texture3"] = NOISE,
		["$linearread_texture3"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})

	SKY_MAT = CreateShaderMaterial("water_skyfill_" .. suffix, {
		["$pixshader"] = "borealis_water_skyfill_ps30",
		["$vertexshader"] = vs,
		["$alpha_blend"] = 0,
		["$ignorez"] = 0,
	})

	SUN_MAT = CreateShaderMaterial("water_sun_" .. suffix, {
		["$pixshader"] = "borealis_water_sun_ps30",
		["$vertexshader"] = vs,
		["$texture1"] = NOISE,
		["$linearread_texture1"] = 1,
		["$alpha_blend"] = 0,
		["$additive"] = 1,
		["$ignorez"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 1, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
	})

	SURF_MAT = CreateShaderMaterial("water_surface_" .. suffix, {
		["$pixshader"] = px,
		["$vertexshader"] = vs,
		["$alpha_blend"] = 0,
		["$writealpha"] = 1,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$texture3"] = NOISE,
		["$linearread_texture3"] = 1,
		["$linearread_texture4"] = 1,
		["$linearread_texture5"] = 1,
		["$linearread_texture6"] = 1,
		["$linearread_texture7"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	}, "screenspace_general_8tex")

	DEPTH_MAT = shaderpack.Available({ "borealis_waterdepth_ps30" }) and CreateShaderMaterial("water_depth_" .. suffix, {
		["$pixshader"] = "borealis_waterdepth_ps30",
		["$vertexshader"] = vs,
		["$alpha_blend"] = 0,
	}) or nil

	buildMeshes()
end

local toLinear, sunDir, setConstant, packColor = shaderpack.ToLinear, shaderpack.SunDir, shaderpack.SetConstant, shaderpack.PackColor

local SUN_TRACE_LENGTH = 32768
local SUN_TRACE_HEIGHT = 4
local SUN_TRACE_INTERVAL = 0.25
local sunTrace = { mask = MASK_SOLID_BRUSHONLY, output = {} }
local sunTraceEnd = Vector()
local eyeSurfacePoint = Vector()

local function sunReaches(pos, sun)
	sunTraceEnd:Set(sun)
	sunTraceEnd:Mul(SUN_TRACE_LENGTH)
	sunTraceEnd:Add(pos)
	sunTrace.start = pos
	sunTrace.endpos = sunTraceEnd
	local tr = util.TraceLine(sunTrace)

	return (not tr.Hit or tr.HitSky) and 1 or 0
end

local function bodySunlit(g, sun)
	local now = RealTime()
	if not g.sunlitAt or now - g.sunlitAt > SUN_TRACE_INTERVAL then
		g.sunlitAt = now
		g.center = g.center or Vector((g.minX + g.maxX) * 0.5, (g.minY + g.maxY) * 0.5, g.surfaceZ + SUN_TRACE_HEIGHT)
		g.sunlit = sunReaches(g.center, sun)
	end

	return g.sunlit
end

local AMBIENT_REFLECTANCE = 0.25
local ICE_AMBIENT_FILL = 0.5

local function bodyAmbient(g)
	local now = RealTime()
	if not g.ambientAt or now - g.ambientAt > SUN_TRACE_INTERVAL then
		g.ambientAt = now
		g.center = g.center or Vector((g.minX + g.maxX) * 0.5, (g.minY + g.maxY) * 0.5, g.surfaceZ + SUN_TRACE_HEIGHT)
		g.ambient = render.GetLightColor(g.center) * AMBIENT_REFLECTANCE
	end

	return g.ambient
end

local IDENTITY_MATRIX = Matrix()

local MATERIAL_VAR_NO_DRAW = 4
local sunMaterials = readSunMaterials()
local sunHidden

local function hideSun(hide)
	if hide == sunHidden then return end
	sunHidden = hide

	for _, m in ipairs(sunMaterials) do
		local flags = m:GetInt("$flags")
		m:SetInt("$flags", hide and bit.bor(flags, MATERIAL_VAR_NO_DRAW) or bit.band(flags, bit.bnot(MATERIAL_VAR_NO_DRAW)))
	end
end

hideSun(false)

local function isUnderwater(pos)
	return bit.band(util.PointContents(pos), CONTENTS_WATER) ~= 0
end

local SURFACE_SEARCH_MAX = 16384
local surfacePos = Vector()

local function waterSurfaceZ(pos)
	surfacePos:Set(pos)
	local lo, step = pos.z, 64
	local hi = lo + step
	surfacePos.z = hi
	while isUnderwater(surfacePos) do
		if hi - pos.z > SURFACE_SEARCH_MAX then return hi end
		lo, step = hi, step * 2
		hi = lo + step
		surfacePos.z = hi
	end

	for _ = 1, 12 do
		local mid = (lo + hi) * 0.5
		surfacePos.z = mid
		if isUnderwater(surfacePos) then lo = mid else hi = mid end
	end

	return (lo + hi) * 0.5
end

surfacewater.IsUnderwater = isUnderwater
surfacewater.SurfaceZ = waterSurfaceZ

local function skyColors()
	local tonemap = shaderpack.ToneMapScale()
	if procsky and procsky.GetSkyColors then
		local h, z = procsky.GetSkyColors()
		return h[1] * tonemap, h[2] * tonemap, h[3] * tonemap, z[1] * tonemap, z[2] * tonemap, z[3] * tonemap
	end

	local fr, fg, fb = render.GetFogColor()
	fr, fg, fb = toLinear(fr) * tonemap, toLinear(fg) * tonemap, toLinear(fb) * tonemap

	return fr, fg, fb, fr, fg, fb
end

local function bodySkyColors(g)
	local hr, hg, hb, zr, zg, zb = skyColors()
	if not g then return hr, hg, hb, zr, zg, zb end

	local open = g.openness
	if open >= 1 then return hr, hg, hb, zr, zg, zb end

	local tonemap = shaderpack.ToneMapScale()
	local amb = bodyAmbient(g)
	local ar, ag, ab = amb.x * tonemap, amb.y * tonemap, amb.z * tonemap

	return Lerp(open, ar, hr), Lerp(open, ag, hg), Lerp(open, ab, hb), Lerp(open, ar, zr), Lerp(open, ag, zg), Lerp(open, ab, zb)
end

local depthWanted = true
local rainConstants = Matrix()

local function drawSurface(eyePos, eyeUnderwater, writeDepth)
	local pvs = visibleClusters(eyePos)
	local skybox3d = shaderpack.skybox3d
	local skyVisible = not eyeUnderwater and skybox3d ~= nil and skybox3d.Visible(eyePos)
	local anyDrawable = false
	for _, g in pairs(meshes) do
		if bodyDrawable(g, pvs, skyVisible) then
			anyDrawable = true
			break
		end
	end
	if not anyDrawable then return false end

	if not eyeUnderwater then depthslices.Capture() end
	render.UpdateScreenEffectTexture()
	SURF_MAT:SetTexture("$basetexture", render.GetScreenEffectTexture())
	SURF_MAT:SetTexture("$texture1", render.GetResolvedFullFrameDepth())
	SURF_MAT:SetFloat("$c0_x", CurTime() % 3600)
	setConstant(SURF_MAT, "$c1", eyePos.x, eyePos.y, eyePos.z)

	local sun = sunDir()
	local lut = procsky and procsky.GetLut and procsky.GetLut()
	local lutWeight = 0
	if lut then
		SURF_MAT:SetTexture("$texture4", lut)
		lutWeight = 1 - shaderpack.Overcast()
	end
	setConstant(SURF_MAT, "$c3", sun.x, sun.y, sun.z, lut and procsky.GetSkyScale() * shaderpack.ToneMapScale() or 0)

	local coverRT = cover.Texture()
	local rain = coverRT and tod and tod.rain and tod.rain.amount or 0
	if coverRT then SURF_MAT:SetTexture("$texture5", coverRT) end
	local fog = shaderpack.fog
	local fogDensity, fogFalloff, fogBase = 0, 1, 0
	if fog and fog.Layer then fogDensity, fogFalloff, fogBase = fog.Layer() end

	local bakedSun = bspdata.BakedSun()
	local foliage = shaderpack.foliage
	local lightScale = foliage and foliage.WorldLightScale() or 1
	local amb = render.GetAmbientLightColor()
	local fill = packColor(amb.x * ICE_AMBIENT_FILL, amb.y * ICE_AMBIENT_FILL, amb.z * ICE_AMBIENT_FILL)
	local tonemap = shaderpack.ToneMapScale()
	local wallTex = shaderpack.skywall.Texture()
	local invW, invH = shaderpack.skywall.InvSize()
	local waveRT, waveX, waveY = shaderpack.wakes.Texture()
	SURF_MAT:SetTexture("$texture7", waveRT or "vgui/black")
	waveX, waveY = waveX or -1e7, waveY or -1e7

	render.OverrideDepthEnable(true, writeDepth)
	cam.PushModelMatrix(IDENTITY_MATRIX, false)
	for _, g in pairs(meshes) do
		if not bodyDrawable(g, pvs, skyVisible) then continue end

		rainConstants:SetUnpacked(rain, g.openness, fogDensity, fogFalloff, fogBase, g.frozen and 1 or 0, invW, invH, bakedSun.x, bakedSun.y, bakedSun.z, lightScale, fill, tonemap, waveX, waveY)
		SURF_MAT:SetMatrix("$viewprojmat", rainConstants)
		SURF_MAT:SetTexture("$texture2", g.normalmap)
		SURF_MAT:SetTexture("$texture6", g.sky and "vgui/black" or wallTex)
		local hr, hg, hb, zr, zg, zb = bodySkyColors(g)
		setConstant(SURF_MAT, "$c2", hr, hg, hb, bodySunlit(g, sun))
		setConstant(SURF_MAT, "$c0", nil, zr, zg, zb)
		SURF_MAT:SetFloat("$c1_w", lutWeight * g.openness)
		render.SetMaterial(SURF_MAT)
		g.mesh:Draw()
	end
	render.OverrideDepthEnable(false, false)

	if writeDepth and DEPTH_MAT and depthslices.BeginDepthWrite() then
		render.SetMaterial(DEPTH_MAT)
		for _, g in pairs(meshes) do
			if bodyDrawable(g, pvs, skyVisible) then g.mesh:Draw() end
		end
		depthslices.EndDepthWrite()
	end
	cam.PopModelMatrix()

	return true
end

local QUAD_NEAR = 12
local QUAD_OVERSIZE = 4
local QUAD_COLOR = Color(255, 255, 255, 255)

local function drawScreenQuad(mat, eyePos, distance)
	local fwd = EyeAngles():Forward()
	local halfW, halfH, vs = shaderpack.ViewTan()
	distance = distance or math.max(QUAD_NEAR, vs.znear * 1.5)
	local size = distance * QUAD_OVERSIZE
	render.SetMaterial(mat)
	cam.PushModelMatrix(IDENTITY_MATRIX, false)
	render.DrawQuadEasy(eyePos + fwd * distance, -fwd, halfW * size, halfH * size, QUAD_COLOR, 0)
	cam.PopModelMatrix()
end

local SKY_FILL_FAR = 0.98
local SUN_FAR = 0.97

local usableRT = shaderpack.UsableRT

local function targetsReady()
	return usableRT(render.GetScreenEffectTexture()) and usableRT(render.GetResolvedFullFrameDepth())
end

local skyTarget
local function renderSkyTarget()
	local w, h = ScrW(), ScrH()
	if not usableRT(skyTarget, w, h) then
		skyTarget = GetRenderTarget("borealis_water_sky_" .. w .. "x" .. h, w, h)
		if not usableRT(skyTarget, w, h) then return end
	end

	render.PushRenderTarget(skyTarget)
	render.Clear(0, 0, 0, 255, false, false)
	render.OverrideDepthEnable(true, false)
	local hooks = skyboxer.hooks or {}
	for n = 1, #hooks do
		ProtectedCall(hooks[n][1])
	end
	render.OverrideDepthEnable(false, false)
	render.PopRenderTarget()

	return skyTarget
end

local function fillSky(eyePos)
	local sky = renderSkyTarget()
	if not sky then return end

	SKY_MAT:SetTexture("$basetexture", sky)
	local far = (render.GetViewSetup().zfar or 30000) * SKY_FILL_FAR
	render.OverrideDepthEnable(true, true)
	drawScreenQuad(SKY_MAT, eyePos, far)
	render.OverrideDepthEnable(false, false)
end

local function bodyAt(pos, surfaceZ)
	local best, bestGap = nil, math.huge
	for _, g in pairs(meshes) do
		if g.mesh and not g.hidden and not g.sky and pos.x >= g.minX and pos.x <= g.maxX and pos.y >= g.minY and pos.y <= g.maxY then
			local gap = math.abs(g.surfaceZ - surfaceZ)
			if gap < bestGap then best, bestGap = g, gap end
		end
	end

	return best
end

function surfacewater.CausticSource(pos, surfaceZ)
	local body = bodyAt(pos, surfaceZ)
	if not body or body.nonWater then return nil end

	local sun = sunDir()

	return body.normalmap, sun, bodySunlit(body, sun)
end

local function inNonWaterLiquid(pos)
	local body = bodyAt(pos, waterSurfaceZ(pos))

	return body ~= nil and body.nonWater
end

local function drawOpaque(bDepth, bSkybox, bSkybox3D)
	if not SURF_MAT then return end
	if bDepth or bSkybox3D then return end
	if render.GetRenderTarget() ~= nil then return end
	if not targetsReady() then return end

	updateEntityBodies()

	local eyePos = EyePos()
	local eyeUnderwater = isUnderwater(eyePos)
	if eyeUnderwater and inNonWaterLiquid(eyePos) then
		hideSun(false)
		depthWanted = false
		return
	end

	hideSun(eyeUnderwater)
	if eyeUnderwater then
		fillSky(eyePos)
		depthWanted = true
	end
end

local SURFACE_ORDER = 1

local function drawSurfaceAbove()
	if not SURF_MAT then return end
	if not targetsReady() then return end

	local eyePos = EyePos()
	if isUnderwater(eyePos) then return end

	depthWanted = drawSurface(eyePos, false, true)
end

local WATERLINE_BAND = 16
local waterlinePos = Vector()

local function drawTranslucent(bDepth, bSkybox, bSkybox3D)
	if not UNDER_MAT then return end
	if bDepth or bSkybox3D or bSkybox then return end
	if render.GetRenderTarget() ~= nil then return end
	if not targetsReady() then return end

	local eyePos = EyePos()
	local eyeUnderwater = isUnderwater(eyePos)
	local waterPos = eyePos
	if not eyeUnderwater then
		waterlinePos:Set(eyePos)
		waterlinePos.z = waterlinePos.z - WATERLINE_BAND
		if not isUnderwater(waterlinePos) then return end
		waterPos = waterlinePos
	end

	local surfaceZ = waterSurfaceZ(waterPos)
	local body = bodyAt(waterPos, surfaceZ)
	if body and body.nonWater then return end

	depthWanted = true
	depthslices.SkipRefog()

	if eyeUnderwater then
		for _, drawAbove in pairs(surfacewater.above) do
			ProtectedCall(drawAbove)
		end

		drawSurface(eyePos, true, false)
	end

	depthslices.Invalidate()
	depthslices.Capture()
	render.UpdateScreenEffectTexture()
	UNDER_MAT:SetTexture("$basetexture", render.GetScreenEffectTexture())
	UNDER_MAT:SetTexture("$texture1", render.GetResolvedFullFrameDepth())

	local fwd = EyeAngles():Forward()
	UNDER_MAT:SetTexture("$texture2", body and body.normalmap or "dev/water_normal")
	setConstant(UNDER_MAT, "$c0", eyePos.x, eyePos.y, eyePos.z, surfaceZ)
	setConstant(UNDER_MAT, "$c1", fwd.x, fwd.y, fwd.z, CurTime() % 3600)

	local _, _, _, zr, zg, zb = bodySkyColors(body)
	setConstant(UNDER_MAT, "$c2", zr, zg, zb, body and body.murk or 1)

	local sun = sunDir()
	eyeSurfacePoint:SetUnpacked(eyePos.x, eyePos.y, surfaceZ + SUN_TRACE_HEIGHT)
	local sunlit = sunReaches(eyeSurfacePoint, sun)
	setConstant(UNDER_MAT, "$c3", sun.x, sun.y, sun.z, sunlit)

	drawScreenQuad(UNDER_MAT, eyePos)

	if not eyeUnderwater then return end

	SUN_MAT:SetTexture("$basetexture", body and body.normalmap or "dev/water_normal")
	setConstant(SUN_MAT, "$c0", eyePos.x, eyePos.y, eyePos.z, surfaceZ)
	setConstant(SUN_MAT, "$c1", sun.x, sun.y, sun.z, CurTime() % 3600)
	setConstant(SUN_MAT, "$c2", body and body.murk or 1, sunlit)
	render.OverrideDepthEnable(true, true)
	drawScreenQuad(SUN_MAT, eyePos, (render.GetViewSetup().zfar or 30000) * SUN_FAR)
	render.OverrideDepthEnable(false, false)
end

local startRainSound, stopRainSound
do
	local COLUMN = cover.COLUMN
	local COVERED = cover.Z_MIN + cover.Z_RANGE
	local BELOW_SURFACE = 2
	local NEAR_WATER, NEAR_WATER_Z = 900, 600
	local UPDATE_INTERVAL = 0.25
	local SCAN_PER_FRAME = 512
	local PRUNE_RANGE = 1200

	local RAIN_SOUNDS = { "ambient/weather/rumble_rain_nowind.wav", "ambient/weather/crucial_rumble_rain_nowind.wav" }
	local RAIN_PITCHES = { 100, 93 }
	local RAIN_LEVEL, RAIN_GAIN, RAIN_FADE = 80, 2.5, 0.5
	local RAIN_REACH, RAIN_RANGE, RAIN_FULL = 400, 900, 60
	local RAIN_LIFT = 8
	local SOUND_MODEL = "models/props_junk/popcan01a.mdl"

	local columnKey, columnFromKey = cover.ColumnKey, cover.ColumnFromKey
	local samplePos = Vector()

	local water = {}
	local scanList, scanAt
	local near = false
	local nextUpdate = 0
	local rainEnt, rainPatches = nil, {}
	local function soundVolume()
		local precipitations = shaderpack.precipitations

		return precipitations and precipitations.RainVolume() or 0
	end

	local function nearWater(eye)
		for _, g in pairs(meshes) do
			if g.mesh and not g.sky and not g.nonWater and not g.frozen
				and eye.x > g.minX - NEAR_WATER and eye.x < g.maxX + NEAR_WATER
				and eye.y > g.minY - NEAR_WATER and eye.y < g.maxY + NEAR_WATER
				and math.abs(eye.z - g.surfaceZ) < NEAR_WATER_Z then
				return true
			end
		end

		return false
	end

	local function checkColumn(cx, cy)
		local key = columnKey(cx, cy)
		local x, y = (cx + 0.5) * COLUMN, (cy + 0.5) * COLUMN
		local z = cover.HeightAt(x, y)
		water[key] = nil
		if not z or z >= COVERED then return end

		samplePos:SetUnpacked(x, y, z - BELOW_SURFACE)
		local contents = util.PointContents(samplePos)
		if bit.band(contents, CONTENTS_WATER) ~= 0 and bit.band(contents, CONTENTS_SLIME) == 0 then
			water[key] = z
		end
	end

	local function onColumn(cx, cy, coverChanged)
		if coverChanged and near then checkColumn(cx, cy) end
	end

	local function reset()
		water = {}
		scanList, scanAt = nil, nil
	end

	local function scanStep()
		if not scanList then
			local winX, winY = cover.Window()
			if not winX then return end

			scanList, scanAt = {}, 1
			for cx = winX, winX + cover.COLUMNS - 1 do
				for cy = winY, winY + cover.COLUMNS - 1 do
					scanList[#scanList + 1] = columnKey(cx, cy)
				end
			end
		end

		local last = math.min(scanAt + SCAN_PER_FRAME - 1, #scanList)
		for i = scanAt, last do
			checkColumn(columnFromKey(scanList[i]))
		end

		if last >= #scanList then
			scanList, scanAt = false, nil
		else
			scanAt = last + 1
		end
	end

	local function stopRain()
		for _, p in pairs(rainPatches) do
			p:Stop()
		end

		rainPatches = {}
	end

	local function setRain(volume, x, y, z)
		if volume <= 0.001 then return stopRain() end

		if not IsValid(rainEnt) then
			rainEnt = ClientsideModel(SOUND_MODEL)
			rainEnt:SetNoDraw(true)
			rainPatches = {}
		end

		samplePos:SetUnpacked(x, y, z + RAIN_LIFT)
		rainEnt:SetPos(samplePos)
		for i, path in ipairs(RAIN_SOUNDS) do
			local p = rainPatches[i]
			if not p then
				p = CreateSound(rainEnt, path)
				p:SetSoundLevel(RAIN_LEVEL)
				rainPatches[i] = p
			end

			if p:IsPlaying() then
				p:ChangeVolume(volume, RAIN_FADE)
			else
				p:PlayEx(volume, RAIN_PITCHES[i])
			end
		end
	end

	local function updateRainSound(eye)
		local rain = tod and tod.rain and tod.rain.amount or 0
		local rain2, prune2, reach2 = RAIN_RANGE * RAIN_RANGE, PRUNE_RANGE * PRUNE_RANGE, RAIN_REACH * RAIN_REACH
		local sum, nearest, nx, ny, nz = 0, rain2, 0, 0, 0
		for key, z in pairs(water) do
			local cx, cy = columnFromKey(key)
			local x, y = (cx + 0.5) * COLUMN, (cy + 0.5) * COLUMN
			local dx, dy, dz = x - eye.x, y - eye.y, z - eye.z
			local d2 = dx * dx + dy * dy + dz * dz
			if d2 > prune2 then
				water[key] = nil
			elseif rain > 0 and d2 < rain2 then
				sum = sum + 1 / (1 + d2 / reach2)
				if d2 < nearest then nearest, nx, ny, nz = d2, x, y, z end
			end
		end

		if sum > 0 then
			setRain(math.min(rain * soundVolume() * math.min(sum / RAIN_FULL, 1) * RAIN_GAIN, 1), nx, ny, nz)
		else
			stopRain()
		end
	end

	local function think()
		local now = RealTime()
		local eye = EyePos()
		local due = now >= nextUpdate
		if due then
			nextUpdate = now + UPDATE_INTERVAL

			local wasNear = near
			near = nearWater(eye) and not isUnderwater(eye)
			if not near then
				if wasNear then
					stopRain()
					reset()
				end
				return
			end
		end

		if not near or not cover.Update(eye) then return end

		if scanList ~= false then return scanStep() end
		if due then updateRainSound(eye) end
	end

	function stopRainSound()
		cover.Unlisten("borealis_water_rain")
		hook.Remove("Think", "borealis_water_rain")
		stopRain()
		if IsValid(rainEnt) then rainEnt:Remove() end
		rainEnt, near = nil, false
		reset()
	end

	function startRainSound()
		stopRainSound()
		cover.Listen("borealis_water_rain", onColumn, reset)
		hook.Add("Think", "borealis_water_rain", think)
	end
end

local function stop()
	surfacewater.active = nil
	stopRainSound()
	hook.Remove("PostDrawOpaqueRenderables", "borealis_water")
	hook.Remove("PostDrawTranslucentRenderables", "borealis_water_underwater")
	depthslices.RemoveEffect("borealis_water")
	shaderpack.wakes.Stop()
	hideSun(false)
	removeMeshes()
	restoreWaterMaterials()
end

local function start()
	stop()
	initialize()
	hook.Add("PostDrawOpaqueRenderables", "borealis_water", drawOpaque)
	hook.Add("PostDrawTranslucentRenderables", "borealis_water_underwater", drawTranslucent)
	depthWanted = true
	depthslices.AddEffect("borealis_water", SURFACE_ORDER, drawSurfaceAbove, false, function() return depthWanted end)
	startRainSound()
	shaderpack.wakes.Start()
	surfacewater.active = true
end

shaderpack.AfterWorld("borealis_water", shaderpack.Toggle("borealis_water", WATER_ENABLED, SHADERS, start, stop, { NOISE }))
