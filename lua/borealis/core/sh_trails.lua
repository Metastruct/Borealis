local STAMP_PS = "borealis_trailstamp_ps30"

if SERVER then
	shaderpack.AddResources({ STAMP_PS })

	return
end

local trails = shaderpack.trails or {}
shaderpack.trails = trails
trails.STAMP_PS = STAMP_PS

local TRAIL_TEXELS, TRAIL_SPAN = 1024, 2048
local TEXEL = TRAIL_SPAN / TRAIL_TEXELS
local TRAIL_STEP = 128
local REFILL_INTERVAL = 1
local CAPTURE_PAD = 4
local STAMP_BLUR = 2
local CAPTURE_HEIGHT = 4096
local CANDIDATE_INTERVAL = 0.25
local RESTAMP_INTERVAL = 1
local GROUND_PAD = 10
local CHANNELS = 2

local toLinear = shaderpack.ToLinear

local trailRT, stampRT, winX, winY
local stampMat, blurMat
local capturing = false
local users = {}
local passes = {}
local reach = 0
local liveMask = { 0, 0, 0 }
local tracked = {}

local function eachRTRect(X0, Y0, w, h, fn)
	local px, py = X0 % TRAIL_TEXELS, Y0 % TRAIL_TEXELS
	local w1, h1 = math.min(w, TRAIL_TEXELS - px), math.min(h, TRAIL_TEXELS - py)
	fn(px, py, w1, h1, 0, 0)
	if w1 < w then fn(0, py, w - w1, h1, w1, 0) end
	if h1 < h then fn(px, 0, w1, h - h1, 0, h1) end
	if w1 < w and h1 < h then fn(0, 0, w - w1, h - h1, w1, h1) end
end

local function clearRect(px, py, w, h)
	render.SetViewPort(px, py, w, h)
	render.Clear(0, 0, 0, 0)
end

local function recentre(eye)
	local half = TRAIL_TEXELS / 2
	local cx = math.floor(eye.x / TEXEL / TRAIL_STEP + 0.5) * TRAIL_STEP - half
	local cy = math.floor(-eye.y / TEXEL / TRAIL_STEP + 0.5) * TRAIL_STEP - half
	if cx == winX and cy == winY then return end

	render.PushRenderTarget(trailRT)
	if not winX or math.abs(cx - winX) >= TRAIL_TEXELS or math.abs(cy - winY) >= TRAIL_TEXELS then
		render.Clear(0, 0, 0, 0)
	else
		local dx, dy = cx - winX, cy - winY
		if dx > 0 then
			eachRTRect(winX + TRAIL_TEXELS, cy, dx, TRAIL_TEXELS, clearRect)
		elseif dx < 0 then
			eachRTRect(cx, cy, -dx, TRAIL_TEXELS, clearRect)
		end

		if dy > 0 then
			eachRTRect(cx, winY + TRAIL_TEXELS, TRAIL_TEXELS, dy, clearRect)
		elseif dy < 0 then
			eachRTRect(cx, cy, TRAIL_TEXELS, -dy, clearRect)
		end

		render.SetViewPort(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)
	end
	render.PopRenderTarget()
	winX, winY = cx, cy
	tracked = {}
	for _, u in pairs(users) do
		u.cache = {}
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
	cam.Start2D()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_REVERSE_SUBTRACT, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
	surface.SetDrawColor(dec[1], dec[2], dec[3], 255)
	surface.DrawRect(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	surface.SetDrawColor(0, 0, 0, 255)
	surface.DrawRect(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)
	render.OverrideBlend(false)
	cam.End2D()
	render.PopRenderTarget()
end

local candidates, nextCandidates = {}, 0

local function leavesTrail(e)
	if not IsValid(e) or e:IsDormant() or e:GetNoDraw() then return false end
	if e:IsPlayer() then return e:Alive() and not e:InVehicle() end

	local model = e:GetModel() or ""
	if model:sub(-4):lower() ~= ".mdl" then return false end

	local class = e:GetClass()
	if class == "viewmodel" or class == "predicted_viewmodel" then return false end
	if e:IsWeapon() and e:IsCarriedByLocalPlayer() and not LocalPlayer():ShouldDrawLocalPlayer() then return false end

	local parent = e:GetParent()
	if IsValid(parent) then return leavesTrail(parent) end

	return true
end

local function findCandidates(eye)
	local now = RealTime()
	if now < nextCandidates then return end
	nextCandidates = now + CANDIDATE_INTERVAL

	local half = TRAIL_SPAN / 2
	candidates = {}
	for _, e in ipairs(ents.FindInBox(eye - Vector(half, half, half), eye + Vector(half, half, half))) do
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

	local X0 = math.max(math.floor(mins.x / TEXEL) - CAPTURE_PAD, winX)
	local X1 = math.min(math.ceil(maxs.x / TEXEL) + CAPTURE_PAD, winX + TRAIL_TEXELS)
	local Y0 = math.max(math.floor(-maxs.y / TEXEL) - CAPTURE_PAD, winY)
	local Y1 = math.min(math.ceil(-mins.y / TEXEL) + CAPTURE_PAD, winY + TRAIL_TEXELS)
	if X1 <= X0 or Y1 <= Y0 then return end

	return { e = e, top = maxs.z, clipNormal = clipNormal, clipBase = clipBase, height = height, accepted = accepted, live = live, persistent = persistent, X0 = X0, Y0 = Y0, w = X1 - X0, h = Y1 - Y0 }
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
				tracked[e] = { pos = pos, ang = ang, stamp = stamp, t = now }
				if stamp then queue(stamp) end
			elseif track.stamp and track.stamp.persistent and now - track.t >= RESTAMP_INTERVAL then
				track.t = now
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

local function drawStamp(s)
	local top = s.top
	for _, pass in ipairs(passes) do
		if pass.height > s.height then break end

		local anyChannel = false
		for c = 1, 3 do
			color[c] = 0
		end
		for id, value in pairs(pass.values) do
			if s.accepted[id] then
				color[users[id].channel] = value
				anyChannel = true
			end
		end

		if anyChannel then
			render.SetColorModulation(color[1], color[2], color[3])
			render.PushCustomClipPlane(s.clipNormal, s.clipBase - pass.height)
			eachRTRect(s.X0, s.Y0, s.w, s.h, function(px, py, w, h, ox, oy)
				local hw, hh = w * TEXEL * 0.5, h * TEXEL * 0.5
				captureView.x, captureView.y, captureView.w, captureView.h = px, py, w, h
				captureView.origin:SetUnpacked((s.X0 + ox) * TEXEL + hw, -((s.Y0 + oy) * TEXEL + hh), top + CAPTURE_HEIGHT)
				local ortho = captureView.ortho
				ortho.left, ortho.right, ortho.top, ortho.bottom = -hw, hw, -hh, hh
				cam.Start(captureView)
				s.e:DrawModel()
				cam.End()
			end)
			render.PopCustomClipPlane()
		end
	end
end

local function blurRect(px, py, w, h)
	surface.DrawTexturedRect(px, py, w, h)
end

local function fillRect(px, py, w, h)
	surface.DrawRect(px, py, w, h)
end

local function clearLive(nd)
	render.PushRenderTarget(trailRT)
	cam.Start2D()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_REVERSE_SUBTRACT, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
	surface.SetDrawColor(liveMask[1], liveMask[2], liveMask[3], 255)
	for i = 1, nd do
		local d = dirty[i]
		eachRTRect(d.X0, d.Y0, d.w, d.h, fillRect)
	end
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	surface.SetDrawColor(0, 0, 0, 255)
	for i = 1, nd do
		local d = dirty[i]
		eachRTRect(d.X0, d.Y0, d.w, d.h, fillRect)
	end
	render.OverrideBlend(false)
	cam.End2D()
	render.PopRenderTarget()
end

local function capture()
	local n, nd = collectStamps()
	if nd > 0 then clearLive(nd) end
	if n == 0 then return end

	render.PushRenderTarget(stampRT)
	for i = 1, n do
		local s = stamps[i]
		eachRTRect(s.X0 - STAMP_BLUR, s.Y0 - STAMP_BLUR, s.w + STAMP_BLUR * 2, s.h + STAMP_BLUR * 2, clearRect)
	end
	render.SetViewPort(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)

	render.MaterialOverride(stampMat)
	render.SuppressEngineLighting(true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	local clipping = render.EnableClipping(true)
	capturing = true
	for i = 1, n do
		local e = stamps[i].e
		local override = e.RenderOverride
		e.RenderOverride = nil
		local ok, err = pcall(drawStamp, stamps[i])
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
	cam.Start2D()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.SetMaterial(blurMat)
	for i = 1, n do
		local s = stamps[i]
		eachRTRect(s.X0, s.Y0, s.w, s.h, blurRect)
	end
	render.OverrideBlend(false)
	cam.End2D()
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

local function drawWrapped(px, py, r)
	for ox = -1, 1 do
		for oy = -1, 1 do
			local cx, cy = px + ox * TRAIL_TEXELS, py + oy * TRAIL_TEXELS
			if cx + r >= 0 and cx - r < TRAIL_TEXELS and cy + r >= 0 and cy - r < TRAIL_TEXELS then
				surface.DrawPoly(discPoly(cx, cy, r))
			end
		end
	end
end

local function drawDisc(d)
	local X, Y, r = d.x / TEXEL, -d.y / TEXEL, d.r / TEXEL
	if X + r < winX or X - r >= winX + TRAIL_TEXELS or Y + r < winY or Y - r >= winY + TRAIL_TEXELS then return end

	local px, py = X % TRAIL_TEXELS, Y % TRAIL_TEXELS
	local rings = math.Clamp(math.ceil(r), 2, 12)
	for k = 1, rings do
		color[1], color[2], color[3] = 0, 0, 0
		color[d.channel] = levelByte(d.v * k / rings)
		surface.SetDrawColor(color[1], color[2], color[3], 255)
		drawWrapped(px, py, r * math.sqrt(1 - (k - 1) / rings))
	end
end

local function drawDiscs()
	if #discs == 0 or not winX then return end

	render.PushRenderTarget(trailRT)
	cam.Start2D()
	draw.NoTexture()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	for _, d in ipairs(discs) do
		drawDisc(d)
	end
	render.OverrideBlend(false)
	cam.End2D()
	render.PopRenderTarget()
	discs = {}
end

function trails.Stamp(id, x, y, radius, depth)
	local u = users[id]
	if not u or not trailRT then return end

	discs[#discs + 1] = { x = x, y = y, r = radius, v = math.Clamp(depth, 0, 1), channel = u.channel }
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

	trailRT = GetRenderTargetEx("borealis_trail_" .. TRAIL_TEXELS, TRAIL_TEXELS, TRAIL_TEXELS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA16161616F)
	stampRT = GetRenderTargetEx("borealis_trail_stamp_" .. TRAIL_TEXELS, TRAIL_TEXELS, TRAIL_TEXELS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
	if not shaderpack.UsableRT(trailRT, TRAIL_TEXELS) or not shaderpack.UsableRT(stampRT, TRAIL_TEXELS) then
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

	for _, rt in ipairs({ trailRT, stampRT }) do
		render.PushRenderTarget(rt)
		render.Clear(0, 0, 0, 0)
		render.PopRenderTarget()
	end

	winX, winY = nil, nil
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
	trailRT, stampRT, winX, winY = nil, nil, nil, nil
	tracked, discs = {}, {}
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
	if not winX then return 0, 0, 0, 0 end

	return (winX + 1) * TEXEL, -(winY + TRAIL_TEXELS - 1) * TEXEL, (winX + TRAIL_TEXELS - 1) * TEXEL, -(winY + 1) * TEXEL
end
