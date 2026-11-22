local DRIP_PS, DRIP_VS = "borealis_drip_ps30", "borealis_drip_vs30"
local SHADERS = { DRIP_VS, DRIP_PS }

if SERVER then
	shaderpack.AddResources(SHADERS)

	return
end

local cover, locallights, dynamiclights, wind = shaderpack.cover, shaderpack.locallights, shaderpack.dynamiclights, shaderpack.wind
local ENABLED = CreateClientConVar("borealis_drips", "1", true, false, "drip rain off roof edges")

local COLUMN = cover.COLUMN
local COVERED = cover.Z_MIN + cover.Z_RANGE
local EDGE_MIN = 48
local ROOF_FLAT = 0.3
local PROBE, PROBE_UP = 8, 40
local LIP_STEPS = 6
local MAX_GAP = 2
local LIP_OUT = 1.5
local LIP_BACK = 3
local LANES, LANE_STEP, LANE_JITTER = 3, 8, 5
local FALL_MIN = 24
local LAND_EXTRA = 64
local LIGHT_LIFT = 12
local TRACES_PER_FRAME = 48
local NATURAL = { [MAT_GRASS] = true, [MAT_DIRT] = true, [MAT_SAND] = true, [MAT_FOLIAGE] = true, [MAT_SNOW] = true }

local GRAVITY = 600
local PERIOD_MIN, PERIOD_LOG = 0.015, 5.7038
local RELEASE_JITTER = 0.7
local SEEDS = 4096
local CORNER_PROBE = 12
local SPILL_CELL = 96
local SPILL_SLOPE = 0.15
local SPILL_CHANCE = 0.7
local SPILL_PERIOD_MIN, SPILL_PERIOD_MAX = 0.018, 0.03
local STREAM_BYTE = 64
local LAUNCH = 30
local PERIOD_BASE, PERIOD_SPREAD = 0.35, 8
local CLUSTER_SCALE = 1 / 96
local ACTIVE_MIN, ACTIVE_RANGE = 0.25, 0.65
local WRAP = 256

local DRAIN_RISE, DRAIN_FALL = 1 / 20, 1 / 90
local DRAIN_MIN = 0.02
local SLANT = 0.08
local TILE = 256
local DRAW_RANGE = 760
local KEEP_RANGE = 1200
local REBUILDS = 2
local EVICT_INTERVAL = 1
local MAX_TILE_LANES = 1500
local ALPHA = 0.5
local COLOR_BODY, COLOR_HEAD, COLOR_HEAD_FLOOR = 0.5, 1.5, 0.22
local LIT = 0.6
local ROWS = 8
local SPLASH_CODE = 32
local SOUND_RANGE, SOUND_RATE, SOUND_LEVEL, SOUND_VOLUME = 350, 6, 60, 1
local STREAM_SOUND, STREAM_MODEL = "ambient/water/water_flow_loop1.wav", "models/props_junk/popcan01a.mdl"
local STREAM_SOUNDS, STREAM_RANGE, STREAM_LIFT, STREAM_PICK_INTERVAL = 2, 800, 4, 0.25
local STREAM_LEVEL, STREAM_VOLUME, STREAM_PITCH, STREAM_PITCH_SPREAD = 70, 2, 95, 15
local GROUND_SOUNDS = { "ambient/water/rain_drip1.wav", "ambient/water/rain_drip2.wav", "ambient/water/rain_drip3.wav", "ambient/water/rain_drip4.wav" }
local WATER_SOUNDS = { "ambient/water/drip1.wav", "ambient/water/drip2.wav", "ambient/water/drip3.wav", "ambient/water/drip4.wav" }

local packColor, setConstant, setVertexConstants = shaderpack.PackColor, shaderpack.SetConstant, shaderpack.SetVertexConstants
local columnKey, columnFromKey = cover.ColumnKey, cover.ColumnFromKey
local UP = Vector(0, 0, 1)
local probe = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = {} }
local landing = { mask = bit.bor(MASK_SOLID_BRUSHONLY, CONTENTS_WATER), start = Vector(), endpos = Vector(), output = {} }
local samplePos = Vector()
local vertexPos = Vector()
local rows = { {} }
local MAT

local edges, queue, queued = {}, {}, {}
local tiles, spillCells, streamSlots = {}, {}, {}
local streamNear, streamDist, nextStreamPick = {}, {}, 0
local drain, soundTokens = 0, 0
local seeded = false
local lastTime, nextEvict = nil, 0
local function soundVolume()
	local precipitations = shaderpack.precipitations

	return precipitations and precipitations.RainVolume() or 0
end

local function frac(x)
	return x - math.floor(x)
end

local function hash3(x, y)
	local qx, qy, qz = frac(x * 0.1031), frac(y * 0.1030), frac(x * 0.0973)
	local d = qx * (qy + 33.33) + qy * (qx + 33.33) + qz * (qz + 33.33)
	qx, qy, qz = qx + d, qy + d, qz + d

	return frac((qx + qy) * qz), frac((qx + qz) * qy), frac((qy + qz) * qx)
end

local function hash(a, b)
	local h = math.sin(a * 12.9898 + b * 78.233) * 43758.5453

	return h - math.floor(h)
end

local function valueNoise(x, y)
	local ix, iy = math.floor(x), math.floor(y)
	local fx, fy = x - ix, y - iy
	fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)

	return Lerp(fy, Lerp(fx, hash(ix, iy), hash(ix + 1, iy)), Lerp(fx, hash(ix, iy + 1), hash(ix + 1, iy + 1)))
end

local function pairKey(cx, cy, axis)
	return columnKey(cx, cy) * 2 + axis
end

local function tileKey(x, y)
	return columnKey(math.floor(x / TILE), math.floor(y / TILE))
end

local function roofAt(x, y, z)
	probe.start:SetUnpacked(x, y, z + PROBE_UP)
	probe.endpos:SetUnpacked(x, y, z - PROBE)
	util.TraceLine(probe)
	local r = probe.output

	return r.Hit and not r.StartSolid and r
end

local function lightByte(v)
	return math.floor(math.sqrt(math.Clamp(v / 4, 0, 1)) * 255 + 0.5)
end

local function planeZ(plane, x, y)
	return plane[3] + (x - plane[1]) * plane[4] + (y - plane[2]) * plane[5]
end

local function onRoof(plane, x, y)
	return roofAt(x, y, planeZ(plane, x, y))
end

local function spills(lx, ly, ox, oy, plane)
	local bx, by = lx - ox * (LIP_OUT + LIP_BACK), ly - oy * (LIP_OUT + LIP_BACK)
	for side = -1, 1, 2 do
		local ax, ay = oy * side, ox * side
		if not onRoof(plane, bx + ax * CORNER_PROBE, by + ay * CORNER_PROBE) then return ox + ax, oy + ay end
		if onRoof(plane, lx + ax * CORNER_PROBE, ly + ay * CORNER_PROBE) then return ox, oy end
	end
end

local function direction(x, y)
	return math.floor(math.atan2(y, x) / (math.pi / 4) + 0.5) % 8
end

local function claimSpill(x, y, owner)
	local cx, cy = math.floor(x / SPILL_CELL), math.floor(y / SPILL_CELL)
	for i = -1, 1 do
		for j = -1, 1 do
			local o = spillCells[columnKey(cx + i, cy + j)]
			if o and o ~= owner then return false end
		end
	end

	spillCells[columnKey(cx, cy)] = owner

	return true
end

local function period(density, lx, ly, spill)
	if spill and hash(ly, lx) < SPILL_CHANCE then
		return Lerp(hash(lx, ly + 1), SPILL_PERIOD_MIN, SPILL_PERIOD_MAX)
	end

	return PERIOD_BASE * PERIOD_SPREAD ^ hash(lx + 1, ly) * (1.6 - density)
end

local function landAt(x, y, top, zb)
	landing.start:SetUnpacked(x, y, top)
	landing.endpos:SetUnpacked(x, y, zb - LAND_EXTRA)
	util.TraceLine(landing)
	local land = landing.output

	return land.Hit and not land.StartSolid and land
end

local function buildLane(lx, ly, ox, oy, plane, zb, density, owner)
	local bx, by = lx - ox * (LIP_OUT + LIP_BACK), ly - oy * (LIP_OUT + LIP_BACK)
	local back = onRoof(plane, bx, by)
	if not back then return nil end

	local top = back.HitPos.z - 1
	if onRoof(plane, lx, ly) then return nil end

	local vx, vy
	if plane[4] * ox + plane[5] * oy < -SPILL_SLOPE then
		vx, vy = spills(lx, ly, ox, oy, plane)
	end

	local spill = vx ~= nil and claimSpill(lx, ly, owner)
	if not spill and hash(lx, ly) > ACTIVE_MIN + ACTIVE_RANGE * density then return nil end

	local dir = spill and direction(vx, vy) or direction(ox, oy)
	local rateByte = math.Clamp(math.floor(math.log(period(density, lx, ly, spill) / PERIOD_MIN) / PERIOD_LOG * 255 + 0.5), 0, 255)
	local stream = rateByte < STREAM_BYTE
	local land = landAt(lx, ly, top, zb)
	if not land then return nil end

	local sx, sy = lx, ly
	if stream then
		local a, off = dir * math.pi / 4, LAUNCH * math.sqrt(2 * (top - land.HitPos.z) / GRAVITY)
		sx, sy = lx + math.cos(a) * off, ly + math.sin(a) * off
		land = landAt(sx, sy, top, zb)
		if not land then return nil end
	end

	local bottom = land.HitPos.z
	if top - bottom < FALL_MIN then return nil end

	samplePos:SetUnpacked(sx, sy, bottom + LIGHT_LIFT)
	local l, dl = render.ComputeLighting(samplePos, UP), render.ComputeDynamicLighting(samplePos, UP)
	local seed = math.floor(hash(lx * 0.37, ly * 0.71) * SEEDS)

	return {
		x = lx, y = ly, top = top, bottom = bottom, sx = sx, sy = sy,
		water = bit.band(land.Contents, CONTENTS_WATER) ~= 0,
		r = lightByte(l.x - dl.x), g = lightByte(l.y - dl.y), b = lightByte(l.z - dl.z),
		code = (rateByte * SEEDS + seed) * 8 + dir,
		seed = seed,
		period = PERIOD_MIN * math.exp(rateByte / 255 * PERIOD_LOG),
		stream = stream,
		tauFall = math.sqrt(2 * (top - bottom) / GRAVITY),
	}
end

local function evaluate(key, cx, cy, axis)
	local dx, dy = axis == 0 and 1 or 0, axis == 1 and 1 or 0
	local ax, ay = (cx + 0.5) * COLUMN, (cy + 0.5) * COLUMN
	local za = cover.HeightAt(ax, ay)
	if not za or za >= COVERED then return nil, 0 end

	local bx, by, zb, gap
	for g = 1, MAX_GAP do
		bx, by = ax + dx * COLUMN * g, ay + dy * COLUMN * g
		zb, gap = cover.HeightAt(bx, by), g
		if not zb or zb < COVERED then break end
	end
	if not zb or zb >= COVERED or math.abs(za - zb) < EDGE_MIN then return nil, 0 end

	local ox, oy = dx, dy
	if zb > za then
		ax, ay, za, zb, ox, oy = bx, by, zb, za, -dx, -dy
	end

	local roof = roofAt(ax, ay, za)
	if not roof or roof.HitNormal.z < ROOF_FLAT or NATURAL[roof.MatType] then return nil, 1 end

	local n = roof.HitNormal
	local plane = { ax, ay, roof.HitPos.z, -n.x / n.z, -n.y / n.z }

	local span = COLUMN * gap
	local lo, hi = 0, span
	for _ = 1, LIP_STEPS do
		local mid = (lo + hi) * 0.5
		if onRoof(plane, ax + ox * mid, ay + oy * mid) then lo = mid else hi = mid end
	end

	local traces = 1 + LIP_STEPS
	if hi >= span - 1 then return nil, traces end

	local lanes = {}
	for k = 1, LANES do
		local s = (k - (LANES + 1) * 0.5) * LANE_STEP + (hash(key, k) - 0.5) * LANE_JITTER
		local lx, ly = ax + dy * s + ox * (hi + LIP_OUT), ay + dx * s + oy * (hi + LIP_OUT)
		local density = valueNoise(lx * CLUSTER_SCALE, ly * CLUSTER_SCALE)
		lanes[#lanes + 1] = buildLane(lx, ly, ox, oy, plane, zb, density, key * LANES + k)
		traces = traces + 7
	end

	if #lanes == 0 then return nil, traces end

	return { tile = tileKey(ax, ay), lanes = lanes }, traces
end

local function tileAt(key)
	local t = tiles[key]
	if not t then
		t = { edges = {}, dirty = true }
		tiles[key] = t
	end

	return t
end

local function setEdge(key, edge)
	local old = edges[key]
	if old then
		local t = tiles[old.tile]
		if t then
			t.edges[key] = nil
			t.dirty = true
		end
	end

	edges[key] = edge
	if edge then
		local t = tileAt(edge.tile)
		t.edges[key] = edge
		t.dirty = true
	end
end

local function enqueue(cx, cy, axis)
	local key = pairKey(cx, cy, axis)
	if queued[key] then return end

	queued[key] = true
	queue[#queue + 1] = key
end

local function onColumn(cx, cy, coverChanged)
	if not coverChanged then return end

	for g = 0, MAX_GAP do
		enqueue(cx - g, cy, 0)
		enqueue(cx, cy - g, 1)
	end
end

local function destroyTile(t)
	if t.mesh then t.mesh:Destroy() end
	t.mesh = nil
end

local function reset()
	for _, t in pairs(tiles) do
		destroyTile(t)
	end

	edges, queue, queued, tiles, spillCells = {}, {}, {}, {}, {}
	streamNear, streamDist, nextStreamPick = {}, {}, 0
	seeded = false
end

local function seed()
	local winX, winY = cover.Window()
	if not winX then return end

	for cx = winX, winX + cover.COLUMNS - 1 do
		for cy = winY, winY + cover.COLUMNS - 1 do
			enqueue(cx, cy, 0)
			enqueue(cx, cy, 1)
		end
	end

	seeded = true
end

local function processQueue()
	local budget = TRACES_PER_FRAME
	while budget > 0 and #queue > 0 do
		local key = table.remove(queue)
		queued[key] = nil
		local axis = key % 2
		local cx, cy = columnFromKey((key - axis) / 2)
		local edge, used = evaluate(key, cx, cy, axis)
		setEdge(key, edge)
		budget = budget - math.max(used, 0.05)
	end
end

local function vertex(lane, v)
	vertexPos:SetUnpacked(lane.x, lane.y, lane.top)
	mesh.Position(vertexPos)
	mesh.TexCoord(0, lane.bottom, lane.code)
	mesh.Color(lane.r, lane.g, lane.b, v)
	mesh.AdvanceVertex()
end

local function buildTile(t)
	destroyTile(t)
	t.dirty = false

	local list, streams = {}, {}
	for _, edge in pairs(t.edges) do
		for _, lane in ipairs(edge.lanes) do
			if #list < MAX_TILE_LANES then
				list[#list + 1] = lane
				if lane.stream then streams[#streams + 1] = lane end
			end
		end
	end

	t.lanes, t.streams = list, streams
	if #list == 0 then return end

	local m = Mesh()
	mesh.Begin(m, MATERIAL_QUADS, #list * (ROWS + 1))
	for _, lane in ipairs(list) do
		for row = 0, ROWS - 1 do
			vertex(lane, row * 2)
			vertex(lane, row * 2 + 1)
			vertex(lane, row * 2 + 3)
			vertex(lane, row * 2 + 2)
		end

		for corner = 0, 3 do
			vertex(lane, SPLASH_CODE + corner)
		end
	end

	mesh.End()
	t.mesh = m
end

local function tileDistance(key, eye)
	local tx, ty = columnFromKey(key)
	local x = math.Clamp(eye.x, tx * TILE, (tx + 1) * TILE)
	local y = math.Clamp(eye.y, ty * TILE, (ty + 1) * TILE)

	return math.sqrt((x - eye.x) ^ 2 + (y - eye.y) ^ 2)
end

local function updateTiles(eye, now)
	local budget = REBUILDS
	for _, t in pairs(tiles) do
		if budget <= 0 then break end
		if t.dirty then
			buildTile(t)
			budget = budget - 1
		end
	end

	if now < nextEvict then return end

	nextEvict = now + EVICT_INTERVAL
	for key, t in pairs(tiles) do
		if tileDistance(key, eye) > KEEP_RANGE then
			for edgeKey in pairs(t.edges) do
				edges[edgeKey] = nil
			end

			destroyTile(t)
			tiles[key] = nil
		end
	end
end

local function playLanding(lane)
	local volume = soundVolume()
	if volume <= 0 or soundTokens < 1 then return end

	soundTokens = soundTokens - 1
	local list = lane.water and WATER_SOUNDS or GROUND_SOUNDS
	samplePos:SetUnpacked(lane.sx, lane.sy, lane.bottom)
	sound.Play(list[math.random(#list)], samplePos, SOUND_LEVEL, math.random(90, 110), SOUND_VOLUME * volume * drain)
end

local function laneSounds(lane, from, to)
	if lane.stream then return end

	local p, tau = lane.period, lane.tauFall
	for slot = math.floor((from - tau) / p), math.floor((to - tau) / p) do
		local first = slot * p + tau
		if first <= to and first + RELEASE_JITTER * p > from then
			local active, jitter = hash3(slot, lane.seed)
			if active < drain then
				local landed = first + RELEASE_JITTER * jitter * p
				if landed > from and landed <= to then
					playLanding(lane)
				end
			end
		end
	end
end

local function sounds(eye, from, to)
	if to <= from then return end

	local range2 = SOUND_RANGE * SOUND_RANGE
	for key, t in pairs(tiles) do
		if t.lanes and tileDistance(key, eye) < SOUND_RANGE then
			for _, lane in ipairs(t.lanes) do
				local dx, dy, dz = lane.sx - eye.x, lane.sy - eye.y, lane.bottom - eye.z
				if dx * dx + dy * dy + dz * dz < range2 then
					laneSounds(lane, from, to)
				end
			end
		end
	end
end

local function nearestStreams(eye)
	local near, dist = streamNear, streamDist
	for i = 1, STREAM_SOUNDS + 1 do
		near[i], dist[i] = nil, nil
	end

	local range2 = STREAM_RANGE * STREAM_RANGE
	for key, t in pairs(tiles) do
		if t.streams and tileDistance(key, eye) < STREAM_RANGE then
			for _, lane in ipairs(t.streams) do
				local dx, dy, dz = lane.sx - eye.x, lane.sy - eye.y, lane.bottom - eye.z
				local d2 = dx * dx + dy * dy + dz * dz
				if d2 < range2 then
					local i = #near + 1
					while i > 1 and dist[i - 1] > d2 do
						near[i], dist[i] = near[i - 1], dist[i - 1]
						i = i - 1
					end

					near[i], dist[i] = lane, d2
					near[STREAM_SOUNDS + 1], dist[STREAM_SOUNDS + 1] = nil, nil
				end
			end
		end
	end

	return near
end

local function silenceStreams()
	for _, slot in ipairs(streamSlots) do
		if slot.patch then slot.patch:Stop() end
		slot.lane = nil
	end
end

local function removeStreams()
	silenceStreams()
	for _, slot in ipairs(streamSlots) do
		if IsValid(slot.ent) then slot.ent:Remove() end
	end

	streamSlots = {}
end

local function streamSounds(eye, now)
	local volume = math.min(STREAM_VOLUME * soundVolume() * drain, 1)
	if now >= nextStreamPick then
		nextStreamPick = now + STREAM_PICK_INTERVAL
		nearestStreams(eye)
	end

	local near = streamNear
	for i = 1, STREAM_SOUNDS do
		local slot, lane = streamSlots[i], near[i]
		if lane then
			if not slot then
				slot = {}
				streamSlots[i] = slot
			end

			if not IsValid(slot.ent) then
				slot.ent = ClientsideModel(STREAM_MODEL)
				slot.ent:SetNoDraw(true)
				slot.patch, slot.lane = nil, nil
			end

			if slot.lane ~= lane then
				slot.lane = lane
				samplePos:SetUnpacked(lane.sx, lane.sy, lane.bottom + STREAM_LIFT)
				slot.ent:SetPos(samplePos)
			end

			if not slot.patch then
				slot.patch = CreateSound(slot.ent, STREAM_SOUND)
				slot.patch:SetSoundLevel(STREAM_LEVEL)
			end

			if slot.patch:IsPlaying() then
				slot.patch:ChangeVolume(volume)
			else
				slot.patch:PlayEx(volume, STREAM_PITCH + lane.seed % STREAM_PITCH_SPREAD)
			end
		elseif slot and slot.patch then
			slot.patch:Stop()
			slot.lane = nil
		end
	end
end

local function ease(value, target, dt)
	if target > value then return math.min(target, value + DRAIN_RISE * dt) end

	return math.max(target, value - DRAIN_FALL * dt)
end

local function think()
	local rain = tod and tod.rain and tod.rain.amount or 0
	drain = ease(drain, rain, RealFrameTime())
	soundTokens = math.min(soundTokens + SOUND_RATE * FrameTime(), SOUND_RATE)

	local time = CurTime() % WRAP
	local from = lastTime or time
	lastTime = time
	if drain <= DRAIN_MIN then return silenceStreams() end

	local eye = EyePos()
	if not cover.Update(eye) then return end

	if not seeded then seed() end
	processQueue()
	local now = RealTime()
	updateTiles(eye, now)
	sounds(eye, from, time)
	streamSounds(eye, now)
end

local function draw(bDepth, _, b3DSky)
	if bDepth or b3DSky or render.GetRenderTarget() then return end
	if drain <= DRAIN_MIN or not MAT then return end

	local eye = EyePos()
	local tonemap = shaderpack.ToneMapScale()
	local fr, fg, fb = render.GetFogColor()
	fr, fg, fb = fr / 255, fg / 255, fb / 255

	MAT:SetTexture("$basetexture", dynamiclights.Texture() or "vgui/black")
	MAT:SetTexture("$texture1", dynamiclights.ProjectedTexture() or "vgui/black")
	setConstant(MAT, "$c0", eye.x, eye.y, eye.z, CurTime() % WRAP)
	setConstant(MAT, "$c1", ALPHA * tonemap, drain, locallights.Scale() * tonemap * LIT, tonemap * LIT)
	setConstant(MAT, "$c2", packColor(fr * COLOR_BODY, fg * COLOR_BODY, fb * COLOR_BODY),
		packColor(math.max(fr * COLOR_HEAD, COLOR_HEAD_FLOOR), math.max(fg * COLOR_HEAD, COLOR_HEAD_FLOOR), math.max(fb * COLOR_HEAD, COLOR_HEAD_FLOOR)))

	local vs = render.GetViewSetup()
	local strength = SLANT * wind.Strength()
	local r = rows[1]
	r[1], r[2], r[3] = 2 * math.tan(math.rad(vs.fov) * 0.5) / vs.width, -wind.X * strength, -wind.Y * strength
	setVertexConstants(rows)

	render.SetMaterial(MAT)
	for key, t in pairs(tiles) do
		if t.mesh and tileDistance(key, eye) < DRAW_RANGE then
			t.mesh:Draw()
		end
	end
end

local function stop()
	cover.Unlisten("borealis_drips")
	hook.Remove("Think", "borealis_drips")
	hook.Remove("PostDrawTranslucentRenderables", "borealis_drips")
	reset()
	removeStreams()
	lastTime = nil
end

local function start()
	stop()
	MAT = CreateShaderMaterial("borealis_drip_" .. os.time(), {
		["$pixshader"] = DRIP_PS,
		["$vertexshader"] = DRIP_VS,
		["$linearread_basetexture"] = 1,
		["$linearread_texture1"] = 1,
		["$ignorez"] = 0,
		["$depthtest"] = 1,
		["$additive"] = 0,
		["$linearwrite"] = 0,
		["$nocull"] = 1,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
	})
	cover.Listen("borealis_drips", onColumn, reset)
	hook.Add("Think", "borealis_drips", think)
	hook.Add("PostDrawTranslucentRenderables", "borealis_drips", draw)
end

shaderpack.Toggle("borealis_drips", ENABLED, SHADERS, start, stop)()
