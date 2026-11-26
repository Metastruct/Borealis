local wakes = shaderpack.wakes or {}
shaderpack.wakes = wakes

local SIM_PS = "borealis_wakesim_ps30"
wakes.SIM_PS = SIM_PS

local TEXELS, TEXEL = 1024, 4
local SPAN = TEXELS * TEXEL
local RECENTRE_STEP = 64
local RATE = 30
local MAX_STEPS = 3
local SLEEP = 30
local CANDIDATE_INTERVAL = 0.25
local SUBMERGED = 8
local SURFACE_CELL = 64
local SURFACE_BAND = 512
local POLY_SIDES = 20
local SPLASH_MAX_RINGS = 16
local CAPTURE_LIFT = 64
local SWEEP_STEPS = 8
local SWEEP_MAX = 512
local HULL_MARGIN = 16
local HULL_LIFT = 4
local SKIM_SOUNDS = { "vehicles/airboat/pontoon_fast_water_loop1.wav", "vehicles/airboat/pontoon_fast_water_loop2.wav" }
local SOUND_MAX = 4
local SOUND_LEVEL = 75
local SOUND_FADE = 3
local SPRAY_MAT = "effects/splash4"
local SPRAY_REF_SIZE = 24
local SPRAY_MAX_PER_FRAME = 16
local SPRAY_GRAVITY = Vector(0, 0, -900)
local SPRAY_ALBEDO = 0.45
local SPRAY_NEUTRAL = 0.6
local SPRAY_AMBIENT_FILL = 0.5
local SPRAY_UP = Vector(0, 0, 1)

local CONFIG = {
	speed = 0.4,
	damping = 0.99,
	depth = 1,
	foamDecay = 0.985,
	splash = 8,
	splashFoam = 1.5,
	splashMin = 150,
	splashSpeed = 800,
	splashSpread = 2.5,
	skimMin = 120,
	skimFull = 800,
	skimRate = 180,
	skimLift = 0.35,
	skimThrow = 0.3,
	skimCarry = 0.6,
	skimFoam = 0.8,
}

local toLinear, setConstant = shaderpack.ToLinear, shaderpack.SetConstant

local stateRTs, forceRT, simMats = {}, nil, nil
local cur, winX, winY = 1, nil, nil
local simTime, lastActive = 0, -math.huge
local candidates, nextCandidates = {}, 0
local tracked, splashes, surfaces = {}, {}, {}
local probe = Vector()
local emitter, stampMat
local capturing = false
local sounds = {}

local function linearByte(v)
	local c, err = 0, math.huge
	for b = 0, 255 do
		local e = math.abs(toLinear(b) - v)
		if e > err then break end
		c, err = b, e
	end

	return c
end

local function floats(e)
	if not IsValid(e) or e:IsDormant() then return false end
	if e:IsPlayer() then return e:Alive() and not e:InVehicle() end
	if e:IsWeapon() or IsValid(e:GetParent()) then return false end

	local model = e:GetModel()
	if not model or model:sub(-4):lower() ~= ".mdl" then return false end

	local class = e:GetClass()

	return class ~= "viewmodel" and class ~= "predicted_viewmodel"
end

local scanCorner = Vector(SPAN / 2, SPAN / 2, SPAN / 2)

local function findCandidates(eye)
	local now = RealTime()
	if now < nextCandidates then return end
	nextCandidates = now + CANDIDATE_INTERVAL

	candidates = {}
	for _, e in ipairs(ents.FindInBox(eye - scanCorner, eye + scanCorner)) do
		if floats(e) then candidates[#candidates + 1] = e end
	end
end

local function surfaceAt(x, y, bottom, top)
	local water = shaderpack.surfacewater
	probe:SetUnpacked(x, y, bottom + 1)
	if not water.IsUnderwater(probe) then return end

	local key = math.floor(x / SURFACE_CELL) .. ":" .. math.floor(y / SURFACE_CELL) .. ":" .. math.floor(bottom / SURFACE_BAND)
	local z = surfaces[key]
	if not z then
		z = water.SurfaceZ(probe)
		surfaces[key] = z
	end
	if top < z - SUBMERGED then return end

	return z
end


local function toGamma(c)
	c = math.max(c, 0)

	return math.min(math.floor((c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055) * 255 + 0.5), 255)
end

local function sprayColor(pos)
	local foliage = shaderpack.foliage
	local scale = foliage and foliage.WorldLightScale and foliage.WorldLightScale() or 1
	local tonemap = shaderpack.ToneMapScale()
	local l, d = render.ComputeLighting(pos, SPRAY_UP), render.ComputeDynamicLighting(pos, SPRAY_UP)
	local amb = render.GetAmbientLightColor()

	local r, g, b = toGamma(((l.x - d.x) * scale + amb.x * SPRAY_AMBIENT_FILL) * tonemap * SPRAY_ALBEDO),
		toGamma(((l.y - d.y) * scale + amb.y * SPRAY_AMBIENT_FILL) * tonemap * SPRAY_ALBEDO),
		toGamma(((l.z - d.z) * scale + amb.z * SPRAY_AMBIENT_FILL) * tonemap * SPRAY_ALBEDO)
	local luma = 0.2126 * r + 0.7152 * g + 0.0722 * b

	return Lerp(SPRAY_NEUTRAL, r, luma), Lerp(SPRAY_NEUTRAL, g, luma), Lerp(SPRAY_NEUTRAL, b, luma)
end

local function sprayEmitter(x, y, z)
	local pos = Vector(x, y, z + 8)
	if not IsValid(emitter) then emitter = ParticleEmitter(pos) end
	if not emitter then return end
	emitter:SetPos(pos)

	return pos
end

local function sprite(px, py, pz, vx, vy, vz, size, alpha, r, g, b)
	local p = emitter:Add(SPRAY_MAT, Vector(px, py, pz))
	if not p then return end

	p:SetVelocity(Vector(vx, vy, vz))
	p:SetGravity(SPRAY_GRAVITY)
	p:SetAirResistance(150)
	p:SetDieTime(0.35 + math.random() * 0.25)
	p:SetStartAlpha(alpha)
	p:SetEndAlpha(0)
	p:SetStartSize(size * 0.2)
	p:SetEndSize(size)
	p:SetRoll(math.random() * 360)
	p:SetRollDelta((math.random() - 0.5) * 2)
	p:SetColor(r, g, b)
end

local function hullExtents(e, dx, dy)
	local mins, maxs = e:OBBMins(), e:OBBMaxs()
	local ex, ey = (maxs.x - mins.x) * 0.5, (maxs.y - mins.y) * 0.5
	local f, r = e:GetForward(), e:GetRight()
	local along = ex * math.abs(f.x * dx + f.y * dy) + ey * math.abs(r.x * dx + r.y * dy)
	local across = ex * math.abs(f.x * dy - f.y * dx) + ey * math.abs(r.x * dy - r.y * dx)

	return e:LocalToWorld(e:OBBCenter()), along, across
end

local hullRes = {}
local hullTrace = { start = Vector(), endpos = Vector(), mask = MASK_ALL, ignoreworld = true, output = hullRes, whitelist = true }

local function hullPoint(e, cx, cy, sx, sy, across, z)
	if e:GetSolid() == SOLID_NONE then return cx + sx * across, cy + sy * across end

	local reach = across + HULL_MARGIN
	hullTrace.start:SetUnpacked(cx + sx * reach, cy + sy * reach, z + HULL_LIFT)
	hullTrace.endpos:SetUnpacked(cx, cy, z + HULL_LIFT)
	util.TraceLine(hullTrace)
	if not hullRes.Hit or hullRes.Entity ~= e or hullRes.StartSolid then return end

	return hullRes.HitPos.x, hullRes.HitPos.y
end

local function skim(e, track, nextTrack, pos, now, z)
	local dt = now - track.time
	if dt <= 0 then return end

	local vx, vy, vz = (pos.x - track.pos.x) / dt, (pos.y - track.pos.y) / dt, (pos.z - track.pos.z) / dt
	local speed = math.sqrt(vx * vx + vy * vy)
	local energy = math.Clamp((speed - CONFIG.skimMin) / (CONFIG.skimFull - CONFIG.skimMin), 0, 1)
	nextTrack.foam = energy * CONFIG.skimFoam
	if energy <= 0 then return end

	local dx, dy = vx / speed, vy / speed
	local centre, along, across = hullExtents(e, dx, dy)
	local scale = math.Clamp(across / SPRAY_REF_SIZE, 0.5, 3)
	nextTrack.energy, nextTrack.scale = energy, scale
	local due = (track.due or 0) + CONFIG.skimRate * energy * scale * dt
	local count = math.floor(due)
	nextTrack.due = due - count
	if count == 0 then return end

	local origin = sprayEmitter(centre.x, centre.y, z)
	if not origin then return end

	local r, g, b = sprayColor(origin)
	local carry = CONFIG.skimCarry
	hullTrace.filter = e
	for _ = 1, math.min(count, SPRAY_MAX_PER_FRAME) do
		local side = math.random() < 0.5 and -1 or 1
		local sx, sy = dy * side, -dx * side
		local at = along * (math.sqrt(math.random()) * 1.1 - 0.2)
		local hx, hy = hullPoint(e, centre.x + dx * at, centre.y + dy * at, sx, sy, across, z)
		if not hx then continue end

		local out = speed * CONFIG.skimThrow * (0.5 + math.random())
		local up = speed * CONFIG.skimLift * (0.5 + math.random())
		sprite(hx, hy, z + 1,
			vx * carry + sx * out, vy * carry + sy * out, vz * carry + up,
			(20 + math.random() * 20) * scale, 60 + 140 * energy, r, g, b)
	end
end

local function queueSplash(e, track, pos, now)
	local dt = now - track.time
	if dt <= 0 then return end

	local fall = (track.pos.z - pos.z) / dt
	if fall < CONFIG.splashMin then return end

	local mins, maxs = e:WorldSpaceAABB()
	local r = math.max(maxs.x - mins.x, maxs.y - mins.y) * 0.5 * CONFIG.splashSpread
	splashes[#splashes + 1] = { x = (mins.x + maxs.x) * 0.5, y = (mins.y + maxs.y) * 0.5, r = r, v = math.min(fall / CONFIG.splashSpeed, 1) * CONFIG.splash }
end

local function updateTracked()
	local now = RealTime()
	local seen = {}
	for _, e in ipairs(candidates) do
		if IsValid(e) and floats(e) then
			seen[e] = true
			local track = tracked[e]
			local pos, ang = e:GetPos(), e:GetAngles()
			if not track or track.pos ~= pos or track.ang ~= ang then
				local mins, maxs = e:WorldSpaceAABB()
				local wet = surfaceAt((mins.x + maxs.x) * 0.5, (mins.y + maxs.y) * 0.5, mins.z, maxs.z)
				local nextTrack = { pos = pos, ang = ang, time = now, wet = wet }
				if wet and track then
					if track.wet then
						skim(e, track, nextTrack, pos, now, wet)
					else
						queueSplash(e, track, pos, now)
					end
				end
				tracked[e] = nextTrack
				if wet or (track and track.wet) then lastActive = now end
			else
				track.foam, track.energy = nil, nil
			end
		end
	end

	for e, track in pairs(tracked) do
		if not seen[e] then
			if track.wet then lastActive = now end
			tracked[e] = nil
		end
	end
end

local shifted = {}

local function drawWrapped(poly, minX, minY, maxX, maxY)
	local baseX = math.floor((minX + maxX) * 0.5 / TEXELS) * TEXELS
	local baseY = math.floor((minY + maxY) * 0.5 / TEXELS) * TEXELS
	for ox = -1, 1 do
		for oy = -1, 1 do
			local dx, dy = ox * TEXELS - baseX, oy * TEXELS - baseY
			if maxX + dx >= 0 and minX + dx < TEXELS and maxY + dy >= 0 and minY + dy < TEXELS then
				for i, p in ipairs(poly) do
					local s = shifted[i] or {}
					shifted[i] = s
					s.x, s.y = p.x + dx, p.y + dy
				end
				for i = #shifted, #poly + 1, -1 do
					shifted[i] = nil
				end
				surface.DrawPoly(shifted)
			end
		end
	end
end

local function inWindow(minX, minY, maxX, maxY)
	return maxX >= winX and minX < winX + TEXELS and maxY >= winY and minY < winY + TEXELS
end

local function eachRTRect(X0, Y0, w, h, fn)
	local px, py = X0 % TEXELS, Y0 % TEXELS
	local w1, h1 = math.min(w, TEXELS - px), math.min(h, TEXELS - py)
	fn(px, py, w1, h1, 0, 0)
	if w1 < w then fn(0, py, w - w1, h1, w1, 0) end
	if h1 < h then fn(px, 0, w1, h - h1, 0, h1) end
	if w1 < w and h1 < h then fn(0, 0, w - w1, h - h1, w1, h1) end
end

local captureView = { type = "3D", origin = Vector(), angles = Angle(90, 90, 0), znear = 1, zfar = 1, ortho = {} }
local clipNormal = Vector(0, 0, -1)
local shot = {}
local stamped = {}

local function captureRect(px, py, w, h, ox, oy)
	local hw, hh = w * TEXEL * 0.5, h * TEXEL * 0.5
	captureView.x, captureView.y, captureView.w, captureView.h = px, py, w, h
	local cx, cy, cz = (shot.X0 + ox) * TEXEL + hw, -((shot.Y0 + oy) * TEXEL + hh), shot.top + CAPTURE_LIFT
	local ortho = captureView.ortho
	ortho.left, ortho.right, ortho.top, ortho.bottom = -hw, hw, -hh, hh
	local e, foam = shot.e, shot.foam

	render.SetColorModulation(0, foam, 0)
	for k = 1, shot.sweeps do
		local back = 1 - k / (shot.sweeps + 1)
		captureView.origin:SetUnpacked(cx + shot.dx * back, cy + shot.dy * back, cz)
		cam.Start(captureView)
		e:DrawModel()
		cam.End()
	end

	render.SetColorModulation(1, foam, 0)
	captureView.origin:SetUnpacked(cx, cy, cz)
	cam.Start(captureView)
	e:DrawModel()
	cam.End()
end

local corner = Vector()

local function renderBox(e)
	local lo, hi = e:GetRenderBounds()
	local minX, minY, minZ, maxX, maxY, maxZ = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
	for i = 0, 7 do
		corner:SetUnpacked(bit.band(i, 1) == 0 and lo.x or hi.x, bit.band(i, 2) == 0 and lo.y or hi.y, bit.band(i, 4) == 0 and lo.z or hi.z)
		local p = e:LocalToWorld(corner)
		minX, minY, minZ = math.min(minX, p.x), math.min(minY, p.y), math.min(minZ, p.z)
		maxX, maxY, maxZ = math.max(maxX, p.x), math.max(maxY, p.y), math.max(maxZ, p.z)
	end

	return minX, minY, minZ, maxX, maxY, maxZ
end

local function stamp(e, z, foam)
	local minX, minY, minZ, maxX, maxY, maxZ = renderBox(e)
	local pos = e:GetPos()
	local from = stamped[e]
	stamped[e] = pos

	shot.sweeps = 0
	if foam > 0 and from then
		local ox, oy = from.x - pos.x, from.y - pos.y
		local step = math.max(math.min(maxX - minX, maxY - minY) * 0.5, TEXEL * 2)
		local dist = math.sqrt(ox * ox + oy * oy)
		if dist > step and dist < SWEEP_MAX then
			shot.sweeps = math.min(math.ceil(dist / step) - 1, SWEEP_STEPS)
			shot.dx, shot.dy = -ox, -oy
			minX, maxX = math.min(minX, minX + ox), math.max(maxX, maxX + ox)
			minY, maxY = math.min(minY, minY + oy), math.max(maxY, maxY + oy)
		end
	end

	local X0, Y0 = math.floor(minX / TEXEL) - 1, math.floor(-maxY / TEXEL) - 1
	local w = math.min(math.ceil(maxX / TEXEL) + 1 - X0, TEXELS)
	local h = math.min(math.ceil(-minY / TEXEL) + 1 - Y0, TEXELS)
	if not inWindow(X0, Y0, X0 + w, Y0 + h) then return end

	shot.e, shot.foam, shot.X0, shot.Y0, shot.top = e, foam, X0, Y0, maxZ
	captureView.zfar = maxZ - minZ + CAPTURE_LIFT * 2
	render.PushCustomClipPlane(clipNormal, -z)
	eachRTRect(X0, Y0, w, h, captureRect)
	render.PopCustomClipPlane()
end

local function drawFootprints()
	render.PushRenderTarget(forceRT)
	render.Clear(0, 0, 0, 0)
	render.MaterialOverride(stampMat)
	render.SuppressEngineLighting(true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	local clipping = render.EnableClipping(true)
	capturing = true
	for e, track in pairs(tracked) do
		if track.wet and IsValid(e) then
			local override = e.RenderOverride
			e.RenderOverride = nil
			local ok, err = pcall(stamp, e, track.wet, track.foam or 0)
			e.RenderOverride = override
			if not ok then ErrorNoHalt("[wakes] capture: " .. tostring(err) .. "\n") end
		else
			stamped[e] = nil
		end
	end
	for e in pairs(stamped) do
		if not tracked[e] then stamped[e] = nil end
	end
	capturing = false
	render.EnableClipping(clipping)
	render.OverrideBlend(false)
	render.SetColorModulation(1, 1, 1)
	render.SuppressEngineLighting(false)
	render.MaterialOverride()
	render.PopRenderTarget()
end

local levelBytes = {}

local function levelByte(v)
	local key = math.floor(math.Clamp(v, 0, 1) * 1023 + 0.5)
	local b = levelBytes[key]
	if not b then
		b = linearByte(key / 1023)
		levelBytes[key] = b
	end

	return b
end

local function discPoly(cx, cy, r)
	local poly = {}
	for i = 1, POLY_SIDES do
		local a = i / POLY_SIDES * math.pi * 2
		poly[i] = { x = cx + math.cos(a) * r, y = cy + math.sin(a) * r }
	end

	return poly
end

local function drawSplashes()
	if #splashes == 0 then return end

	lastActive = RealTime()
	render.PushRenderTarget(stateRTs[cur])
	render.OverrideAlphaWriteEnable(true, true)
	cam.Start2D()
	draw.NoTexture()
	for _, s in ipairs(splashes) do
		local X, Y, r = s.x / TEXEL, -s.y / TEXEL, s.r / TEXEL
		if inWindow(X - r, Y - r, X + r, Y + r) then
			local rim = s.v / 3
			local rings = math.min(math.max(math.ceil(r), math.ceil(s.v + rim)), SPLASH_MAX_RINGS)
			local raise, dig = levelByte(rim / rings), levelByte((s.v + rim) / rings)

			render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
			surface.SetDrawColor(raise, raise, 0, 255)
			for k = 1, rings do
				drawWrapped(discPoly(X, Y, r * math.sqrt(1 - (k - 1) / rings)), X - r, Y - r, X + r, Y + r)
			end

			render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_REVERSE_SUBTRACT, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
			surface.SetDrawColor(dig, dig, 0, math.max(math.floor(math.min(CONFIG.splashFoam * s.v / CONFIG.splash / rings, 1) * 255 + 0.5), 1))
			for k = 1, rings do
				drawWrapped(discPoly(X, Y, r * 0.5 * math.sqrt(1 - (k - 1) / rings)), X - r, Y - r, X + r, Y + r)
			end
		end
	end
	render.OverrideBlend(false)
	cam.End2D()
	render.OverrideAlphaWriteEnable(false)
	render.PopRenderTarget()
	splashes = {}
end

local function clearRect(px, py, w, h)
	render.SetViewPort(px, py, w, h)
	render.Clear(0, 0, 0, 0)
end

local function eachRect(X0, Y0, w, h, fn)
	local px, py = X0 % TEXELS, Y0 % TEXELS
	local w1, h1 = math.min(w, TEXELS - px), math.min(h, TEXELS - py)
	fn(px, py, w1, h1)
	if w1 < w then fn(0, py, w - w1, h1) end
	if h1 < h then fn(px, 0, w1, h - h1) end
	if w1 < w and h1 < h then fn(0, 0, w - w1, h - h1) end
end

local function recentre(eye)
	local half = TEXELS / 2
	local cx = math.floor(eye.x / TEXEL / RECENTRE_STEP + 0.5) * RECENTRE_STEP - half
	local cy = math.floor(-eye.y / TEXEL / RECENTRE_STEP + 0.5) * RECENTRE_STEP - half
	if cx == winX and cy == winY then return end

	for _, rt in ipairs(stateRTs) do
		render.PushRenderTarget(rt)
		render.OverrideAlphaWriteEnable(true, true)
		if not winX or math.abs(cx - winX) >= TEXELS or math.abs(cy - winY) >= TEXELS then
			render.Clear(0, 0, 0, 0)
		else
			local dx, dy = cx - winX, cy - winY
			if dx > 0 then
				eachRect(winX + TEXELS, cy, dx, TEXELS, clearRect)
			elseif dx < 0 then
				eachRect(cx, cy, -dx, TEXELS, clearRect)
			end
			if dy > 0 then
				eachRect(cx, winY + TEXELS, TEXELS, dy, clearRect)
			elseif dy < 0 then
				eachRect(cx, cy, TEXELS, -dy, clearRect)
			end
			render.SetViewPort(0, 0, TEXELS, TEXELS)
		end
		render.OverrideAlphaWriteEnable(false)
		render.PopRenderTarget()
	end
	winX, winY = cx, cy
	surfaces = {}
end

local function step()
	local now = RealTime()
	if now - lastActive > SLEEP then
		simTime = now

		return
	end

	local steps = math.floor((now - simTime) * RATE)
	if steps <= 0 then return end

	if steps >= MAX_STEPS then
		steps = MAX_STEPS
		simTime = now
	else
		simTime = simTime + steps / RATE
	end

	drawFootprints()
	for _, mat in ipairs(simMats) do
		setConstant(mat, "$c0", winX, winY, 0, 0)
		setConstant(mat, "$c1", CONFIG.speed, CONFIG.damping, CONFIG.depth, CONFIG.foamDecay)
	end
	for _ = 1, steps do
		local src = cur
		cur = 3 - cur
		render.PushRenderTarget(stateRTs[cur])
		render.OverrideAlphaWriteEnable(true, true)
		render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
		render.SetMaterial(simMats[src])
		render.DrawScreenQuad()
		render.OverrideBlend(false)
		render.OverrideAlphaWriteEnable(false)
		render.PopRenderTarget()
	end
end

local loudest, targets = {}, {}

local function updateSounds(eye)
	for i = #loudest, 1, -1 do
		loudest[i] = nil
	end
	for e, track in pairs(tracked) do
		if track.energy then loudest[#loudest + 1] = e end
	end
	if #loudest > SOUND_MAX then
		table.sort(loudest, function(a, b) return a:GetPos():DistToSqr(eye) < b:GetPos():DistToSqr(eye) end)
	end

	table.Empty(targets)
	for i = 1, math.min(#loudest, SOUND_MAX) do
		local track = tracked[loudest[i]]
		targets[loudest[i]] = track.energy * math.Clamp(track.scale, 0.4, 1)
	end

	local fade = SOUND_FADE * RealFrameTime()
	for e, target in pairs(targets) do
		if not sounds[e] then
			local patch = CreateSound(e, SKIM_SOUNDS[e:EntIndex() % #SKIM_SOUNDS + 1])
			patch:SetSoundLevel(SOUND_LEVEL)
			patch:PlayEx(0, 100)
			sounds[e] = { patch = patch, volume = 0 }
		end
	end

	for e, s in pairs(sounds) do
		local target = IsValid(e) and targets[e] or 0
		s.volume = math.Approach(s.volume, target, fade)
		if s.volume <= 0 and target <= 0 then
			s.patch:Stop()
			sounds[e] = nil
		else
			local track = tracked[e]
			local energy = track and track.energy or 0
			local scale = track and track.scale or 1
			s.patch:ChangeVolume(s.volume)
			s.patch:ChangePitch(math.Clamp(90 + 30 * energy - 12 * (scale - 1), 70, 130))
		end
	end
end

local function stopSounds()
	for e, s in pairs(sounds) do
		s.patch:Stop()
		sounds[e] = nil
	end
end

local function update()
	local eye = EyePos()
	recentre(eye)
	findCandidates(eye)
	updateTracked()
	updateSounds(eye)
	drawSplashes()
	step()
end

function wakes.Start()
	if simMats then return true end

	for i = 1, 2 do
		local rt = GetRenderTargetEx("borealis_wakes" .. i .. "_" .. TEXELS, TEXELS, TEXELS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA16161616F)
		if not shaderpack.UsableRT(rt, TEXELS) then
			stateRTs = {}

			return false
		end
		stateRTs[i] = rt
	end

	forceRT = GetRenderTargetEx("borealis_wakes_force_" .. TEXELS, TEXELS, TEXELS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
	if not shaderpack.UsableRT(forceRT, TEXELS) then
		stateRTs, forceRT = {}, nil

		return false
	end

	for _, rt in ipairs(stateRTs) do
		render.PushRenderTarget(rt)
		render.OverrideAlphaWriteEnable(true, true)
		render.Clear(0, 0, 0, 0)
		render.OverrideAlphaWriteEnable(false)
		render.PopRenderTarget()
	end

	stampMat = CreateMaterial("borealis_wakes_stamp_" .. os.time(), "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$model"] = 1,
		["$nocull"] = 1,
		["$ignorez"] = 1,
	})

	simMats = {}
	for i, rt in ipairs(stateRTs) do
		simMats[i] = CreateShaderMaterial("borealis_wakes_sim" .. i .. "_" .. os.time(), {
			["$pixshader"] = SIM_PS,
			["$basetexture"] = rt:GetName(),
			["$texture1"] = forceRT:GetName(),
			["$linearread_basetexture"] = 1,
			["$linearread_texture1"] = 1,
			["$linearwrite"] = 1,
			["$alpha_blend"] = 0,
			["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
			["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		})
		simMats[i]:SetTexture("$basetexture", rt)
		simMats[i]:SetTexture("$texture1", forceRT)
	end

	cur, winX, winY, nextCandidates = 1, nil, nil, 0
	simTime, lastActive = RealTime(), -math.huge
	tracked, splashes, surfaces, candidates = {}, {}, {}, {}
	hook.Add("OnEntityCreated", "borealis_wakes", function() nextCandidates = 0 end)
	hook.Add("PreRender", "borealis_wakes", update)
	hook.Add("ShouldDrawLocalPlayer", "borealis_wakes", function()
		if capturing then return true end
	end)

	return true
end

function wakes.Stop()
	hook.Remove("PreRender", "borealis_wakes")
	hook.Remove("ShouldDrawLocalPlayer", "borealis_wakes")
	hook.Remove("OnEntityCreated", "borealis_wakes")
	if IsValid(emitter) then emitter:Finish() end
	stateRTs, forceRT, simMats, winX, winY, emitter = {}, nil, nil, nil, nil, nil
	stopSounds()
	tracked, splashes, surfaces, candidates = {}, {}, {}, {}
	table.Empty(stamped)
end

function wakes.Texture()
	if not simMats or not winX then return end

	return stateRTs[cur], winX, winY
end
