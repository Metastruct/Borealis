local NOISE = "shaderpack/procsky/fognoise"

if SERVER then
	shaderpack.AddResources({ "borealis_water_vs30", "borealis_water_ps30", "borealis_underwater_ps30", "borealis_water_skyfill_ps30", "borealis_water_sun_ps30", "borealis_waterdepth_ps30" }, { NOISE })

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
	local groups = {}
	for _, face in ipairs(bspdata.WaterFaces(true)) do
		local name = face.name
		local frozen = winter and ice.FaceFreezes(face) or false
		local key = string.format("%s|%.5f|%.5f|%.5f|%.5f|%d|%s", bodyKey(name), face.su, face.ou, face.sv, face.ov, math.Round(face.dist), tostring(frozen))
		local g = groups[key]
		if not g then
			g = { body = bodyKey(name), materials = {name}, model = face.model, su = face.su, ou = face.ou, sv = face.sv, ov = face.ov, verts = {}, clusters = {}, frozen = frozen }
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

local ICE_LIGHT_CELL, ICE_LIGHT_LIFT, ICE_MAX_VERTS = 256, 4, 65535
local ICE_LIGHT_INWARD = { 0, 0.1, 0.25, 0.5, 1 }
local UP = Vector(0, 0, 1)
local lightPos = Vector()
local NO_LIGHT = { 0, 0, 255 }

local function tessellationCount(verts, cell)
	local count = 0
	for i = 1, #verts, 3 do
		local a, b, c = verts[i], verts[i + 1], verts[i + 2]
		local n = math.max(1, math.ceil(math.max(a:Distance(b), b:Distance(c), c:Distance(a)) / cell))
		count = count + n * n * 3
	end

	return count
end

local function bakedLight(v, centre, cache)
	local key = math.Round(v.x) .. "," .. math.Round(v.y)
	local light = cache[key]
	if light then return light end

	for _, f in ipairs(ICE_LIGHT_INWARD) do
		lightPos:SetUnpacked(v.x + (centre.x - v.x) * f, v.y + (centre.y - v.y) * f, v.z + ICE_LIGHT_LIFT)
		if bit.band(util.PointContents(lightPos), CONTENTS_SOLID) == 0 then break end
	end

	local l, d = render.ComputeLighting(lightPos, UP), render.ComputeDynamicLighting(lightPos, UP)
	light = {
		math.Clamp(math.floor((l.x - d.x) * 127.5), 0, 255),
		math.Clamp(math.floor((l.y - d.y) * 127.5), 0, 255),
		math.Clamp(math.floor((l.z - d.z) * 127.5), 0, 255),
	}
	cache[key] = light

	return light
end

local function bakeIce(verts)
	local cell = ICE_LIGHT_CELL
	local count = tessellationCount(verts, cell)
	while count > math.max(ICE_MAX_VERTS, #verts) do
		cell = cell * math.sqrt(count / ICE_MAX_VERTS) * 1.05
		count = tessellationCount(verts, cell)
	end

	local out, lights, cache = {}, {}, {}
	for i = 1, #verts, 3 do
		local a, b, c = verts[i], verts[i + 1], verts[i + 2]
		local n = math.max(1, math.ceil(math.max(a:Distance(b), b:Distance(c), c:Distance(a)) / cell))
		local ab, ac = (b - a) / n, (c - a) / n
		local centre = (a + b + c) / 3
		local function add(u, w)
			local v = a + ab * u + ac * w
			out[#out + 1] = v
			lights[#lights + 1] = bakedLight(v, centre, cache)
		end

		for u = 0, n - 1 do
			for w = 0, n - 1 - u do
				add(u, w)
				add(u + 1, w)
				add(u, w + 1)
				if u + w < n - 1 then
					add(u + 1, w)
					add(u + 1, w + 1)
					add(u, w + 1)
				end
			end
		end
	end

	return out, lights
end

local function writeBodyMesh(g, ent)
	if g.mesh then g.mesh:Destroy() end

	local msh = Mesh(SURF_MAT)
	mesh.Begin(msh, MATERIAL_TRIANGLES, #g.verts / 3)
	local murkByte = math.floor(g.murk / MURK_MAX * 255 + 0.5)
	local minX, minY, maxX, maxY, maxZ = math.huge, math.huge, -math.huge, -math.huge, -math.huge
	local lights = g.lights
	for i, v in ipairs(g.verts) do
		if ent then v = ent:LocalToWorld(v) end
		local light = lights and lights[i] or NO_LIGHT
		mesh.Position(v)
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
				frozen = g.frozen,
			}
			if g.frozen then body.verts, body.lights = bakeIce(g.verts) end
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

local function bodyDrawable(g, pvs)
	if not g.mesh or g.hidden or g.nonWater then return false end
	if g.model ~= 0 or not pvs then return true end

	for cluster in pairs(g.clusters) do
		if pvs[cluster] then return true end
	end

	return false
end

local UNDER_MAT
local SKY_MAT
local SUN_MAT

local SHADERS = { "borealis_water_vs30", "borealis_water_ps30", "borealis_underwater_ps30", "borealis_water_skyfill_ps30", "borealis_water_sun_ps30" }
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
local ICE_FILL_K = 0.5

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

local function skyColors()
	local tonemap = render.GetToneMappingScaleLinear().x
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

	local tonemap = render.GetToneMappingScaleLinear().x
	local amb = bodyAmbient(g)
	local ar, ag, ab = amb.x * tonemap, amb.y * tonemap, amb.z * tonemap

	return Lerp(open, ar, hr), Lerp(open, ag, hg), Lerp(open, ab, hb), Lerp(open, ar, zr), Lerp(open, ag, zg), Lerp(open, ab, zb)
end

local depthWanted = true
local rainConstants = Matrix()

local function drawSurface(eyePos, eyeUnderwater, writeDepth)
	local pvs = visibleClusters(eyePos)
	local anyDrawable = false
	for _, g in pairs(meshes) do
		if bodyDrawable(g, pvs) then
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
	setConstant(SURF_MAT, "$c3", sun.x, sun.y, sun.z, lut and procsky.GetSkyScale() * render.GetToneMappingScaleLinear().x or 0)

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
	local fill = packColor(amb.x * ICE_FILL_K, amb.y * ICE_FILL_K, amb.z * ICE_FILL_K)
	local tonemap = render.GetToneMappingScaleLinear().x
	SURF_MAT:SetTexture("$texture6", shaderpack.skywall.Texture())
	local invW, invH = shaderpack.skywall.InvSize()

	render.OverrideDepthEnable(true, writeDepth)
	cam.PushModelMatrix(IDENTITY_MATRIX, false)
	for _, g in pairs(meshes) do
		if not bodyDrawable(g, pvs) then continue end

		rainConstants:SetUnpacked(rain, g.openness, fogDensity, fogFalloff, fogBase, g.frozen and 1 or 0, invW, invH, bakedSun.x, bakedSun.y, bakedSun.z, lightScale, fill, tonemap, 0, 0)
		SURF_MAT:SetMatrix("$viewprojmat", rainConstants)
		SURF_MAT:SetTexture("$texture2", g.normalmap)
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
			if bodyDrawable(g, pvs) then g.mesh:Draw() end
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
		if g.mesh and not g.hidden and pos.x >= g.minX and pos.x <= g.maxX and pos.y >= g.minY and pos.y <= g.maxY then
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

local function stop()
	hook.Remove("PostDrawOpaqueRenderables", "borealis_water")
	hook.Remove("PostDrawTranslucentRenderables", "borealis_water_underwater")
	depthslices.RemoveEffect("borealis_water")
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
end

shaderpack.AfterWorld("borealis_water", shaderpack.Toggle("borealis_water", WATER_ENABLED, SHADERS, start, stop, { NOISE }))
