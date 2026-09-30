local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

if SERVER then
	if not resource.AddShader then return end

	resource.AddShader("water_vs30")
	resource.AddShader("water_ps30")
	resource.AddShader("underwater_ps30")
	resource.AddShader("water_skyfill_ps30")
	resource.AddShader("water_sun_ps30")
	resource.AddFile("materials/procsky/fognoise.vtf")

	return
end

require("skyboxer")

local SURF_WARP = 0x8
local TOP_FACING = 0.99
local MURK_REF_FOG_END, MURK_MIN, MURK_MAX = 1000, 0.25, 4

local WATER_ENABLED = CreateClientConVar("cl_draw_water", "1", true, false, "draw the custom water surface and underwater effects")

local byte = string.byte

local function u16(b, p)
	local x, y = byte(b, p, p + 1)

	return y * 256 + x
end

local function i16(b, p)
	local v = u16(b, p)

	return v >= 32768 and v - 65536 or v
end

local function i32(b, p)
	local w, x, y, z = byte(b, p, p + 3)
	local v = ((z * 256 + y) * 256 + x) * 256 + w

	return v >= 2147483648 and v - 4294967296 or v
end

local function f32(b, p)
	local w, x, y, z = byte(b, p, p + 3)
	local sign = z >= 128 and -1 or 1
	local expo = (z % 128) * 2 + math.floor(y / 128)
	local mant = ((y % 128) * 256 + x) * 256 + w
	if expo == 0 then return sign * mant * 2 ^ -149 end
	if expo == 255 then return sign * math.huge end

	return sign * (1 + mant * 2 ^ -23) * 2 ^ (expo - 127)
end

local function bodyKey(name)
	name = name:lower():gsub("^maps/[^/]+/", "")

	return (name:gsub("_%-?%d+_%-?%d+_%-?%d+$", ""))
end

local SUN_DEFAULT_MATERIAL = "sprites/light_glow02_add_noz"
local function readSunMaterials()
	local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
	if not f then return {} end

	f:Seek(8)
	local ofs, len = f:ReadLong(), f:ReadLong()
	f:Seek(ofs)
	local entities = f:Read(len) or ""
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
	local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
	if not f then return {} end

	local function lump(n)
		f:Seek(8 + n * 16)
		local ofs, len, version = f:ReadLong(), f:ReadLong(), f:ReadLong()
		f:Seek(ofs)

		return f:Read(len) or "", version
	end

	local PLANES, TEXDATA, VERTS = lump(1), lump(2), lump(3)
	local VISIBILITY, NODES = lump(4), lump(5)
	local TEXINFO, FACES = lump(6), lump(7)
	local LEAFS, leafVersion = lump(10)
	local EDGES, SURFEDGES, MODELS = lump(12), lump(13), lump(14)
	local LEAFFACES = lump(16)
	local STRDATA, STRTAB = lump(43), lump(44)
	f:Close()

	local leafSize = leafVersion == 0 and 56 or 32
	local function leafAt(pos)
		local node = 0
		while node >= 0 do
			local np = node * 32 + 1
			local pp = i32(NODES, np) * 20 + 1
			local side = f32(PLANES, pp) * pos.x + f32(PLANES, pp + 4) * pos.y + f32(PLANES, pp + 8) * pos.z - f32(PLANES, pp + 12)
			node = i32(NODES, side >= 0 and np + 4 or np + 8)
		end

		return -node - 1
	end

	local function leafCluster(leaf)
		return i16(LEAFS, leaf * leafSize + 5)
	end

	local faceClusters = {}
	for leaf = 0, #LEAFS / leafSize - 1 do
		local cluster = leafCluster(leaf)
		if cluster >= 0 then
			local lp = leaf * leafSize + 1
			local first, count = u16(LEAFS, lp + 20), u16(LEAFS, lp + 22)
			for n = first, first + count - 1 do
				local fi = u16(LEAFFACES, n * 2 + 1)
				faceClusters[fi] = faceClusters[fi] or {}
				faceClusters[fi][cluster] = true
			end
		end
	end

	local numClusters = #VISIBILITY >= 4 and i32(VISIBILITY, 1) or 0
	local pvsCache = {}
	local function visibleClusters(pos)
		if numClusters <= 0 then return end

		local cluster = leafCluster(leafAt(pos))
		if cluster < 0 then return end

		local pvs = pvsCache[cluster]
		if pvs then return pvs end

		pvs = {}
		local p = i32(VISIBILITY, 5 + cluster * 8) + 1
		local c = 0
		while c < numClusters do
			local b = byte(VISIBILITY, p)
			p = p + 1
			if b == 0 then
				c = c + byte(VISIBILITY, p) * 8
				p = p + 1
			else
				for n = 0, 7 do
					if bit.band(b, bit.lshift(1, n)) ~= 0 then pvs[c + n] = true end
				end
				c = c + 8
			end
		end

		pvsCache[cluster] = pvs
		return pvs
	end

	local function matName(td)
		local id = i32(TEXDATA, td * 32 + 13)
		local ofs = i32(STRTAB, id * 4 + 1)
		local e = STRDATA:find("\0", ofs + 1, true)

		return STRDATA:sub(ofs + 1, (e or 1) - 1)
	end

	local groups = {}
	for mi = 0, #MODELS / 48 - 1 do
		local mp = mi * 48 + 1
		local firstface, numfaces = i32(MODELS, mp + 40), i32(MODELS, mp + 44)

		for fi = firstface, firstface + numfaces - 1 do
			local p = fi * 56 + 1
			local ti = i16(FACES, p + 10)
			if ti >= 0 and i16(FACES, p + 12) < 0 then
				local tp = ti * 72 + 1
				if bit.band(i32(TEXINFO, tp + 64), SURF_WARP) ~= 0 then
					local pp = u16(FACES, p) * 20 + 1
					local nz, dist = f32(PLANES, pp + 8), f32(PLANES, pp + 12)
					if byte(FACES, p + 2) ~= 0 then nz, dist = -nz, -dist end

					local name = matName(i32(TEXINFO, tp + 68)):lower()
					if nz > TOP_FACING and not (name:find("_beneath", 1, true) or name:find("under", 1, true)) then
						local td = i32(TEXINFO, tp + 68)
						local tw, th = i32(TEXDATA, td * 32 + 17), i32(TEXDATA, td * 32 + 21)
						-- folded by texture size, so pass "world x to tiles" and we dont need division
						local su, ou = f32(TEXINFO, tp) / tw, f32(TEXINFO, tp + 12) / tw
						local sv, ov = f32(TEXINFO, tp + 20) / th, f32(TEXINFO, tp + 28) / th

						local key = string.format("%s|%.5f|%.5f|%.5f|%.5f|%d", bodyKey(name), su, ou, sv, ov, math.Round(dist))
						local g = groups[key]
						if not g then
							g = { body = bodyKey(name), materials = {name}, model = mi, su = su, ou = ou, sv = sv, ov = ov, verts = {}, clusters = {} }
							groups[key] = g
						else
							g.materials[#g.materials + 1] = name
						end

						local firstedge, numedges = i32(FACES, p + 4), i16(FACES, p + 8)
						local poly = {}
						for n = 0, numedges - 1 do
							local se = i32(SURFEDGES, (firstedge + n) * 4 + 1)
							local vi = se >= 0 and u16(EDGES, se * 4 + 1) or u16(EDGES, -se * 4 + 3)
							local vp = vi * 12 + 1
							poly[#poly + 1] = Vector(f32(VERTS, vp), f32(VERTS, vp + 4), f32(VERTS, vp + 8))
						end

						for cluster in pairs(faceClusters[fi] or {}) do
							g.clusters[cluster] = true
						end

						-- convex polygon
						local t = g.verts
						for n = 2, #poly - 1 do
							t[#t + 1] = poly[1]
							t[#t + 1] = poly[n]
							t[#t + 1] = poly[n + 1]
						end
					end
				end
			end
		end
	end

	return groups, visibleClusters
end

local function getWaterBrushEntity(mi)
	if mi == 0 then return end

	local want = "*" .. mi
	for _, e in ipairs(ents.GetAll()) do
		if e:GetModel() == want then return e end
	end
end

surfacewater = surfacewater or {}
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

		-- disables surface water rendering
		surfaceMat:SetInt("$fogend", 1e6)
		surfaceMat:SetFloat("$alpha", 0.99)
		surfaceMat:SetInt("$flags", bit.bor(surfaceMat:GetInt("$flags"), 4, MATERIAL_VAR_TRANSLUCENT))

		local underWaterMatName = surfaceMat:GetString("$bottommaterial")
		if not underWaterMatName or underWaterMatName == "" then continue end

		local underWaterMat = Material(underWaterMatName)
		local bottomFogEnd = rememberOriginal(underWaterMat)
		fogEnd = fogEnd or bottomFogEnd
		underWaterMat:SetInt("$fogend", 1e6) -- disables underwater rendering
		underWaterMat:SetString("$underwateroverlay", "") -- disables underwater screen postprocessing

		-- make sure the water is using the expensive setting, we cannot make the cheap water transparent
		underWaterMat:SetInt("$forcecheap", 1)
		underWaterMat:SetInt("$forceexpensive", 0)

		-- disable fresnel and refract/reflect so the surface bumpmap effectively appears transparent
		underWaterMat:SetFloat("$alpha", 0.99)
		underWaterMat:SetInt("$flags", bit.bor(underWaterMat:GetInt("$flags"), 4, MATERIAL_VAR_TRANSLUCENT))
	end

	return fogEnd
end

local SHADER_MAT_KVS = [==[
	screenspace_general
	{
		$pixshader ""
		$vertexshader ""

		$basetexture ""
		$texture1    ""
		$texture2    ""
		$texture3    ""

		// Mandatory, don't touch
		$ignorez            1
		$vertexcolor        1
		$vertextransform    1
		"<dx90"
		{
			$no_draw 1
		}

		$copyalpha                 0
		$alpha_blend_color_overlay 0
		$alpha_blend               1
		$linearwrite               1
		$linearread_basetexture    1
	}
]==]

local function createShaderMaterial(name, opts)
	local keyValues = util.KeyValuesToTable(SHADER_MAT_KVS, false, true)

	if opts then
		for k, v in pairs(opts) do
			keyValues[k] = v
		end
	end

	return CreateMaterial(name, "screenspace_general", keyValues)
end

local SURF_MAT
local meshes = {}
local visibleClusters = function() end

local function dropMeshes()
	for k, m in pairs(meshes) do
		if m.mesh then m.mesh:Destroy() end
		meshes[k] = nil
	end
end

local function writeBodyMesh(g, ent)
	if g.mesh then g.mesh:Destroy() end

	local msh = Mesh(SURF_MAT)
	mesh.Begin(msh, MATERIAL_TRIANGLES, #g.verts / 3)
	-- red channel has the water body murk
	local murkByte = math.floor(g.murk / MURK_MAX * 255 + 0.5)
	local minX, minY, maxX, maxY, maxZ = math.huge, math.huge, -math.huge, -math.huge, -math.huge
	for _, v in ipairs(g.verts) do
		if ent then v = ent:LocalToWorld(v) end
		mesh.Position(v)
		mesh.TexCoord(0, 0, 0)
		mesh.Color(murkByte, 0, 0, 255)
		mesh.AdvanceVertex()
		minX, minY = math.min(minX, v.x), math.min(minY, v.y)
		maxX, maxY, maxZ = math.max(maxX, v.x), math.max(maxY, v.y), math.max(maxZ, v.z)
	end

	mesh.End()
	g.mesh = msh
	g.minX, g.minY, g.maxX, g.maxY, g.surfaceZ = minX, minY, maxX, maxY, maxZ
	g.center = nil
end

local WATER_SURFACEPROPS = { water = true, slime = true, wade = true }

local function isWaterMaterial(name)
	local prop = Material(name):GetString("$surfaceprop")

	return not prop or WATER_SURFACEPROPS[prop:lower()] == true
end

local function buildMeshes()
	dropMeshes()

	if not SURF_MAT then return end

	local groups, visibility = readSurfaceWaterBrushes()
	visibleClusters = visibility or function() end

	for key, g in pairs(groups) do
		if #g.verts >= 3 then
			local foreign = not isWaterMaterial(g.materials[1])
			local fogEnd = not foreign and prepareWaterBodyMaterials(g.materials) or nil
			local normalmap = Material(g.materials[1]):GetString("$normalmap") or "dev/water_normal"
			local murk = fogEnd and math.Clamp(MURK_REF_FOG_END / fogEnd, MURK_MIN, MURK_MAX) or 1

			local body = {
				verts = g.verts, model = g.model, normalmap = normalmap, body = g.body, su = g.su, ou = g.ou, sv = g.sv, ov = g.ov,
				murk = math.floor(murk / MURK_MAX * 255 + 0.5) / 255 * MURK_MAX, clusters = g.clusters, foreign = foreign,
			}
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
	if not g.mesh or g.hidden or g.foreign then return false end
	if g.model ~= 0 or not pvs then return true end

	for cluster in pairs(g.clusters) do
		if pvs[cluster] then return true end
	end

	return false
end

local UNDER_MAT
local SKY_MAT
local SUN_MAT

local SHADERS = { "water_vs30", "water_ps30", "underwater_ps30", "water_skyfill_ps30", "water_sun_ps30" }
local materialSerial = 0

local function initialize()
	materialSerial = materialSerial + 1
	local suffix = os.time() .. "_" .. materialSerial
	local px, vs = "water_ps30", "water_vs30"
	UNDER_MAT = createShaderMaterial("water_underwater_" .. suffix, {
		["$pixshader"] = "underwater_ps30",
		["$vertexshader"] = vs,
		["$alpha_blend"] = 0,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$texture3"] = "procsky/fognoise",
		["$linearread_texture3"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})

	SKY_MAT = createShaderMaterial("water_skyfill_" .. suffix, {
		["$pixshader"] = "water_skyfill_ps30",
		["$vertexshader"] = vs,
		["$alpha_blend"] = 0,
		["$ignorez"] = 0,
	})

	SUN_MAT = createShaderMaterial("water_sun_" .. suffix, {
		["$pixshader"] = "water_sun_ps30",
		["$vertexshader"] = vs,
		["$texture1"] = "procsky/fognoise",
		["$linearread_texture1"] = 1,
		["$alpha_blend"] = 0,
		["$additive"] = 1,
		["$ignorez"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 1, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
	})

	SURF_MAT = createShaderMaterial("water_surface_" .. suffix, {
		["$pixshader"] = px,
		["$vertexshader"] = vs,
		["$alpha_blend"] = 0,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$texture3"] = "procsky/fognoise",
		["$linearread_texture3"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})

	buildMeshes()
end

local function toLinear(c)
	c = c / 255
	return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

local function sunDir()
	if procsky and procsky.GetLights then
		return procsky.GetLights()
	elseif tod and tod.CurrentParams and isangle(tod.CurrentParams.sun_angles) then
		return -tod.CurrentParams.sun_angles:Forward()
	end

	return Vector(0, 0, 1)
end

local SUN_TRACE_LENGTH = 32768
local SUN_TRACE_LIFT = 4
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
		g.center = g.center or Vector((g.minX + g.maxX) * 0.5, (g.minY + g.maxY) * 0.5, g.surfaceZ + SUN_TRACE_LIFT)
		g.sunlit = sunReaches(g.center, sun)
	end

	return g.sunlit
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
local surfaceProbe = Vector()

local function waterSurfaceZ(pos)
	surfaceProbe:Set(pos)
	local lo, step = pos.z, 64
	local hi = lo + step
	surfaceProbe.z = hi
	while isUnderwater(surfaceProbe) do
		if hi - pos.z > SURFACE_SEARCH_MAX then return hi end
		lo, step = hi, step * 2
		hi = lo + step
		surfaceProbe.z = hi
	end

	for _ = 1, 12 do
		local mid = (lo + hi) * 0.5
		surfaceProbe.z = mid
		if isUnderwater(surfaceProbe) then lo = mid else hi = mid end
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

local depthWanted = true

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

	SURF_MAT:SetFloat("$c1_x", eyePos.x)
	SURF_MAT:SetFloat("$c1_y", eyePos.y)
	SURF_MAT:SetFloat("$c1_z", eyePos.z)

	local hr, hg, hb, zr, zg, zb = skyColors()
	SURF_MAT:SetFloat("$c2_x", hr)
	SURF_MAT:SetFloat("$c2_y", hg)
	SURF_MAT:SetFloat("$c2_z", hb)
	SURF_MAT:SetFloat("$c0_y", zr)
	SURF_MAT:SetFloat("$c0_z", zg)
	SURF_MAT:SetFloat("$c0_w", zb)

	local sun = sunDir()
	SURF_MAT:SetFloat("$c3_x", sun.x)
	SURF_MAT:SetFloat("$c3_y", sun.y)
	SURF_MAT:SetFloat("$c3_z", sun.z)

	render.OverrideDepthEnable(true, writeDepth)
	cam.PushModelMatrix(IDENTITY_MATRIX, false)
	for _, g in pairs(meshes) do
		if not bodyDrawable(g, pvs) then continue end

		SURF_MAT:SetTexture("$texture2", g.normalmap)
		SURF_MAT:SetFloat("$c2_w", bodySunlit(g, sun))
		render.SetMaterial(SURF_MAT)
		g.mesh:Draw()
	end
	cam.PopModelMatrix()
	render.OverrideDepthEnable(false, false)
	if not eyeUnderwater then depthslices.Invalidate() end

	return true
end

local QUAD_NEAR = 12
local QUAD_OVERSIZE = 4
local QUAD_COLOR = Color(255, 255, 255, 255)

local function drawScreenQuad(mat, eyePos, distance)
	distance = distance or QUAD_NEAR
	local fwd = EyeAngles():Forward()
	local vs = render.GetViewSetup()
	local halfW = math.tan(math.rad(vs.fov) * 0.5)
	local size = distance * QUAD_OVERSIZE
	render.SetMaterial(mat)
	cam.PushModelMatrix(IDENTITY_MATRIX, false)
	render.DrawQuadEasy(eyePos + fwd * distance, -fwd, halfW * size, halfW / vs.aspect * size, QUAD_COLOR, 0)
	cam.PopModelMatrix()
end

local SKY_FILL_FAR = 0.98
local SUN_FAR = 0.97

local function usableRT(t, w, h)
	if t == nil or t:IsError() then return false end
	if w then return t:Width() == w and t:Height() == h end

	return t:Width() > 64
end

local function targetsReady()
	return usableRT(render.GetScreenEffectTexture()) and usableRT(render.GetResolvedFullFrameDepth())
end

local skyTarget
local function renderSkyTarget()
	local w, h = ScrW(), ScrH()
	if not usableRT(skyTarget, w, h) then
		skyTarget = GetRenderTarget("ms_water_sky_" .. w .. "x" .. h, w, h)
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

local function inForeignLiquid(pos)
	local body = bodyAt(pos, waterSurfaceZ(pos))

	return body ~= nil and body.foreign
end

local function drawOpaque(bDepth, bSkybox, bSkybox3D)
	if not SURF_MAT then return end
	if bDepth or bSkybox3D then return end
	if render.GetRenderTarget() ~= nil then return end
	if not targetsReady() then return end

	updateEntityBodies()

	local eyePos = EyePos()
	local eyeUnderwater = isUnderwater(eyePos)
	if eyeUnderwater and inForeignLiquid(eyePos) then
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
local waterlineProbe = Vector()

local function drawTranslucent(bDepth, bSkybox, bSkybox3D)
	if not UNDER_MAT then return end
	if bDepth or bSkybox3D or bSkybox then return end
	if render.GetRenderTarget() ~= nil then return end
	if not targetsReady() then return end

	local eyePos = EyePos()
	local eyeUnderwater = isUnderwater(eyePos)
	local probe = eyePos
	if not eyeUnderwater then
		waterlineProbe:Set(eyePos)
		waterlineProbe.z = waterlineProbe.z - WATERLINE_BAND
		if not isUnderwater(waterlineProbe) then return end
		probe = waterlineProbe
	end

	local surfaceZ = waterSurfaceZ(probe)
	local body = bodyAt(probe, surfaceZ)
	if body and body.foreign then return end

	depthWanted = true

	if eyeUnderwater then
		drawSurface(eyePos, true, false)
	end

	depthslices.Invalidate()
	depthslices.Capture()
	render.UpdateScreenEffectTexture()
	UNDER_MAT:SetTexture("$basetexture", render.GetScreenEffectTexture())
	UNDER_MAT:SetTexture("$texture1", render.GetResolvedFullFrameDepth())

	local fwd = EyeAngles():Forward()
	UNDER_MAT:SetTexture("$texture2", body and body.normalmap or "dev/water_normal")
	UNDER_MAT:SetFloat("$c2_w", body and body.murk or 1)
	UNDER_MAT:SetFloat("$c0_x", eyePos.x)
	UNDER_MAT:SetFloat("$c0_y", eyePos.y)
	UNDER_MAT:SetFloat("$c0_z", eyePos.z)
	UNDER_MAT:SetFloat("$c0_w", surfaceZ)
	UNDER_MAT:SetFloat("$c1_x", fwd.x)
	UNDER_MAT:SetFloat("$c1_y", fwd.y)
	UNDER_MAT:SetFloat("$c1_z", fwd.z)
	UNDER_MAT:SetFloat("$c1_w", CurTime() % 3600)

	local _, _, _, zr, zg, zb = skyColors()
	UNDER_MAT:SetFloat("$c2_x", zr)
	UNDER_MAT:SetFloat("$c2_y", zg)
	UNDER_MAT:SetFloat("$c2_z", zb)

	local sun = sunDir()
	UNDER_MAT:SetFloat("$c3_x", sun.x)
	UNDER_MAT:SetFloat("$c3_y", sun.y)
	UNDER_MAT:SetFloat("$c3_z", sun.z)
	eyeSurfacePoint:SetUnpacked(eyePos.x, eyePos.y, surfaceZ + SUN_TRACE_LIFT)
	local sunlit = sunReaches(eyeSurfacePoint, sun)
	UNDER_MAT:SetFloat("$c3_w", sunlit)

	drawScreenQuad(UNDER_MAT, eyePos)

	if not eyeUnderwater then return end

	SUN_MAT:SetTexture("$basetexture", body and body.normalmap or "dev/water_normal")
	SUN_MAT:SetFloat("$c0_x", eyePos.x)
	SUN_MAT:SetFloat("$c0_y", eyePos.y)
	SUN_MAT:SetFloat("$c0_z", eyePos.z)
	SUN_MAT:SetFloat("$c0_w", surfaceZ)
	SUN_MAT:SetFloat("$c1_x", sun.x)
	SUN_MAT:SetFloat("$c1_y", sun.y)
	SUN_MAT:SetFloat("$c1_z", sun.z)
	SUN_MAT:SetFloat("$c1_w", CurTime() % 3600)
	SUN_MAT:SetFloat("$c2_x", body and body.murk or 1)
	SUN_MAT:SetFloat("$c2_y", sunlit)
	render.OverrideDepthEnable(true, true)
	drawScreenQuad(SUN_MAT, eyePos, (render.GetViewSetup().zfar or 30000) * SUN_FAR)
	render.OverrideDepthEnable(false, false)
end

local function stop()
	hook.Remove("PostDrawOpaqueRenderables", "ms_water")
	hook.Remove("PostDrawTranslucentRenderables", "ms_water_underwater")
	hook.Remove("NeedsDepthPass", "ms_water")
	depthslices.RemoveEffect("ms_water")
	hideSun(false)
	dropMeshes()
	restoreWaterMaterials()
end

local function start()
	stop()
	initialize()
	hook.Add("PostDrawOpaqueRenderables", "ms_water", drawOpaque)
	hook.Add("PostDrawTranslucentRenderables", "ms_water_underwater", drawTranslucent)
	depthslices.AddEffect("ms_water", SURFACE_ORDER, drawSurfaceAbove)
	depthWanted = true
	hook.Add("NeedsDepthPass", "ms_water", function()
		if depthWanted then return true end
	end)
end

local function shadersAvailable()
	for _, name in ipairs(SHADERS) do
		if not file.Exists("shaders/fxc/" .. name .. ".vcs", "GAME") then return false end
	end

	return true
end

local function apply()
	if not WATER_ENABLED:GetBool() then
		stop()
		return
	end

	if shadersAvailable() then
		start()
	elseif HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
		hook.Add("ShaderMounted", "ms_water", function()
			hook.Remove("ShaderMounted", "ms_water")
			if WATER_ENABLED:GetBool() and shadersAvailable() then
				start()
			end
		end)
	end
end

cvars.RemoveChangeCallback("cl_draw_water", "ms_water")
cvars.AddChangeCallback("cl_draw_water", apply, "ms_water")
hook.Remove("ShaderMounted", "ms_water")
apply()
