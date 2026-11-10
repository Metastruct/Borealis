local snow = shaderpack.snow
local trails = snow.trails or {}
snow.trails = trails

local DEPTH = snow.DEPTH
local TRAIL_TEXELS, TRAIL_SPAN = 1024, 2048
local TEXEL = TRAIL_SPAN / TRAIL_TEXELS
local TRAIL_STEP = 128
local REFILL_INTERVAL = 1
local REFILL_TIME, SNOWFALL_TIME = 1200, 120
local CAPTURE_PAD = 4
local STAMP_BLUR = 2
local CAPTURE_HEIGHT = 4096
local GATHER_INTERVAL = 0.25
local RESTAMP_INTERVAL = 1
local SKY_CELL = 16

local toLinear = shaderpack.ToLinear
local cellKey = snow.CellKey

local trailRT, stampRT, winX, winY
local stampMat, blurMat
local capturing = false
local stampSky = {}

local function reachesSky(x, y, z, rays)
	local key = cellKey(x, y, z, SKY_CELL)
	local open = rays[key]
	if open == nil then
		local solid
		open, solid = snow.SeesSky(x, y, z)
		if solid then return false end

		rays[key] = open
	end

	return open
end

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
	stampSky = {}
end

local nextRefill = 0

local function refill()
	local now = RealTime()
	if now < nextRefill then return end
	nextRefill = now + REFILL_INTERVAL

	local amount = tod and tod.snow and tod.snow.amount or 0
	local dec = (1 / REFILL_TIME + amount / SNOWFALL_TIME) * REFILL_INTERVAL
	local c, err = 1, math.huge
	for v = 1, 255 do
		local e = math.abs(toLinear(v) - dec)
		if e > err then break end
		c, err = v, e
	end

	render.PushRenderTarget(trailRT)
	cam.Start2D()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_REVERSE_SUBTRACT, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
	surface.SetDrawColor(c, c, c, 255)
	surface.DrawRect(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX, BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	surface.SetDrawColor(0, 0, 0, 255)
	surface.DrawRect(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)
	render.OverrideBlend(false)
	cam.End2D()
	render.PopRenderTarget()
end

local candidates, nextGather = {}, 0

local function printable(e)
	if not IsValid(e) or e:IsDormant() or e:GetNoDraw() or (e:GetModel() or "") == "" then return false end
	if e:IsPlayer() then return e:Alive() and not e:InVehicle() end
	if e:IsNPC() or e:IsNextBot() or e:IsRagdoll() or e:IsVehicle() or e:GetClass() == "prop_physics" then return true end

	local parent = e:GetParent()

	return IsValid(parent) and printable(parent)
end

local function gather(eye)
	local now = RealTime()
	if now < nextGather then return end
	nextGather = now + GATHER_INTERVAL

	local half = TRAIL_SPAN / 2
	candidates = {}
	for _, e in ipairs(ents.FindInBox(eye - Vector(half, half, half), eye + Vector(half, half, half))) do
		if printable(e) then candidates[#candidates + 1] = e end
	end
end

local captureView = { type = "3D", origin = Vector(), angles = Angle(90, 90, 0), znear = 1, zfar = CAPTURE_HEIGHT * 2, ortho = {} }
local groundRes = {}
local groundTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = groundRes }
local CLIP_NORMAL = Vector(0, 0, -1)

local stamps = {}
local lastStamp = {}

hook.Add("EntityRemoved", "borealis_snow", function(e)
	lastStamp[e] = nil
end)

local function stampRect(e)
	if not printable(e) then return end

	local now = RealTime()
	local pos, ang = e:GetPos(), e:GetAngles()
	local last = lastStamp[e]
	if last and now - last.t < RESTAMP_INTERVAL and last.pos == pos and last.ang == ang then return end

	local mins, maxs = e:WorldSpaceAABB()
	local mx, my = (mins.x + maxs.x) * 0.5, (mins.y + maxs.y) * 0.5
	groundTrace.start:SetUnpacked(mx, my, mins.z + DEPTH)
	groundTrace.endpos:SetUnpacked(mx, my, mins.z - DEPTH * 2)
	util.TraceLine(groundTrace)
	if not groundRes.Hit then return end

	local top = groundRes.HitPos.z + DEPTH
	if mins.z > top then return end
	if not reachesSky(mx, my, groundRes.HitPos.z + snow.RAY_HEIGHT, stampSky) then return end

	local X0 = math.max(math.floor(mins.x / TEXEL) - CAPTURE_PAD, winX)
	local X1 = math.min(math.ceil(maxs.x / TEXEL) + CAPTURE_PAD, winX + TRAIL_TEXELS)
	local Y0 = math.max(math.floor(-maxs.y / TEXEL) - CAPTURE_PAD, winY)
	local Y1 = math.min(math.ceil(-mins.y / TEXEL) + CAPTURE_PAD, winY + TRAIL_TEXELS)
	if X1 <= X0 or Y1 <= Y0 then return end

	lastStamp[e] = { t = now, pos = pos, ang = ang }

	return { e = e, top = top, X0 = X0, Y0 = Y0, w = X1 - X0, h = Y1 - Y0 }
end

local function drawStamp(s)
	render.PushCustomClipPlane(CLIP_NORMAL, -s.top)
	eachRTRect(s.X0, s.Y0, s.w, s.h, function(px, py, w, h, ox, oy)
		local hw, hh = w * TEXEL * 0.5, h * TEXEL * 0.5
		captureView.x, captureView.y, captureView.w, captureView.h = px, py, w, h
		captureView.origin:SetUnpacked((s.X0 + ox) * TEXEL + hw, -((s.Y0 + oy) * TEXEL + hh), s.top + CAPTURE_HEIGHT)
		local ortho = captureView.ortho
		ortho.left, ortho.right, ortho.top, ortho.bottom = -hw, hw, -hh, hh
		cam.Start(captureView)
		s.e:DrawModel()
		cam.End()
	end)
	render.PopCustomClipPlane()
end

local function blurRect(px, py, w, h)
	surface.DrawTexturedRect(px, py, w, h)
end

local function capture()
	local n = 0
	for _, e in ipairs(candidates) do
		local ok, s = pcall(stampRect, e)
		if ok and s then
			n = n + 1
			stamps[n] = s
		end
	end

	for i = #stamps, n + 1, -1 do
		stamps[i] = nil
	end

	if n == 0 then return end

	render.PushRenderTarget(stampRT)
	for i = 1, n do
		local s = stamps[i]
		eachRTRect(s.X0 - STAMP_BLUR, s.Y0 - STAMP_BLUR, s.w + STAMP_BLUR * 2, s.h + STAMP_BLUR * 2, clearRect)
	end
	render.SetViewPort(0, 0, TRAIL_TEXELS, TRAIL_TEXELS)

	render.MaterialOverride(stampMat)
	render.SuppressEngineLighting(true)
	local clipping = render.EnableClipping(true)
	capturing = true
	for i = 1, n do
		local e = stamps[i].e
		local override = e.RenderOverride
		e.RenderOverride = nil
		local ok, err = pcall(drawStamp, stamps[i])
		e.RenderOverride = override
		if not ok then ErrorNoHalt("[snow] capture: " .. tostring(err) .. "\n") end
	end
	capturing = false
	render.EnableClipping(clipping)
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

function trails.Prepare()
	if not trailRT then return end

	local eye = EyePos()
	recentre(eye)
	refill()
	gather(eye)
	capture()
end

function trails.Texture()
	return trailRT
end

function trails.Window()
	return (winX + 1) * TEXEL, -(winY + TRAIL_TEXELS - 1) * TEXEL, (winX + TRAIL_TEXELS - 1) * TEXEL, -(winY + 1) * TEXEL
end

function trails.Start(suffix)
	trailRT = GetRenderTargetEx("borealis_snow_trail_" .. TRAIL_TEXELS, TRAIL_TEXELS, TRAIL_TEXELS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA16161616F)
	stampRT = GetRenderTargetEx("borealis_snow_stamp_" .. TRAIL_TEXELS, TRAIL_TEXELS, TRAIL_TEXELS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
	if not shaderpack.UsableRT(trailRT, TRAIL_TEXELS) or not shaderpack.UsableRT(stampRT, TRAIL_TEXELS) then
		trailRT, stampRT = nil, nil

		return false
	end

	stampMat = CreateMaterial("borealis_snow_stamp_" .. suffix, "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$model"] = 1,
		["$nocull"] = 1,
		["$ignorez"] = 1,
	})
	blurMat = CreateShaderMaterial("borealis_snow_blur_" .. suffix, {
		["$pixshader"] = snow.STAMP_PS,
		["$basetexture"] = stampRT:GetName(),
		["$linearread_basetexture"] = 1,
		["$linearwrite"] = 1,
		["$alpha_blend"] = 0,
	})
	blurMat:SetTexture("$basetexture", stampRT)

	for _, rt in ipairs({ trailRT, stampRT }) do
		render.PushRenderTarget(rt)
		render.Clear(0, 0, 0, 0)
		render.PopRenderTarget()
	end

	hook.Add("ShouldDrawLocalPlayer", "borealis_snow", function()
		if capturing then return true end
	end)

	return true
end

function trails.Stop()
	hook.Remove("ShouldDrawLocalPlayer", "borealis_snow")
	winX, winY = nil, nil
end
