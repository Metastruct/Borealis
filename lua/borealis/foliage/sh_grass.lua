if SERVER then
	shaderpack.AddResources({ "borealis_grass_vs30", "borealis_grass_ps30", "borealis_grassdepth_ps30" })

	return
end

local foliage, wind = shaderpack.foliage, shaderpack.wind
local GRASS_ENABLED = CreateClientConVar("borealis_grass", "0", true, false, "draw grass tufts on grass surfaces")
local GRASS_DISTANCE = CreateClientConVar("borealis_grass_distance", "3072", true, false, "grass draw distance in units", 1024, 16384)

local WINTER = shaderpack.Season() == "winter"
local AUTUMN = false
local DENSITY, HEIGHT, DRYNESS, ROOT_COLOR, TIP_COLOR, DRY_COLOR

local function setSeason(winter, autumn)
	WINTER, AUTUMN = winter, autumn
	DENSITY = winter and 0.35 or 1
	HEIGHT = winter and 0.7 or 1
	DRYNESS = winter and 1 or autumn and 0.6 or 0.15
	ROOT_COLOR = winter and { 0.09, 0.085, 0.06 } or autumn and { 0.07, 0.06, 0.02 } or { 0.06, 0.075, 0.02 }
	TIP_COLOR = autumn and { 0.13, 0.15, 0.045 } or { 0.15, 0.19, 0.05 }
	DRY_COLOR = winter and { 0.28, 0.25, 0.17 } or autumn and { 0.32, 0.2, 0.06 } or { 0.24, 0.21, 0.09 }
end

setSeason(WINTER, AUTUMN)

local MAX_SLOPE_Z = 0.7
local CURL, CURL_MAX = 1.5, 0.45
local LEAN = 0.5
local LEAN_MAX = 0.95
local QUAD_H = 40
local TRANSLUCENCY = 0.35
local TRAMPLE_SLICES = { 10, 24, 40, 64 }

local packColor, setConstant = shaderpack.PackColor, shaderpack.SetConstant

local basePos = Vector()
local function keep(x, y, z, r)
	if r > DENSITY then return false end
	basePos:SetUnpacked(x, y, z + 1)

	return bit.band(util.PointContents(basePos), MASK_WATER) == 0
end

local lastWet = 0
local function palette(mat, depthMat)
	mat:SetFloat("$c1_x", wind.HEADING)
	setConstant(mat, "$c2", nil, packColor(unpack(ROOT_COLOR)), packColor(unpack(TIP_COLOR)))
	setConstant(mat, "$c3", TRANSLUCENCY, DRYNESS, packColor(unpack(DRY_COLOR)))
	if depthMat then
		depthMat:SetFloat("$c1_x", wind.HEADING)
	end

	lastWet = -1
end

local PUSH_SLOTS = 5
local PUSH_RANGE = 1536
local PUSH_GATHER_INTERVAL = 0.25
local PUSH_STEP = 32
local PUSH_LIFE = 2.5
local PUSH_MIN_SPEED = 20
local PUSH_PAD = 32
local PUSH_MAX_RADIUS = 127
local PUSH_MAX_POINTS = 128
local PUSH_HEAD_FADE = 0.35
local PUSH_ATTACK = 0.3
local PUSH_EVICT = 0.4

local pushCandidates, nextPushGather = {}, 0
local pushTracks = {}
local pushPoints = {}
local pushSlots = {}
local pushFrame, pushTime = -1, 0

local function pushable(e)
	if not IsValid(e) or e:IsDormant() or e:GetNoDraw() or IsValid(e:GetParent()) then return false end
	if e:IsPlayer() then return e:Alive() and not e:InVehicle() end

	return (e:GetModel() or ""):sub(-4):lower() == ".mdl"
end

local function gatherPushers(eye)
	local now = RealTime()
	if now < nextPushGather then return end
	nextPushGather = now + PUSH_GATHER_INTERVAL

	pushCandidates = {}
	local keep = {}
	for _, e in ipairs(ents.FindInSphere(eye, PUSH_RANGE)) do
		if pushable(e) then
			pushCandidates[#pushCandidates + 1] = e
			keep[e] = pushTracks[e]
		end
	end
	pushTracks = keep
end

local function placePoint(point, mins, maxs)
	point.x, point.y, point.z = (mins.x + maxs.x) * 0.5, (mins.y + maxs.y) * 0.5, mins.z
	point.r = math.min(math.max(maxs.x - mins.x, maxs.y - mins.y) * 0.5 + PUSH_PAD, PUSH_MAX_RADIUS)
end

local function approach(v, target, step)
	if v < target then return math.min(v + step, target) end

	return math.max(v - step, target)
end

local function updatePoints(now, dt)
	for _, point in ipairs(pushPoints) do
		point.active = false
	end

	for _, e in ipairs(pushCandidates) do
		if pushable(e) then
			local pos = e:GetPos()
			local track = pushTracks[e]
			if not track then
				track = { pos = pos, trail = pos, speed = 0 }
				pushTracks[e] = track
			end

			local speed = dt > 0 and pos:Distance(track.pos) / dt or 0
			track.speed = track.speed + (speed - track.speed) * 0.3
			track.pos = pos

			if e:IsPlayer() or e:IsNPC() or e:IsNextBot() or track.speed > PUSH_MIN_SPEED then
				local mins, maxs = e:WorldSpaceAABB()
				local head = track.head
				if not head or head.dead then
					head = { head = true, strength = 0 }
					track.head = head
					pushPoints[#pushPoints + 1] = head
				end
				placePoint(head, mins, maxs)
				head.active = true

				local dx, dy = pos.x - track.trail.x, pos.y - track.trail.y
				if dx * dx + dy * dy > PUSH_STEP * PUSH_STEP then
					track.trail = pos
					if #pushPoints < PUSH_MAX_POINTS then
						local trailPoint = { born = now, strength = 1 }
						placePoint(trailPoint, mins, maxs)
						pushPoints[#pushPoints + 1] = trailPoint
					end
				end
			end
		end
	end

	for i = #pushPoints, 1, -1 do
		local point = pushPoints[i]
		if point.head then
			point.strength = approach(point.strength, point.active and 1 or 0, dt / PUSH_HEAD_FADE)
			point.dead = not point.active and point.strength <= 0
		else
			local age = math.min((now - point.born) / PUSH_LIFE, 1)
			point.strength = 1 - age * age * (3 - 2 * age)
			point.dead = age >= 1
		end

		if point.dead then table.remove(pushPoints, i) end
	end
end

local function rankPoints(eye)
	local ranked = {}
	for _, point in ipairs(pushPoints) do
		if point.strength > 0 then
			local dx, dy, dz = point.x - eye.x, point.y - eye.y, point.z - eye.z
			point.score = point.strength * (point.head and 2 or 1) / (1 + math.sqrt(dx * dx + dy * dy + dz * dz) / 256)
			ranked[#ranked + 1] = point
		end
	end
	table.sort(ranked, function(a, b) return a.score > b.score end)

	local wanted = {}
	for i = 1, math.min(PUSH_SLOTS, #ranked) do
		wanted[ranked[i]] = true
	end

	return ranked, wanted
end

local function updatePushers(eye)
	local frameNumber = FrameNumber()
	if frameNumber == pushFrame then return end
	pushFrame = frameNumber

	local now = RealTime()
	local dt = math.min(now - pushTime, 0.1)
	pushTime = now
	gatherPushers(eye)
	updatePoints(now, dt)

	local ranked, wanted = rankPoints(eye)
	local assigned = {}
	for i = 1, PUSH_SLOTS do
		local slot = pushSlots[i]
		if slot then
			local point = slot.point
			if wanted[point] and not point.dead then
				slot.shown = math.min(slot.shown + dt / PUSH_ATTACK, point.strength)
				assigned[point] = true
			else
				slot.shown = math.max(math.min(slot.shown - dt / PUSH_EVICT, point.strength), 0)
				if slot.shown <= 0 then pushSlots[i] = nil end
			end
		end
	end

	local nextPoint = 1
	for i = 1, PUSH_SLOTS do
		if not pushSlots[i] then
			while ranked[nextPoint] and (assigned[ranked[nextPoint]] or not wanted[ranked[nextPoint]]) do
				nextPoint = nextPoint + 1
			end

			local point = ranked[nextPoint]
			if not point then break end

			assigned[point] = true
			pushSlots[i] = { point = point, shown = 0 }
		end
	end
end

local vertexRows = { {}, {}, {}, {}, {}, {} }
local function frame(mat, depthMat, time)
	local strength = wind.Strength()
	local curl = math.min(CURL * strength, CURL_MAX)
	mat:SetFloat("$c1_z", curl)
	if depthMat then
		depthMat:SetFloat("$c1_z", curl)
	end

	local r = vertexRows
	r[1][1], r[1][2], r[1][3] = time, LEAN * strength, QUAD_H * HEIGHT
	updatePushers(EyePos())
	local used = 0
	for i = 1, PUSH_SLOTS do
		local slot = pushSlots[i]
		if slot and slot.shown > 0.002 then
			used = used + 1
			local p, row = slot.point, r[used + 1]
			row[1], row[2], row[3] = p.x, math.floor(p.y) + p.r / 128, math.floor(p.z) + slot.shown * 0.99
		end
	end
	for i = used + 1, PUSH_SLOTS do
		local row = r[i + 1]
		row[1], row[2], row[3] = 0, 0, 0
	end
	shaderpack.SetVertexConstants(r)

	local wet = tod and tod.rain and tod.rain.amount or 0
	if wet == lastWet then return end
	lastWet = wet
	local k = 1 - 0.3 * wet
	setConstant(mat, "$c2", nil, packColor(ROOT_COLOR[1] * k, ROOT_COLOR[2] * k, ROOT_COLOR[3] * k), packColor(TIP_COLOR[1] * k, TIP_COLOR[2] * (1 - 0.2 * wet), TIP_COLOR[3] * k))
	mat:SetFloat("$c3_z", packColor(DRY_COLOR[1] * k, DRY_COLOR[2] * k, DRY_COLOR[3] * k))
end

local layer = foliage.Layer({
	name = "grass",
	pixelShader = "borealis_grass_ps30", vertexShader = "borealis_grass_vs30", depthShader = "borealis_grassdepth_ps30",
	classify = foliage.SurfaceClassifier({ grass = true }, { "grass" }), minNormalZ = MAX_SLOPE_Z,
	spacing = 18, jitter = 8, quadW = 26, quadH = QUAD_H,
	sway = QUAD_H * 1.4 * LEAN_MAX,
	keep = keep, palette = palette, frame = frame, engineLights = true, skybox = true,
	trails = {
		channel = 2,
		slices = TRAMPLE_SLICES,
		live = true,
		accept = function() return true end,
	},
})
layer.height = HEIGHT

local function setDistance()
	layer:SetDistance(math.Clamp(GRASS_DISTANCE:GetInt(), 1024, 16384))
end

setDistance()

local apply = shaderpack.Toggle("borealis_grass", GRASS_ENABLED, { "borealis_grass_ps30", "borealis_grass_vs30", "borealis_trailstamp_ps30" }, function() layer:Start() end, function() layer:Stop() end)

cvars.RemoveChangeCallback("borealis_grass_distance", "borealis_grass")
cvars.AddChangeCallback("borealis_grass_distance", setDistance, "borealis_grass")

hook.Add("TOD_WinterRemoved", "borealis_grass", function()
	if not WINTER then return end
	setSeason(false, AUTUMN)
	layer.height = HEIGHT
	apply()
end)

hook.Add("TOD_Autumn", "borealis_grass", function()
	if WINTER or AUTUMN then return end
	setSeason(false, true)
	if layer.mat then
		layer.mat:SetFloat("$c3_y", DRYNESS)
		lastWet = -1
	end
end)

shaderpack.AfterWorld("borealis_grass", function()
	setSeason(shaderpack.Season() == "winter", AUTUMN)
	layer.height = HEIGHT
	apply()
end)
