local PS, VS = "borealis_lava_ps30", "borealis_fog_vs30"
local AREA_TRIGGER, AREA_MINS, AREA_MAXS, AREA_DELAY = "volcano", "borealis_lava_area_mins", "borealis_lava_area_maxs", 5
local NOISE = "shaderpack/procsky/fognoise"

if SERVER then
	shaderpack.AddResources({ VS, PS }, { NOISE })

	local function publishArea()
		local trigger = ms and ms.GetTrigger and ms.GetTrigger(AREA_TRIGGER)
		if not IsValid(trigger) then return end

		local mins, maxs = trigger:WorldSpaceAABB()
		SetGlobal2Vector(AREA_MINS, mins)
		SetGlobal2Vector(AREA_MAXS, maxs)
	end

	hook.Add("InitPostEntity", "borealis_lava_area", function()
		timer.Simple(AREA_DELAY, publishArea)
	end)

	publishArea()

	return
end

local depthslices, bspdata = shaderpack.depthslices, bspdata
local ENABLED = CreateClientConVar("borealis_lava", "1", true, false, "light, heat shimmer and embers around lava pools")

local ORDER = 0.6
local RES = 256
local MARGIN = 1024
local WIDE_SIGMA = 320
local HEIGHT_RANGE = 255
local CEILING_SEARCH = 4096
local ACTIVE_RANGE = 1500
local ACTIVE_RANGE_BELOW, ACTIVE_RANGE_ABOVE = 512, 2048
local AREA_MARGIN = 1500
local NO_AREA_MINS, NO_AREA_MAXS = Vector(-32768, -32768, -32768), Vector(32768, 32768, 32768)
local FADE_RATE = 1.5
local LOOKUP_INTERVAL = 1
local STRENGTH, SHIMMER, PULSE, GLOW = 2.4, 0.004, 0.25, 1.8
local FUME, CAVE_HAZE = 0.003, 0.35
local EMBER_RATE, EMBER_RANGE, EMBER_TRIES = 24, 2500, 8
local EMBER_MAT = "sprites/light_glow02_add"
local SURFACE_COVER = 0.5
local HEAT_SIGMA, HEAT_RANGE, HEAT_SWEEPS = 120, 3, 2
local HEAT_TRACE_HEIGHTS = { 64, 256 }
local MASK_DIR = "shaderpack/lava"
local VTF_FLAGS = 0x4 + 0x8 + 0x100 + 0x200 + 0x2000
local VTF_FORMAT = 0

local setConstant = shaderpack.SetConstant

local function readPools()
	local f, lump = bspdata.OpenLumps()
	if not f then return {} end

	local ENTITIES, TEXDATA, VERTS, TEXINFO, FACES = lump(0), lump(2), lump(3), lump(6), lump(7)
	local EDGES, SURFEDGES, MODELS = lump(12), lump(13), lump(14)
	local STRDATA, STRTAB = lump(43), lump(44)
	f:Close()

	local u16, i16, i32, f32 = bspdata.U16, bspdata.I16, bspdata.I32, bspdata.F32

	local function matName(td)
		local id = i32(TEXDATA, td * 32 + 13)
		local ofs = i32(STRTAB, id * 4 + 1)
		local e = STRDATA:find("\0", ofs + 1, true)

		return STRDATA:sub(ofs + 1, (e or 1) - 1)
	end

	local origins = {}
	for block in ENTITIES:gmatch("%b{}") do
		local model = block:match("\"model\" \"(%*%d+)\"")
		if model then
			local x, y, z = (block:match("\"origin\" \"([^\"]*)\"") or "0 0 0"):match("(%S+)%s+(%S+)%s+(%S+)")
			origins[model] = Vector(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
		end
	end

	local function isLava(p)
		local ti = i16(FACES, p + 10)
		if ti < 0 then return false end

		local name = matName(i32(TEXINFO, ti * 72 + 69)):lower()

		return name:find("lava", 1, true) ~= nil and not name:find("beneath", 1, true)
	end

	local function topPolygon(p, top, origin)
		local firstedge, numedges = i32(FACES, p + 4), i16(FACES, p + 8)
		local poly = {}
		for n = 0, numedges - 1 do
			local se = i32(SURFEDGES, (firstedge + n) * 4 + 1)
			local vi = se >= 0 and u16(EDGES, se * 4 + 1) or u16(EDGES, -se * 4 + 3)
			local vp = vi * 12 + 1
			if math.abs(f32(VERTS, vp + 8) - top) > 1 then return end

			poly[#poly + 1] = { f32(VERTS, vp) + origin.x, f32(VERTS, vp + 4) + origin.y }
		end

		return #poly >= 3 and poly or nil
	end

	local pools = {}
	for mi = 1, #MODELS / 48 - 1 do
		local mp = mi * 48 + 1
		local top = f32(MODELS, mp + 20)
		local origin = origins["*" .. mi] or Vector()
		local firstface, numfaces = i32(MODELS, mp + 40), i32(MODELS, mp + 44)
		local polys = {}
		for fi = firstface, firstface + numfaces - 1 do
			local p = fi * 56 + 1
			local poly = isLava(p) and topPolygon(p, top, origin)
			if poly then
				polys[#polys + 1] = poly
			end
		end

		if #polys > 0 then
			local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
			for _, poly in ipairs(polys) do
				for _, v in ipairs(poly) do
					x0, y0, x1, y1 = math.min(x0, v[1]), math.min(y0, v[2]), math.max(x1, v[1]), math.max(y1, v[2])
				end
			end

			pools[#pools + 1] = { model = "*" .. mi, origin = origin, top = top + origin.z, polys = polys, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
		end
	end

	return pools
end

local function inside(poly, x, y)
	local sign = 0
	local n = #poly
	for k = 1, n do
		local a, b = poly[k], poly[k % n + 1]
		local c = (b[1] - a[1]) * (y - a[2]) - (b[2] - a[2]) * (x - a[1])
		if c ~= 0 then
			local s = c > 0 and 1 or -1
			if sign == 0 then
				sign = s
			elseif s ~= sign then
				return false
			end
		end
	end

	return true
end

local SUBSAMPLES = { { 0.25, 0.25 }, { 0.75, 0.25 }, { 0.25, 0.75 }, { 0.75, 0.75 } }

local function insideAny(polys, x, y)
	for _, poly in ipairs(polys) do
		if inside(poly, x, y) then return true end
	end

	return false
end

local openTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = {} }

local function openAbove(x, y, z)
	openTrace.start:SetUnpacked(x, y, z + 0.5)
	openTrace.endpos:SetUnpacked(x, y, z + CEILING_SEARCH)
	local tr = util.TraceLine(openTrace)
	if tr.StartSolid then return false end

	openTrace.start:SetUnpacked(x, y, tr.HitPos.z - 1)
	openTrace.endpos:SetUnpacked(x, y, z + 0.5)

	return not util.TraceLine(openTrace).Hit
end

local DIAGONAL = math.sqrt(2)

local function relax(dist, i, j, step, ok)
	if not ok then return end

	local d = dist[j] + step
	if d < dist[i] then
		dist[i] = d
	end
end

local OPEN = setmetatable({}, { __index = function() return true end })

local function forwardRow(dist, cy, passE, passN)
	for cx = 0, RES - 1 do
		local i = cy * RES + cx + 1
		if cx > 0 then
			relax(dist, i, i - 1, 1, passE[i - 1])
		end

		if cy > 0 then
			local up = i - RES
			relax(dist, i, up, 1, passN[up])
			if cx > 0 then
				local j = up - 1
				relax(dist, i, j, DIAGONAL, passE[j] and passN[up] or passN[j] and passE[i - 1])
			end

			if cx < RES - 1 then
				local j = up + 1
				relax(dist, i, j, DIAGONAL, passE[up] and passN[up] or passN[j] and passE[i])
			end
		end
	end
end

local function backwardRow(dist, cy, passE, passN)
	for cx = RES - 1, 0, -1 do
		local i = cy * RES + cx + 1
		if cx < RES - 1 then
			relax(dist, i, i + 1, 1, passE[i])
		end

		if cy < RES - 1 then
			local down = i + RES
			relax(dist, i, down, 1, passN[i])
			if cx < RES - 1 then
				local j = down + 1
				relax(dist, i, j, DIAGONAL, passE[i] and passN[i + 1] or passN[i] and passE[down])
			end

			if cx > 0 then
				local j = down - 1
				relax(dist, i, j, DIAGONAL, passE[i - 1] and passN[i - 1] or passN[i] and passE[j])
			end
		end
	end
end

local function chamfer(dist, passE, passN, budget)
	for cy = 0, RES - 1 do
		forwardRow(dist, cy, passE, passN)
		budget()
	end

	for cy = RES - 1, 0, -1 do
		backwardRow(dist, cy, passE, passN)
		budget()
	end
end

local heatTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = {} }

local function openBetween(x0, y0, x1, y1, top)
	for _, height in ipairs(HEAT_TRACE_HEIGHTS) do
		heatTrace.start:SetUnpacked(x0, y0, top + height)
		heatTrace.endpos:SetUnpacked(x1, y1, top + height)
		if not util.TraceLine(heatTrace).Hit then return true end
	end

	return false
end

local function airEdges(near, height, minTop, ox, oy, texel, budget)
	local passE, passN = setmetatable({}, getmetatable(OPEN)), setmetatable({}, getmetatable(OPEN))
	local rangeTexels = HEAT_RANGE * HEAT_SIGMA / texel
	for cy = 0, RES - 1 do
		local y = oy + (cy + 0.5) * texel
		for cx = 0, RES - 1 do
			local i = cy * RES + cx + 1
			if near[i] <= rangeTexels then
				local x = ox + (cx + 0.5) * texel
				local top = minTop + height[i] * HEIGHT_RANGE
				if cx < RES - 1 then
					passE[i] = openBetween(x, y, x + texel, y, top)
				end

				if cy < RES - 1 then
					passN[i] = openBetween(x, y, x, y + texel, top)
				end
			end
		end

		budget()
	end

	return passE, passN
end

local function heatFalloff(cover, height, minTop, ox, oy, texel, budget)
	local near, dist = {}, {}
	for i = 1, RES * RES do
		near[i] = cover[i] >= SURFACE_COVER and 0 or math.huge
		dist[i] = near[i]
	end

	chamfer(near, OPEN, OPEN, budget)
	local passE, passN = airEdges(near, height, minTop, ox, oy, texel, budget)
	for _ = 1, HEAT_SWEEPS do
		chamfer(dist, passE, passN, budget)
	end

	local k = -0.5 * (texel / HEAT_SIGMA) ^ 2
	for i = 1, RES * RES do
		dist[i] = math.exp(k * dist[i] * dist[i])
	end

	return dist
end

local function boxBlur(src, r)
	local tmp, dst = {}, {}
	local norm = 1 / (2 * r + 1)
	for y = 0, RES - 1 do
		local row = y * RES + 1
		local sum = 0
		for x = 0, r do
			sum = sum + (x < RES and src[row + x] or 0)
		end

		for x = 0, RES - 1 do
			tmp[row + x] = sum * norm
			local add, sub = x + r + 1, x - r
			sum = sum + (add < RES and src[row + add] or 0) - (sub >= 0 and src[row + sub] or 0)
		end
	end

	for x = 0, RES - 1 do
		local col = x + 1
		local sum = 0
		for y = 0, r do
			sum = sum + (y < RES and tmp[y * RES + col] or 0)
		end

		for y = 0, RES - 1 do
			dst[y * RES + col] = sum * norm
			local add, sub = y + r + 1, y - r
			sum = sum + (add < RES and tmp[add * RES + col] or 0) - (sub >= 0 and tmp[sub * RES + col] or 0)
		end
	end

	return dst
end

local lava = shaderpack.lava or {}
shaderpack.lava = lava

local function bake(pools, budget)
	local x0, y0, x1, y1, minTop, maxTop = math.huge, math.huge, -math.huge, -math.huge, math.huge, -math.huge
	for _, pool in ipairs(pools) do
		x0, y0, x1, y1 = math.min(x0, pool.x0), math.min(y0, pool.y0), math.max(x1, pool.x1), math.max(y1, pool.y1)
		minTop, maxTop = math.min(minTop, pool.top), math.max(maxTop, pool.top)
	end

	local size = math.max(x1 - x0, y1 - y0) + MARGIN * 2
	local ox, oy = (x0 + x1 - size) / 2, (y0 + y1 - size) / 2
	local texel = size / RES

	local cover, height = {}, {}
	for i = 1, RES * RES do
		cover[i] = 0
	end

	local function texelCover(pool, cx, cy)
		local hits = 0
		for _, s in ipairs(SUBSAMPLES) do
			local x, y = ox + (cx + s[1]) * texel, oy + (cy + s[2]) * texel
			if insideAny(pool.polys, x, y) and openAbove(x, y, pool.top) then
				hits = hits + 1
			end
		end

		return hits / #SUBSAMPLES
	end

	for _, pool in ipairs(pools) do
		local cx0, cx1 = math.max(0, math.floor((pool.x0 - ox) / texel)), math.min(RES - 1, math.floor((pool.x1 - ox) / texel))
		local cy0, cy1 = math.max(0, math.floor((pool.y0 - oy) / texel)), math.min(RES - 1, math.floor((pool.y1 - oy) / texel))
		for cy = cy0, cy1 do
			for cx = cx0, cx1 do
				local i = cy * RES + cx + 1
				cover[i] = math.max(cover[i], texelCover(pool, cx, cy))
				budget()
			end
		end
	end

	for cy = 0, RES - 1 do
		local y = oy + (cy + 0.5) * texel
		for cx = 0, RES - 1 do
			local x = ox + (cx + 0.5) * texel
			local best, top = math.huge, minTop
			for _, pool in ipairs(pools) do
				local dx = math.max(pool.x0 - x, 0, x - pool.x1)
				local dy = math.max(pool.y0 - y, 0, y - pool.y1)
				local dist = dx * dx + dy * dy
				if dist < best then
					best, top = dist, pool.top
				end
			end

			height[cy * RES + cx + 1] = math.Clamp(top - minTop, 0, HEIGHT_RANGE) / HEIGHT_RANGE
		end

		budget()
	end

	local near = boxBlur(cover, 1)
	local r = math.max(1, math.Round(WIDE_SIGMA / texel))
	local wide = boxBlur(boxBlur(boxBlur(cover, r), r), r)
	local heat = heatFalloff(cover, height, minTop, ox, oy, texel, budget)

	local rows = { shaderpack.VTFHeader(RES, RES, VTF_FORMAT, VTF_FLAGS) }
	local bytes = {}
	for cy = 0, RES - 1 do
		for cx = 0, RES - 1 do
			local i = cy * RES + cx + 1
			local b = cx * 4
			bytes[b + 1] = math.floor(math.Clamp(near[i], 0, 1) * 255 + 0.5)
			bytes[b + 2] = math.floor(math.Clamp(wide[i], 0, 1) * 255 + 0.5)
			bytes[b + 3] = math.floor(height[i] * 255 + 0.5)
			bytes[b + 4] = math.floor(heat[i] * 255 + 0.5)
		end

		rows[#rows + 1] = string.char(unpack(bytes, 1, RES * 4))
		budget()
	end

	local lavaTexels = {}
	for i = 1, RES * RES do
		if cover[i] >= 1 then
			lavaTexels[#lavaTexels + 1] = i - 1
		end
	end

	return {
		vtf = table.concat(rows), ox = ox, oy = oy, size = size, texel = texel, minTop = minTop, maxTop = maxTop,
		x0 = x0, y0 = y0, x1 = x1, y1 = y1, cover = cover, height = height, lavaTexels = lavaTexels,
	}
end

local function loadMask(vtf)
	file.CreateDir(MASK_DIR)
	for _, old in ipairs(file.Find(MASK_DIR .. "/*.vtf", "DATA")) do
		file.Delete(MASK_DIR .. "/" .. old)
	end

	local key = game.GetMap() .. "_" .. os.time()
	file.Write(MASK_DIR .. "/" .. key .. ".vtf", vtf)
	local mat = CreateMaterial("borealis_lava_mask_" .. key, "UnlitGeneric", { ["$basetexture"] = "../data/" .. MASK_DIR .. "/" .. key })
	local tex = mat:GetTexture("$basetexture")

	return tex and not tex:IsError() and tex or nil
end

local MAT
local materialSerial = 0

local function build()
	materialSerial = materialSerial + 1
	MAT = CreateShaderMaterial("borealis_lava_" .. os.time() .. "_" .. materialSerial, {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$texture3"] = NOISE,
		["$linearread_basetexture"] = 0,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
		["$linearwrite"] = 0,
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
		["$ignorez"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})
end

local fade, level, pendingSpawns = 0, 0, 0

local function findEntity(pool)
	local now = RealTime()
	if IsValid(pool.ent) or (pool.lookupAt and now - pool.lookupAt < LOOKUP_INTERVAL) then return pool.ent end

	pool.lookupAt = now
	for _, e in ents.Iterator() do
		if e:GetModel() == pool.model then
			pool.ent = e

			return e
		end
	end
end

local function area()
	local mins, maxs = GetGlobal2Vector(AREA_MINS, vector_origin), GetGlobal2Vector(AREA_MAXS, vector_origin)
	if mins == maxs then return end

	return mins, maxs
end

local function nearLava(eye)
	local mins, maxs = area()
	if mins then
		if eye.x < mins.x - AREA_MARGIN or eye.x > maxs.x + AREA_MARGIN or eye.y < mins.y - AREA_MARGIN or eye.y > maxs.y + AREA_MARGIN then return false end
		if eye.z < mins.z - AREA_MARGIN or eye.z > maxs.z + AREA_MARGIN then return false end
	else
		local m = lava.data
		if eye.x < m.x0 - ACTIVE_RANGE or eye.x > m.x1 + ACTIVE_RANGE or eye.y < m.y0 - ACTIVE_RANGE or eye.y > m.y1 + ACTIVE_RANGE then return false end
		if eye.z < m.minTop - ACTIVE_RANGE_BELOW or eye.z > m.maxTop + ACTIVE_RANGE_ABOVE then return false end
	end

	for _, pool in ipairs(lava.pools) do
		local ent = findEntity(pool)
		if IsValid(ent) and not ent:IsDormant() then
			level = ent:GetPos().z - pool.origin.z

			return true
		end
	end

	return false
end

local emberPos, emberVel, emberGravity = Vector(), Vector(), Vector(0, 0, 10)

local function spawnEmber(eye)
	local m = lava.data
	local texels = m.lavaTexels
	for _ = 1, EMBER_TRIES do
		local t = texels[math.random(#texels)]
		local cx, cy = t % RES, math.floor(t / RES)
		local x, y = m.ox + (cx + math.random()) * m.texel, m.oy + (cy + math.random()) * m.texel
		local z = m.minTop + m.height[t + 1] * HEIGHT_RANGE + level + 2
		if (x - eye.x) ^ 2 + (y - eye.y) ^ 2 + (z - eye.z) ^ 2 < EMBER_RANGE * EMBER_RANGE then
			emberPos:SetUnpacked(x, y, z)
			local p = lava.emitter:Add(EMBER_MAT, emberPos)
			if not p then return end

			emberVel:SetUnpacked(math.Rand(-12, 12), math.Rand(-12, 12), math.Rand(30, 80))
			p:SetVelocity(emberVel)
			p:SetGravity(emberGravity)
			p:SetAirResistance(15)
			p:SetDieTime(math.Rand(3, 7))
			p:SetStartAlpha(255)
			p:SetEndAlpha(0)
			p:SetStartSize(math.Rand(1.2, 2.6))
			p:SetEndSize(0)
			p:SetColor(255, math.random(90, 160), 40)
			p:SetLighting(false)

			return
		end
	end
end

function lava.Fade()
	return fade
end

function lava.Surface(x, y)
	local m = lava.data
	if not m then return end

	local cx, cy = math.floor((x - m.ox) / m.texel), math.floor((y - m.oy) / m.texel)
	if cx < 0 or cy < 0 or cx >= RES or cy >= RES then return end

	local i = cy * RES + cx + 1
	if m.cover[i] < SURFACE_COVER then return end

	return m.minTop + m.height[i] * HEIGHT_RANGE + level
end

local function think()
	local eye = EyePos()
	local target = nearLava(eye) and 1 or 0
	local dt = RealFrameTime()
	fade = target > fade and math.min(target, fade + FADE_RATE * dt) or math.max(target, fade - FADE_RATE * dt)
	if fade <= 0 or #lava.data.lavaTexels == 0 then return end

	lava.emitter:SetPos(eye)
	pendingSpawns = pendingSpawns + EMBER_RATE * fade * dt
	while pendingSpawns >= 1 do
		pendingSpawns = pendingSpawns - 1
		spawnEmber(eye)
	end
end

local quadColor = Color(0, 0, 0, 255)
local extra = Matrix()

local function draw()
	if fade <= 0.001 then return end

	if not MAT then build() end

	MAT:SetTexture("$texture2", lava.mask)
	local m = lava.data
	local eye, ang = EyePos(), EyeAngles()
	local fwd, right = ang:Forward(), ang:Right()
	local halfW, halfH = depthslices.ViewTan()
	setConstant(MAT, "$c0", eye.x, eye.y, eye.z, CurTime() % 3600)
	setConstant(MAT, "$c1", fwd.x, fwd.y, fwd.z, halfW)
	setConstant(MAT, "$c2", right.x, right.y, right.z, halfH)
	setConstant(MAT, "$c3", m.ox, m.oy, m.size, m.minTop + level)
	local mins, maxs = area()
	local haze = mins and CAVE_HAZE or 0
	mins, maxs = mins or NO_AREA_MINS, maxs or NO_AREA_MAXS
	extra:SetUnpacked(
		STRENGTH * fade, SHIMMER * fade, PULSE * fade, Lerp(fade, 1, GLOW),
		mins.x, mins.y, mins.z, FUME * fade,
		maxs.x, maxs.y, maxs.z, haze,
		0, 0, 0, 0
	)
	MAT:SetMatrix("$viewprojmat", extra)
	quadColor.b = depthslices.Samples()

	return depthslices.Composite(MAT, quadColor)
end

local function stop()
	hook.Remove("Think", "borealis_lava")
	hook.Remove("Think", "borealis_lava_bake")
	lava.baking = nil
	depthslices.RemoveEffect("borealis_lava")
	if lava.emitter then
		lava.emitter:Finish()
		lava.emitter = nil
	end

	fade = 0
end

local function activate()
	if not lava.mask then return end

	lava.emitter = ParticleEmitter(EyePos())
	hook.Add("Think", "borealis_lava", think)
	depthslices.AddEffect("borealis_lava", ORDER, draw, true, function() return fade > 0.001 end)
end

local function bakeAll()
	local pools = readPools()
	if #pools == 0 then
		lava.data = false

		return
	end

	local data = bake(pools, bspdata.FrameBudget())
	lava.mask = loadMask(data.vtf)
	data.vtf = nil
	lava.pools, lava.data = pools, data
end

local function bakeStep()
	local co = lava.baking
	local ok, err = coroutine.resume(co)
	if not ok then
		ErrorNoHalt("[lava] mask bake failed: " .. tostring(err) .. "\n")
	end

	if coroutine.status(co) == "dead" then
		hook.Remove("Think", "borealis_lava_bake")
		lava.baking = nil
		if ok then activate() end
	end
end

local function start()
	stop()
	MAT = nil

	if lava.data ~= nil then
		activate()

		return
	end

	lava.baking = coroutine.create(bakeAll)
	hook.Add("Think", "borealis_lava_bake", bakeStep)
end

shaderpack.AfterWorld("borealis_lava", shaderpack.Toggle("borealis_lava", ENABLED, { PS, VS }, start, stop, { NOISE }))
