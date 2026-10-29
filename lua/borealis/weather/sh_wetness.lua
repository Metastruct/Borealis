local PS, VS = "wet_ps30", "fog_vs30"
local NOISE = "shaderpack/procsky/fognoise"

if SERVER then
	shaderpack.AddResources({ VS, PS }, { NOISE })

	return
end

local cover, depthslices, procsky, fog, bspdata = shaderpack.cover, shaderpack.depthslices, shaderpack.procsky, shaderpack.fog, shaderpack.bspdata
local ENABLED = CreateClientConVar("cl_draw_wetness", "1", true, false, "darken and gloss the surfaces the rain reaches")

local WET_RATE, DRY_RATE = 1 / 20, 1 / 60
local POOL_RATE, POOL_DRY_RATE = 1 / 40, 1 / 180
local FROST = 0.8
local ORDER = 0.5
local PUDDLE_LEVELS = {
	{ 0, 1.1 }, { 0.01, 0.81 }, { 0.05, 0.73 }, { 0.1, 0.68 }, { 0.25, 0.6 }, { 0.5, 0.5 },
	{ 0.75, 0.41 }, { 0.9, 0.33 }, { 0.95, 0.29 }, { 0.99, 0.21 }, { 1, -0.1 },
}

local function puddleLevel(share)
	for i = 2, #PUDDLE_LEVELS do
		local a, b = PUDDLE_LEVELS[i - 1], PUDDLE_LEVELS[i]
		if share <= b[1] then
			return Lerp((share - a[1]) / (b[1] - a[1]), a[2], b[2])
		end
	end

	return PUDDLE_LEVELS[#PUDDLE_LEVELS][2]
end

local toLinear, setConstant = shaderpack.ToLinear, shaderpack.SetConstant

local MAT
local materialSerial = 0

local function build()
	materialSerial = materialSerial + 1
	MAT = CreateShaderMaterial("ms_wetness_" .. os.time() .. "_" .. materialSerial, {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$texture3"] = NOISE,
		["$linearread_basetexture"] = 0,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
		["$linearread_texture4"] = 1,
		["$linearread_texture5"] = 1,
		["$linearread_texture6"] = 1,
		["$linearwrite"] = 0,
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
		["$ignorez"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	}, "screenspace_general_8tex")
end

local wet, pool, active, frozen = 0, 0, false, false

local function ease(value, target, rise, fall, dt)
	if target > value then
		return math.min(target, value + rise * dt)
	end

	return math.max(target, value - fall * dt)
end

local function think()
	local rain = tod and tod.rain and tod.rain.amount or 0
	local dt = RealFrameTime()
	wet = ease(wet, frozen and FROST or rain, WET_RATE, DRY_RATE, dt)
	pool = ease(pool, frozen and 0 or rain, POOL_RATE, POOL_DRY_RATE, dt)
	active = wet > 0.001 or pool > 0.001
end

local FAR_COLUMN, FAR_COLUMNS = 128, 64
local FAR_TRACES_PER_FRAME = 32
local FAR_DEFAULT = 0.7
local FAR_LIFT, FAR_LIFT_LOW, FAR_DROP = 1024, 128, 4096
local FAR_RETRACE_Z = 1024
local SHORE_PROBE = 8
local Z_MIN, Z_RANGE = cover.Z_MIN, cover.Z_RANGE

local farRT, farX, farY, farZ
local farQueue, farOwner = {}, {}
local farTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = {} }
local farWater = { mask = MASK_WATER, start = Vector(), endpos = Vector(), output = {} }

local function farColumn(cx, cy, z)
	local x, y = (cx + 0.5) * FAR_COLUMN, (cy + 0.5) * FAR_COLUMN
	farTrace.start:SetUnpacked(x, y, z + FAR_LIFT)
	farTrace.endpos:SetUnpacked(x, y, z - FAR_DROP)
	local tr = util.TraceLine(farTrace)
	if tr.StartSolid then
		farTrace.start:SetUnpacked(x, y, z + FAR_LIFT_LOW)
		tr = util.TraceLine(farTrace)
		if tr.StartSolid then return FAR_DEFAULT end
	end

	if not tr.Hit or tr.HitSky then return FAR_DEFAULT end

	farWater.start:Set(farTrace.start)
	farWater.endpos:SetUnpacked(x, y, tr.HitPos.z - SHORE_PROBE)
	local water = util.TraceLine(farWater)

	return cover.GLOSS[tr.MatType] or 1, water.Hit and not water.StartSolid and water.HitPos.z or nil
end

local function clearFar(z)
	render.PushRenderTarget(farRT)
	render.Clear(0, 0, math.floor(FAR_DEFAULT * 255 + 0.5), 255)
	render.PopRenderTarget()
	farQueue, farOwner = {}, {}
	farX, farY, farZ = nil, nil, z
end

local function updateFar(eye)
	if not farRT then
		farRT = GetRenderTargetEx("ms_wet_gloss_" .. FAR_COLUMNS, FAR_COLUMNS, FAR_COLUMNS, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
		if not shaderpack.UsableRT(farRT, FAR_COLUMNS) then
			farRT = nil

			return
		end

		clearFar(eye.z)
	end

	local half = FAR_COLUMNS / 2
	local ex, ey = math.floor(eye.x / FAR_COLUMN), math.floor(eye.y / FAR_COLUMN)
	local x0, y0 = ex - half, ey - half
	if math.abs(eye.z - farZ) > FAR_RETRACE_Z or (farX and (math.abs(x0 - farX) >= FAR_COLUMNS or math.abs(y0 - farY) >= FAR_COLUMNS)) then
		clearFar(eye.z)
	end

	if x0 ~= farX or y0 ~= farY then
		farX, farY = x0, y0
		local pending = {}
		for cy = y0, y0 + FAR_COLUMNS - 1 do
			for cx = x0, x0 + FAR_COLUMNS - 1 do
				local key = cover.ColumnKey(cx, cy)
				if farOwner[cx % FAR_COLUMNS * FAR_COLUMNS + cy % FAR_COLUMNS] ~= key then
					pending[#pending + 1] = { key, math.max(math.abs(cx - ex), math.abs(cy - ey)) }
				end
			end
		end

		table.sort(pending, function(a, b) return a[2] > b[2] end)
		farQueue = {}
		for i = 1, #pending do
			farQueue[i] = pending[i][1]
		end
	end

	if #farQueue == 0 then return end

	render.PushRenderTarget(farRT)
	for _ = 1, FAR_TRACES_PER_FRAME do
		local key = table.remove(farQueue)
		if not key then break end

		local cx, cy = cover.ColumnFromKey(key)
		if cx >= farX and cx < farX + FAR_COLUMNS and cy >= farY and cy < farY + FAR_COLUMNS then
			local gloss, level = farColumn(cx, cy, eye.z)
			local v = level and math.floor(math.Clamp((level - Z_MIN) / Z_RANGE, 0, 1) * 65535 + 0.5) or 0
			local hi = math.floor(v / 256)
			render.SetViewPort(cx % FAR_COLUMNS, cy % FAR_COLUMNS, 1, 1)
			render.Clear(hi, v - hi * 256, math.floor(gloss * 255 + 0.5), level and 0 or 255)
			farOwner[cx % FAR_COLUMNS * FAR_COLUMNS + cy % FAR_COLUMNS] = key
		end
	end
	render.SetViewPort(0, 0, FAR_COLUMNS, FAR_COLUMNS)
	render.PopRenderTarget()
end

local function prepare()
	if active then
		local eye = EyePos()
		cover.Update(eye)
		updateFar(eye)
	end
end

local function skyColors()
	local tonemap = render.GetToneMappingScaleLinear().x
	if procsky and procsky.GetSkyColors then
		local h, z = procsky.GetSkyColors()

		return h[1] * tonemap, h[2] * tonemap, h[3] * tonemap, z[1] * tonemap, z[2] * tonemap, z[3] * tonemap
	end

	local r, g, b = render.GetFogColor()
	r, g, b = toLinear(r) * tonemap, toLinear(g) * tonemap, toLinear(b) * tonemap

	return r, g, b, r, g, b
end

local FOG_DENSITY_MAX, FOG_FALLOFF_MAX = 0.001, 1000
local quadColor = Color(0, 0, 0, 255)
local extra = Matrix()

local function draw()
	if not active then return end

	local coverRT = cover.Texture()
	if not coverRT or not farRT then return end

	if not MAT then build() end
	local bakedSun = bspdata.BakedSun()

	MAT:SetTexture("$texture2", coverRT)
	MAT:SetTexture("$texture5", farRT)
	local spans = cover.Spans()
	MAT:SetTexture("$texture6", spans or coverRT)
	local eye, ang = EyePos(), EyeAngles()
	local fwd, right = ang:Forward(), ang:Right()
	local halfW, halfH, vs = depthslices.ViewTan()
	local hr, hg, hb, zr, zg, zb = skyColors()
	setConstant(MAT, "$c0", eye.x, eye.y, eye.z, wet)
	setConstant(MAT, "$c1", fwd.x, fwd.y, fwd.z, halfW)
	setConstant(MAT, "$c2", hr, hg, hb, halfH)
	setConstant(MAT, "$c3", zr, zg, zb, vs.znear)

	local lut = procsky and procsky.GetLut and procsky.GetLut()
	local lutWeight, lutScale = 0, 0
	if lut then
		MAT:SetTexture("$texture4", lut)
		lutWeight = 1 - shaderpack.Overcast()
		lutScale = procsky.GetSkyScale() * render.GetToneMappingScaleLinear().x
	end

	local rain = frozen and -1 or tod and tod.rain and tod.rain.amount or 0
	local fogDensity, fogFalloff, fogBase = fog.Layer()
	extra:SetUnpacked(
		CurTime() % 3600, rain, lutWeight, lutScale,
		right.x, right.y, right.z, puddleLevel(pool),
		bakedSun.x, bakedSun.y, bakedSun.z, pool,
		(farX + FAR_COLUMNS / 2) * FAR_COLUMN, (farY + FAR_COLUMNS / 2) * FAR_COLUMN, fogBase, spans and vs.zfar or -vs.zfar
	)
	MAT:SetMatrix("$viewprojmat", extra)
	quadColor.r = math.floor(math.min(fogDensity / FOG_DENSITY_MAX, 1) * 255 + 0.5)
	quadColor.g = math.floor(math.Clamp(fogFalloff / FOG_FALLOFF_MAX, 1 / 255, 1) * 255 + 0.5)
	quadColor.b = depthslices.Samples()

	return depthslices.Composite(MAT, quadColor)
end

local function stop()
	hook.Remove("Think", "ms_wetness")
	hook.Remove("PreRender", "ms_wetness")
	depthslices.RemoveEffect("ms_wetness")
	active = false
end

local function start()
	stop()
	MAT = nil
	frozen = shaderpack.ice ~= nil and shaderpack.ice.Winter()
	hook.Add("Think", "ms_wetness", think)
	hook.Add("PreRender", "ms_wetness", prepare)
	depthslices.AddEffect("ms_wetness", ORDER, draw, false, function() return active end)
end

shaderpack.Toggle("ms_wetness", ENABLED, { PS, VS }, start, stop, { NOISE })()

hook.Add("TOD_WinterRemoved", "ms_wetness", function()
	frozen = false
end)

hook.Add("TOD_WinterRemoved", "ms_wetness", function()
	frozen = false
end)
