local STAMP_PS = "borealis_trailstamp_ps30"
local FILL_PS = "borealis_trailfill_ps30"

if SERVER then
	shaderpack.AddResources({ STAMP_PS, FILL_PS })

	return
end

local trails = shaderpack.trails or {}
shaderpack.trails = trails
trails.STAMP_PS = STAMP_PS
trails.FILL_PS = FILL_PS

local LEVELS, LEVEL, TEXEL = 4, 768, 2
local STRIDE = LEVEL + 2
local ATLAS = STRIDE * 2
local RECENTRE_STEP = 32
local SCAN_HALF = LEVEL * TEXEL
local REFILL_INTERVAL = 1
local CAPTURE_PAD = 4
local STAMP_BLUR = 2
local CAPTURE_HEIGHT = 4096
local CANDIDATE_INTERVAL = 0.25
local RESTAMP_INTERVAL = 1
local GROUND_PAD = 10
local CHANNELS = 2

local toLinear, setConstant = shaderpack.ToLinear, shaderpack.SetConstant

local levelTexel, levelX, levelY = {}, {}, {}
for i = 1, LEVELS do
	levelTexel[i] = TEXEL * 2 ^ (i - 1)
	levelX[i] = (i - 1) % 2 * STRIDE + 1
	levelY[i] = math.floor((i - 1) / 2) * STRIDE + 1
end

local trailRT, stampRT
local winX, winY = {}, {}
local eyeX, eyeY
local stampMat, blurMat, copyMat, fillMat
local capturing = false
local users = {}
local passes = {}
local reach = 0
local liveMask = { 0, 0, 0 }
local tracked = {}
local levelPos = {}

local function emit(i, px, py, w, h, offX, offY, fn, mirror)
	local ox, oy = levelX[i], levelY[i]
	fn(ox + px, oy + py, w, h, offX, offY)
	if not mirror then return end

	local gx1 = px == 0 and LEVEL or nil
	local gx2 = px + w == LEVEL and -1 or nil
	local gy1 = py == 0 and LEVEL or nil
	local gy2 = py + h == LEVEL and -1 or nil
	if gx1 then fn(ox + gx1, oy + py, 1, h) end
	if gx2 then fn(ox + gx2, oy + py, 1, h) end
	if gy1 then fn(ox + px, oy + gy1, w, 1) end
	if gy2 then fn(ox + px, oy + gy2, w, 1) end
	if gx1 and gy1 then fn(ox + gx1, oy + gy1, 1, 1) end
	if gx1 and gy2 then fn(ox + gx1, oy + gy2, 1, 1) end
	if gx2 and gy1 then fn(ox + gx2, oy + gy1, 1, 1) end
	if gx2 and gy2 then fn(ox + gx2, oy + gy2, 1, 1) end
end

local function eachRect(i, X0, Y0, w, h, fn, mirror)
	local px, py = X0 % LEVEL, Y0 % LEVEL
	local w1, h1 = math.min(w, LEVEL - px), math.min(h, LEVEL - py)
	emit(i, px, py, w1, h1, 0, 0, fn, mirror)
	if w1 < w then emit(i, 0, py, w - w1, h1, w1, 0, fn, mirror) end
	if h1 < h then emit(i, px, 0, w1, h - h1, 0, h1, fn, mirror) end
	if w1 < w and h1 < h then emit(i, 0, 0, w - w1, h - h1, w1, h1, fn, mirror) end
end

local function clearRect(px, py, w, h)
	render.SetViewPort(px, py, w, h)
	render.Clear(0, 0, 0, 0)
end

local function quadRect(px, py, w, h)
	render.SetScissorRect(px, py, px + w, py + h, true)
	render.DrawScreenQuad()
end

local function paintRect(px, py, w, h)
	surface.DrawRect(px, py, w, h)
end

local function copyAtlas()
	render.PushRenderTarget(stampRT)
	render.SetViewPort(0, 0, ATLAS, ATLAS)
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	render.SetMaterial(copyMat)
	render.DrawScreenQuad()
	render.OverrideBlend(false)
	render.OverrideAlphaWriteEnable(false)
	render.PopRenderTarget()
end

local function enteredStrips(i, wx, wy, fn)
	local cx, cy = winX[i], winY[i]
	if not wx or math.abs(cx - wx) >= LEVEL or math.abs(cy - wy) >= LEVEL then
		eachRect(i, cx, cy, LEVEL, LEVEL, fn, true)

		return
	end

	local dx, dy = cx - wx, cy - wy
	if dx > 0 then
		eachRect(i, wx + LEVEL, cy, dx, LEVEL, fn, true)
	elseif dx < 0 then
		eachRect(i, cx, cy, -dx, LEVEL, fn, true)
	end
	if dy > 0 then
		eachRect(i, cx, wy + LEVEL, LEVEL, dy, fn, true)
	elseif dy < 0 then
		eachRect(i, cx, cy, LEVEL, -dy, fn, true)
	end
end

local function recentreLevel(i, eye)
	local texel, half = levelTexel[i], LEVEL / 2
	local cx = math.floor(eye.x / texel / RECENTRE_STEP + 0.5) * RECENTRE_STEP - half
	local cy = math.floor(-eye.y / texel / RECENTRE_STEP + 0.5) * RECENTRE_STEP - half
	local wx, wy = winX[i], winY[i]
	if cx == wx and cy == wy then return false end

	winX[i], winY[i] = cx, cy
	if i == LEVELS then
		render.PushRenderTarget(trailRT)
		render.OverrideAlphaWriteEnable(true, true)
		enteredStrips(i, wx, wy, clearRect)
		render.SetViewPort(0, 0, ATLAS, ATLAS)
		render.OverrideAlphaWriteEnable(false)
		render.PopRenderTarget()

		return true
	end

	copyAtlas()
	setConstant(fillMat, "$c0", winX[1] or 0, winY[1] or 0, winX[2] or 0, winY[2] or 0)
	setConstant(fillMat, "$c1", winX[3] or 0, winY[3] or 0, winX[4] or 0, winY[4] or 0)
	render.PushRenderTarget(trailRT)
	render.SetViewPort(0, 0, ATLAS, ATLAS)
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	render.SetMaterial(fillMat)
	enteredStrips(i, wx, wy, quadRect)
	render.SetScissorRect(0, 0, 0, 0, false)
	render.OverrideBlend(false)
	render.OverrideAlphaWriteEnable(false)
	render.PopRenderTarget()

	return true
end

local nearMoved = false

local function recentre(eye)
	eyeX, eyeY = eye.x, eye.y
	for i = LEVELS, 1, -1 do
		if recentreLevel(i, eye) and i == 1 then
			nearMoved = true
			for _, u in pairs(users) do
				u.cache = {}
			end
		end
	end
end

local function linearByte(dec)
	local c, err = 0, math.huge
	for v = 0, 255 do
		local e = math.abs(toLinear(v) - dec)
		if e > err then break end
		c, err = v, e
	end

	return c
end

local nextRefill = 0

local function refill()
	local now = RealTime()
	if now < nextRefill then return end
	nextRefill = now + REFILL_INTERVAL

	local dec = { 0, 0, 0 }
	for _, u in pairs(users) do
		if not u.live then dec[u.channel] = linearByte(u.recover() * REFILL_INTERVAL) end
	end

	render.PushRenderTarget(trailRT)
	render.SetViewPort(0, 0, ATLAS, ATLAS)
	cam.Start2D()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_REVERSE_SUBTRACT, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
	surface.SetDrawColor(dec[1], dec[2], dec[3], 255)
	surface.DrawRect(0, 0, ATLAS, ATLAS)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	surface.SetDrawColor(0, 0, 0, 255)
	surface.DrawRect(0, 0, ATLAS, ATLAS)
	render.OverrideBlend(false)
	cam.End2D()
	render.PopRenderTarget()
end

local candidates, nextCandidates = {}, 0

local STAND_IN_MODEL = "models/player/kleiner.mdl"
local standIns = {}

local function dropStandIn(e)
	local s = standIns[e]
	if s then
		if IsValid(s.model) then s.model:Remove() end
		standIns[e] = nil
	end
end

local function wearsPac(e)
	return e:IsPlayer() and e:GetModel():lower():sub(1, 18) == "models/pac3_cache/"
end

local function standIn(e)
	local pac = wearsPac(e)
	local s = standIns[e]
	if s and s.pac == pac then return s.model end

	dropStandIn(e)
	local proxy = false
	if pac then
		proxy = ClientsideModel(STAND_IN_MODEL, RENDERGROUP_OPAQUE)
		if IsValid(proxy) then
			proxy:SetNoDraw(true)
			proxy:SetPos(e:GetPos())
			proxy:SetParent(e)
			proxy:AddEffects(EF_BONEMERGE)
		else
			proxy = false
		end
	end
	standIns[e] = { pac = pac, model = proxy }

	return proxy
end

local function leavesTrail(e)
	if not IsValid(e) or e:IsDormant() or e:GetNoDraw() then return false end
	if e:IsPlayer() then return e:Alive() and not e:InVehicle() end

	local model = (e:GetModel() or ""):lower()
	if model:sub(-4) ~= ".mdl" then return false end

	local class = e:GetClass()
	if class == "viewmodel" or class == "predicted_viewmodel" then return false end
	if e:IsWeapon() and IsValid(e:GetOwner()) and e:GetOwner():IsPlayer() then return false end

	local parent = e:GetParent()
	if IsValid(parent) then return leavesTrail(parent) end

	return true
end

local scanCorner = Vector(SCAN_HALF, SCAN_HALF, SCAN_HALF)

local function findCandidates(eye)
	local now = RealTime()
	if now < nextCandidates then return end
	nextCandidates = now + CANDIDATE_INTERVAL

	candidates = {}
	for _, e in ipairs(ents.FindInBox(eye - scanCorner, eye + scanCorner)) do
		if leavesTrail(e) then candidates[#candidates + 1] = e end
	end
end

local captureView = { type = "3D", origin = Vector(), angles = Angle(90, 90, 0), znear = 1, zfar = CAPTURE_HEIGHT * 2, ortho = {} }
local groundRes = {}
local groundTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = groundRes }
local GROUND_INSET = 0.35
local GROUND_MAX_SLOPE = 1.2
local SAMPLES = { { 0, 0 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }

local stamps, dirty = {}, {}

local function groundPlane(mins, maxs, mx, my)
	local hx, hy = (maxs.x - mins.x) * GROUND_INSET, (maxs.y - mins.y) * GROUND_INSET
	local n, sx, sy, sz, sxx, sxy, syy, sxz, syz = 0, 0, 0, 0, 0, 0, 0, 0, 0
	local high = -math.huge
	local centre
	for _, o in ipairs(SAMPLES) do
		local dx, dy = o[1] * hx, o[2] * hy
		groundTrace.start:SetUnpacked(mx + dx, my + dy, maxs.z + GROUND_PAD)
		groundTrace.endpos:SetUnpacked(mx + dx, my + dy, mins.z - reach)
		util.TraceLine(groundTrace)
		if groundRes.Hit and not groundRes.StartSolid then
			local z = groundRes.HitPos.z
			n = n + 1
			sx, sy, sz = sx + dx, sy + dy, sz + z
			sxx, sxy, syy = sxx + dx * dx, sxy + dx * dy, syy + dy * dy
			sxz, syz = sxz + dx * z, syz + dy * z
			high = math.max(high, z)
			if o[1] == 0 then centre = z end
		end
	end
	if n == 0 then return end

	local b, c = 0, 0
	if n >= 3 then
		local mxv, myv, mz = sx / n, sy / n, sz / n
		local cxx, cxy, cyy = sxx - n * mxv * mxv, sxy - n * mxv * myv, syy - n * myv * myv
		local cxz, cyz = sxz - n * mxv * mz, syz - n * myv * mz
		local det = cxx * cyy - cxy * cxy
		if math.abs(det) > 1e-6 then
			b = (cxz * cyy - cyz * cxy) / det
			c = (cyz * cxx - cxz * cxy) / det
			if b * b + c * c > GROUND_MAX_SLOPE * GROUND_MAX_SLOPE then
				b, c = 0, 0
			end
		end

		if b ~= 0 or c ~= 0 then return mz - b * mxv - c * myv, b, c, high end
	end

	return centre or high, 0, 0, high
end

local function levelRect(s, i)
	local texel = levelTexel[i]
	local X0 = math.max(math.floor(s.minX / texel) - CAPTURE_PAD, winX[i])
	local X1 = math.min(math.ceil(s.maxX / texel) + CAPTURE_PAD, winX[i] + LEVEL)
	local Y0 = math.max(math.floor(-s.maxY / texel) - CAPTURE_PAD, winY[i])
	local Y1 = math.min(math.ceil(-s.minY / texel) + CAPTURE_PAD, winY[i] + LEVEL)
	if X1 <= X0 or Y1 <= Y0 then return end

	return X0, Y0, X1 - X0, Y1 - Y0
end

local function measure(e)
	local mins, maxs = e:WorldSpaceAABB()
	local mx, my = (mins.x + maxs.x) * 0.5, (mins.y + maxs.y) * 0.5
	local ground, b, c, high = groundPlane(mins, maxs, mx, my)
	if not ground then return end

	local nz = 1 / math.sqrt(1 + b * b + c * c)
	local clipNormal = Vector(b * nz, c * nz, -nz)
	local clipBase = -nz * (ground - b * mx - c * my)

	local accepted, height, live, persistent = {}, 0, false, false
	for id, u in pairs(users) do
		if mins.z <= high + u.height and u.accept(groundRes, mx, my, ground, u.cache) then
			accepted[id] = true
			height = math.max(height, u.height)
			if u.live then
				live = true
			else
				persistent = true
			end
		end
	end
	if height == 0 then return end

	local s = { e = e, pos = e:GetPos(), top = maxs.z, minX = mins.x, minY = mins.y, maxX = maxs.x, maxY = maxs.y, clipNormal = clipNormal, clipBase = clipBase, height = height, accepted = accepted, live = live, persistent = persistent }
	s.X0, s.Y0, s.w, s.h = levelRect(s, 1)
	if not s.X0 then s.X0, s.Y0, s.w, s.h = 0, 0, 0, 0 end

	return s
end

local function overlaps(a, b)
	return a.X0 < b.X0 + b.w and b.X0 < a.X0 + a.w and a.Y0 < b.Y0 + b.h and b.Y0 < a.Y0 + a.h
end

local function collectStamps()
	local now = RealTime()
	local n, nd = 0, 0
	local seen, queued = {}, {}
	local function queue(s)
		if queued[s] then return end
		queued[s] = true
		n = n + 1
		stamps[n] = s
	end

	for _, e in ipairs(candidates) do
		if leavesTrail(e) then
			seen[e] = true
			local track = tracked[e]
			local pos, ang = e:GetPos(), e:GetAngles()
			if not track or track.pos ~= pos or track.ang ~= ang then
				if track and track.stamp and track.stamp.live then
					nd = nd + 1
					dirty[nd] = track.stamp
				end

				local ok, stamp = pcall(measure, e)
				stamp = ok and stamp or nil
				tracked[e] = { pos = pos, ang = ang, stamp = stamp, t = track and track.t or now - math.random() * RESTAMP_INTERVAL }
				if stamp then queue(stamp) end
			elseif track.stamp and track.stamp.persistent and now - track.t >= RESTAMP_INTERVAL then
				track.t = now
				track.restamps = (track.restamps or 0) + 1
				track.stamp.restamp = track.restamps
				queue(track.stamp)
			end
		end
	end

	for e, track in pairs(tracked) do
		if not seen[e] then
			if track.stamp and track.stamp.live then
				nd = nd + 1
				dirty[nd] = track.stamp
			end
			tracked[e] = nil
			levelPos[e] = nil
		end
	end
	for e in pairs(standIns) do
		if not tracked[e] then dropStandIn(e) end
	end

	if nearMoved then
		nearMoved = false
		for _, track in pairs(tracked) do
			local s = track.stamp
			if s then
				s.X0, s.Y0, s.w, s.h = levelRect(s, 1)
				if not s.X0 then s.X0, s.Y0, s.w, s.h = 0, 0, 0, 0 end
				if s.live then queue(s) end
			end
		end
	end

	if nd > 0 then
		for _, track in pairs(tracked) do
			local s = track.stamp
			if s and s.live and not queued[s] then
				for i = 1, nd do
					if overlaps(s, dirty[i]) then
						queue(s)
						break
					end
				end
			end
		end
	end

	for i = #stamps, n + 1, -1 do
		stamps[i] = nil
	end
	for i = #dirty, nd + 1, -1 do
		dirty[i] = nil
	end

	return n, nd
end

local color = { 0, 0, 0 }
local shot = {}

local function captureRect(px, py, w, h, ox, oy)
	local texel = shot.texel
	local hw, hh = w * texel * 0.5, h * texel * 0.5
	captureView.x, captureView.y, captureView.w, captureView.h = px, py, w, h
	captureView.origin:SetUnpacked((shot.X0 + ox) * texel + hw, -((shot.Y0 + oy) * texel + hh), shot.top + CAPTURE_HEIGHT)
	local ortho = captureView.ortho
	ortho.left, ortho.right, ortho.top, ortho.bottom = -hw, hw, -hh, hh
	cam.Start(captureView)
	shot.draw:DrawModel()
	cam.End()
end

local function drawStamp(p)
	local s, i = p.s, p.i
	shot.draw, shot.top, shot.texel, shot.X0, shot.Y0 = standIn(s.e) or s.e, s.top, levelTexel[i], p.X0, p.Y0
	for _, pass in ipairs(passes) do
		if pass.height > s.height then break end

		local anyChannel = false
		for c = 1, 3 do
			color[c] = 0
		end
		for id, value in pairs(pass.values) do
			if s.accepted[id] and (i == 1 or not users[id].live) then
				color[users[id].channel] = value
				anyChannel = true
			end
		end

		if anyChannel then
			render.SetColorModulation(color[1], color[2], color[3])
			render.PushCustomClipPlane(s.clipNormal, s.clipBase - pass.height)
			eachRect(i, p.X0, p.Y0, p.w, p.h, captureRect)
			render.PopCustomClipPlane()
		end
	end
end

local function clearLive(nd)
	render.PushRenderTarget(trailRT)
	render.SetViewPort(0, 0, ATLAS, ATLAS)
	cam.Start2D()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_REVERSE_SUBTRACT, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
	surface.SetDrawColor(liveMask[1], liveMask[2], liveMask[3], 255)
	for i = 1, nd do
		local d = dirty[i]
		if d.w > 0 then eachRect(1, d.X0, d.Y0, d.w, d.h, paintRect, true) end
	end
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	surface.SetDrawColor(0, 0, 0, 255)
	for i = 1, nd do
		local d = dirty[i]
		if d.w > 0 then eachRect(1, d.X0, d.Y0, d.w, d.h, paintRect, true) end
	end
	render.OverrideBlend(false)
	cam.End2D()
	render.PopRenderTarget()
end

local plan = {}

local function planStamps(n)
	local m = 0
	for k = 1, n do
		local s = stamps[k]
		local last = levelPos[s.e] or {}
		levelPos[s.e] = last
		local size = math.max(s.maxX - s.minX, s.maxY - s.minY)
		for i = 1, LEVELS do
			local texel = levelTexel[i]
			local want = i == 1
			if not want and s.persistent and size >= texel then
				local p = last[i]
				want = s.restamp and s.restamp % 2 ^ (i - 1) == 0 or not p or math.abs(p.x - s.pos.x) + math.abs(p.y - s.pos.y) >= texel * 0.5
			end
			if want then
				local X0, Y0, w, h = levelRect(s, i)
				if X0 then
					m = m + 1
					local p = plan[m] or {}
					plan[m] = p
					p.s, p.i, p.X0, p.Y0, p.w, p.h = s, i, X0, Y0, w, h
					last[i] = s.pos
				end
			end
		end
		s.restamp = nil
	end
	for k = #plan, m + 1, -1 do
		plan[k] = nil
	end

	return m
end

local function capture()
	local n, nd = collectStamps()
	if nd > 0 then clearLive(nd) end
	if n == 0 then return end

	local m = planStamps(n)
	if m == 0 then return end

	render.PushRenderTarget(stampRT)
	for k = 1, m do
		local p = plan[k]
		eachRect(p.i, p.X0 - STAMP_BLUR, p.Y0 - STAMP_BLUR, math.min(p.w + STAMP_BLUR * 2, LEVEL), math.min(p.h + STAMP_BLUR * 2, LEVEL), clearRect)
	end
	render.SetViewPort(0, 0, ATLAS, ATLAS)

	render.MaterialOverride(stampMat)
	render.SuppressEngineLighting(true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	local clipping = render.EnableClipping(true)
	capturing = true
	for k = 1, m do
		local e = plan[k].s.e
		local override = e.RenderOverride
		e.RenderOverride = nil
		local ok, err = pcall(drawStamp, plan[k])
		e.RenderOverride = override
		if not ok then ErrorNoHalt("[trails] capture: " .. tostring(err) .. "\n") end
	end
	capturing = false
	render.EnableClipping(clipping)
	render.OverrideBlend(false)
	render.SetColorModulation(1, 1, 1)
	render.SuppressEngineLighting(false)
	render.MaterialOverride()
	render.PopRenderTarget()

	render.PushRenderTarget(trailRT)
	render.SetViewPort(0, 0, ATLAS, ATLAS)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	render.SetMaterial(blurMat)
	for k = 1, m do
		local p = plan[k]
		eachRect(p.i, p.X0, p.Y0, p.w, p.h, quadRect, true)
	end
	render.SetScissorRect(0, 0, 0, 0, false)
	render.OverrideBlend(false)
	render.PopRenderTarget()
end

local discs = {}
local DISC_SIDES = 20
local LEVEL_STEPS = 1023
local levelBytes = {}

local function levelByte(v)
	local key = math.floor(v * LEVEL_STEPS + 0.5)
	local b = levelBytes[key]
	if not b then
		b = linearByte(key / LEVEL_STEPS)
		levelBytes[key] = b
	end

	return b
end

local function discPoly(cx, cy, r)
	local poly = {}
	for i = 1, DISC_SIDES do
		local a = i / DISC_SIDES * math.pi * 2
		poly[i] = { x = cx + math.cos(a) * r, y = cy + math.sin(a) * r }
	end

	return poly
end

local function drawWrapped(i, px, py, r)
	local ox, oy = levelX[i], levelY[i]
	for sx = -1, 1 do
		for sy = -1, 1 do
			local cx, cy = px + sx * LEVEL, py + sy * LEVEL
			if cx + r >= -1 and cx - r < LEVEL + 1 and cy + r >= -1 and cy - r < LEVEL + 1 then
				surface.DrawPoly(discPoly(ox + cx, oy + cy, r))
			end
		end
	end
end

local function drawDisc(d, i)
	local texel = levelTexel[i]
	local X, Y, r = d.x / texel, -d.y / texel, d.r / texel
	if i > 1 and (d.live or r < 1) then return end
	if X + r < winX[i] or X - r >= winX[i] + LEVEL or Y + r < winY[i] or Y - r >= winY[i] + LEVEL then return end

	local px, py = X % LEVEL, Y % LEVEL
	local rings = math.Clamp(math.ceil(r), 2, 12)
	for k = 1, rings do
		color[1], color[2], color[3] = 0, 0, 0
		color[d.channel] = levelByte(d.v * k / rings)
		surface.SetDrawColor(color[1], color[2], color[3], 255)
		drawWrapped(i, px, py, r * math.sqrt(1 - (k - 1) / rings))
	end
end

local function drawDiscs()
	if #discs == 0 or not winX[1] then return end

	render.PushRenderTarget(trailRT)
	render.SetViewPort(0, 0, ATLAS, ATLAS)
	cam.Start2D()
	draw.NoTexture()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	for i = 1, LEVELS do
		local ox, oy = levelX[i], levelY[i]
		render.SetScissorRect(ox - 1, oy - 1, ox + LEVEL + 1, oy + LEVEL + 1, true)
		for _, d in ipairs(discs) do
			drawDisc(d, i)
		end
	end
	render.SetScissorRect(0, 0, 0, 0, false)
	render.OverrideBlend(false)
	cam.End2D()
	render.PopRenderTarget()
	discs = {}
end

function trails.Stamp(id, x, y, radius, depth)
	local u = users[id]
	if not u or not trailRT then return end

	discs[#discs + 1] = { x = x, y = y, r = radius, v = math.Clamp(depth, 0, 1), channel = u.channel, live = u.live }
end

local function updateTrails()
	local eye = EyePos()
	recentre(eye)
	refill()
	findCandidates(eye)
	capture()
	drawDiscs()
end

local function rebuildPasses()
	local heights, seen = {}, {}
	reach = 0
	for _, u in pairs(users) do
		reach = math.max(reach, u.height + GROUND_PAD)
		for _, h in ipairs(u.slices) do
			if not seen[h] then
				seen[h] = true
				heights[#heights + 1] = h
			end
		end
	end
	table.sort(heights)

	liveMask = { 0, 0, 0 }
	for _, u in pairs(users) do
		if u.live then liveMask[u.channel] = 255 end
	end
	tracked = {}

	passes = {}
	for i, h in ipairs(heights) do
		local values = {}
		for id, u in pairs(users) do
			for k, sh in ipairs(u.slices) do
				if sh >= h then
					values[id] = 1 - (u.slices[k - 1] or 0) / u.height
					break
				end
			end
		end
		passes[i] = { height = h, values = values }
	end
end

local function start()
	if trailRT then return true end

	trailRT = GetRenderTargetEx("borealis_trail_" .. ATLAS, ATLAS, ATLAS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA16161616F)
	stampRT = GetRenderTargetEx("borealis_trail_stamp_" .. ATLAS, ATLAS, ATLAS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
	if not shaderpack.UsableRT(trailRT, ATLAS) or not shaderpack.UsableRT(stampRT, ATLAS) then
		trailRT, stampRT = nil, nil

		return false
	end

	local suffix = os.time()
	stampMat = CreateMaterial("borealis_trail_stamp_" .. suffix, "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$model"] = 1,
		["$nocull"] = 1,
		["$ignorez"] = 1,
	})
	blurMat = CreateShaderMaterial("borealis_trail_blur_" .. suffix, {
		["$pixshader"] = trails.STAMP_PS,
		["$basetexture"] = stampRT:GetName(),
		["$linearread_basetexture"] = 0,
		["$linearwrite"] = 1,
		["$alpha_blend"] = 0,
	})
	blurMat:SetTexture("$basetexture", stampRT)

	local fillKeys = {
		["$pixshader"] = trails.FILL_PS,
		["$linearread_basetexture"] = 1,
		["$linearwrite"] = 1,
		["$alpha_blend"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
	}
	fillKeys["$basetexture"] = trailRT:GetName()
	copyMat = CreateShaderMaterial("borealis_trail_copy_" .. suffix, fillKeys)
	copyMat:SetTexture("$basetexture", trailRT)
	fillKeys["$basetexture"] = stampRT:GetName()
	fillKeys["$c2_x"] = 1
	fillMat = CreateShaderMaterial("borealis_trail_fill_" .. suffix, fillKeys)
	fillMat:SetTexture("$basetexture", stampRT)

	for _, rt in ipairs({ trailRT, stampRT }) do
		render.PushRenderTarget(rt)
		render.OverrideAlphaWriteEnable(true, true)
		render.Clear(0, 0, 0, 0)
		render.OverrideAlphaWriteEnable(false)
		render.PopRenderTarget()
	end

	winX, winY, eyeX, eyeY, levelPos = {}, {}, nil, nil, {}
	hook.Add("PreRender", "borealis_trails", updateTrails)
	hook.Add("ShouldDrawLocalPlayer", "borealis_trails", function()
		if capturing then return true end
	end)
	hook.Add("OnEntityCreated", "borealis_trails", function()
		nextCandidates = 0
	end)

	return true
end

local function stop()
	hook.Remove("PreRender", "borealis_trails")
	hook.Remove("ShouldDrawLocalPlayer", "borealis_trails")
	hook.Remove("OnEntityCreated", "borealis_trails")
	trailRT, stampRT, winX, winY, eyeX, eyeY = nil, nil, {}, {}, nil, nil
	tracked, discs, levelPos = {}, {}, {}
	for e in pairs(standIns) do
		dropStandIn(e)
	end
end

function trails.Use(id, user)
	if user then
		assert(user.channel >= 1 and user.channel <= CHANNELS, "trails: bad channel")
		user.height = user.slices[#user.slices]
		user.cache = {}
		users[id] = user
	else
		users[id] = nil
	end

	rebuildPasses()
	if next(users) then return start() end

	stop()

	return false
end

function trails.Texture()
	return trailRT
end

function trails.Window()
	if not winX[1] then return 0, 0, 0, 0 end

	return (winX[1] + 1) * TEXEL, -(winY[1] + LEVEL - 1) * TEXEL, (winX[1] + LEVEL - 1) * TEXEL, -(winY[1] + 1) * TEXEL
end

function trails.Centre()
	if not eyeX then return -1e7, -1e7, 0, 0 end

	return eyeX, eyeY, 0, 0
end
