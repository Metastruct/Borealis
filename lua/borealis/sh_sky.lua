local SHADERS = { "sky_ps30", "skylut_ps30", "aurora_vs30" }

if SERVER then
	shaderpack.AddResources(SHADERS)

	return
end

require("skyboxer")

local SKY_ENABLED = CreateClientConVar("cl_draw_procsky", "1", true, false, "draw the procedural atmosphere sky")
local setConstant = shaderpack.SetConstant

local INTENSITY = 1
local MOON_INTENSITY = 0.012 -- relative to the sun
local moonGain = 1 -- 0 while the theme hides the moon
local UPDATE_INTERVAL = 0.2 -- seconds between fog and cloud colour updates
local HORIZON_ELEV = math.rad(2) -- fog colour is sampled this far above the horizon
local CLOUD_H = 2 -- km, altitude the cloud light is computed at

local procsky = shaderpack.procsky or {}
shaderpack.procsky = procsky
procsky.theme = procsky.theme or {}
local ONE = { 1, 1, 1 }

--------------------------------------------------------------------------
-- atmosphere model, the shader's math for single directions.  Units are km.
--------------------------------------------------------------------------
local R_EARTH, R_ATMO = 6371, 6471
local H_R, H_M, EYE_H = 8, 1.2, 0.2
local BETA_R = { 5.8e-3, 13.5e-3, 33.1e-3 }
local BETA_O = { 0.65e-3, 1.881e-3, 0.085e-3 } -- ozone, or twilight goes green
local O_CENTER, O_WIDTH = 25, 15
local BETA_M, MIE_G, MIE_EXT = 5e-3, 0.76, 1.1
local N_VIEW, N_LIGHT = 8, 3
local DISC_STEPS = 12
local SUN_DISC = 0.15
local EXPOSURE = 1.2 -- soft shoulder per channel, same as the shader
local SUN_COL = { 1, 0.96, 0.9 }
local MOON_COL = { 0.55, 0.7, 1 }
local exp, sqrt, max, min = math.exp, math.sqrt, math.max, math.min

local function exitDist(ox, oy, oz, dx, dy, dz, r)
	local b = ox * dx + oy * dy + oz * dz
	local c = ox * ox + oy * oy + oz * oz - r * r

	return -b + sqrt(max(b * b - c, 0))
end

local function density(h)
	h = max(h, 0)

	return exp(-h / H_R), exp(-h / H_M), max(0, 1 - math.abs(h - O_CENTER) / O_WIDTH)
end

local function extinction(oR, oM, oO)
	return BETA_R[1] * oR + BETA_M * MIE_EXT * oM + BETA_O[1] * oO,
		BETA_R[2] * oR + BETA_M * MIE_EXT * oM + BETA_O[2] * oO,
		BETA_R[3] * oR + BETA_M * MIE_EXT * oM + BETA_O[3] * oO
end

-- optical depth from p toward the light, zero when the earth is in the way
local function lightDepth(px, py, pz, lx, ly, lz)
	local b = px * lx + py * ly + pz * lz
	local c = px * px + py * py + pz * pz - R_EARTH * R_EARTH
	if b < 0 and b * b > c then return 0, 0, 0, 0 end

	local len = exitDist(px, py, pz, lx, ly, lz, R_ATMO)
	local ds = len / N_LIGHT
	local oR, oM, oO = 0, 0, 0
	for i = 0, N_LIGHT - 1 do
		local t = ds * (i + 0.5)
		local qx, qy, qz = px + lx * t, py + ly * t, pz + lz * t
		local dR, dM, dO = density(sqrt(qx * qx + qy * qy + qz * qz) - R_EARTH)
		oR, oM, oO = oR + dR * ds, oM + dM * ds, oO + dO * ds
	end

	return oR, oM, oO, 1
end

-- in-scattered light and transmittance along a view ray of length len
local function scatter(ox, oy, oz, dx, dy, dz, len, lx, ly, lz, lr, lg, lb)
	local mu = dx * lx + dy * ly + dz * lz
	local phaseR = 3 / (16 * math.pi) * (1 + mu * mu)
	local g2 = MIE_G * MIE_G
	local phaseM = 3 / (8 * math.pi) * (1 - g2) * (1 + mu * mu) / ((2 + g2) * (1 + g2 - 2 * MIE_G * mu) ^ 1.5)

	local oR, oM, oO = 0, 0, 0
	local sR1, sR2, sR3, sM1, sM2, sM3 = 0, 0, 0, 0, 0, 0
	local tPrev = 0
	for i = 0, N_VIEW - 1 do
		-- samples crowd toward the eye, where the dense air is
		local u1 = (i + 1) / N_VIEW
		local tNext = len * u1 * u1
		local ds = tNext - tPrev
		local t = tPrev + ds * 0.5
		tPrev = tNext
		local qx, qy, qz = ox + dx * t, oy + dy * t, oz + dz * t
		local dR, dM, dO = density(sqrt(qx * qx + qy * qy + qz * qz) - R_EARTH)
		dR, dM, dO = dR * ds, dM * ds, dO * ds
		oR, oM, oO = oR + dR, oM + dM, oO + dO

		local lR, lM, lO, lit = lightDepth(qx, qy, qz, lx, ly, lz)
		if lit > 0 then
			local e1, e2, e3 = extinction(oR + lR, oM + lM, oO + lO)
			local a1, a2, a3 = exp(-e1), exp(-e2), exp(-e3)
			sR1, sR2, sR3 = sR1 + a1 * dR, sR2 + a2 * dR, sR3 + a3 * dR
			sM1, sM2, sM3 = sM1 + a1 * dM, sM2 + a2 * dM, sM3 + a3 * dM
		end
	end

	local e1, e2, e3 = extinction(oR, oM, oO)

	return lr * (sR1 * BETA_R[1] * phaseR + sM1 * BETA_M * phaseM),
		lg * (sR2 * BETA_R[2] * phaseR + sM2 * BETA_M * phaseM),
		lb * (sR3 * BETA_R[3] * phaseR + sM3 * BETA_M * phaseM),
		exp(-e1), exp(-e2), exp(-e3)
end

local function shoulder1(v)
	return 1 - exp(-max(v, 0) * EXPOSURE)
end

local function shoulder(r, g, b)
	return shoulder1(r), shoulder1(g), shoulder1(b)
end

-- sky radiance in direction d (linear, after the shoulder like the shader)
local function radiance(dx, dy, dz, sun, moon)
	local ox, oy, oz = 0, 0, R_EARTH + EYE_H
	local b = oz * dz
	local c = oz * oz - R_EARTH * R_EARTH
	local disc = b * b - c
	local ground = b < 0 and disc > 0
	local len = ground and (-b - sqrt(disc)) or exitDist(ox, oy, oz, dx, dy, dz, R_ATMO)

	local si, mi = 20, 20 * MOON_INTENSITY * moonGain
	local r, g, bl, t1, t2, t3 = scatter(ox, oy, oz, dx, dy, dz, len, sun.x, sun.y, sun.z, SUN_COL[1] * si, SUN_COL[2] * si, SUN_COL[3] * si)
	local r2, g2, b2 = scatter(ox, oy, oz, dx, dy, dz, len, moon.x, moon.y, moon.z, MOON_COL[1] * mi, MOON_COL[2] * mi, MOON_COL[3] * mi)
	r, g, bl = r + r2, g + g2, bl + b2
	if ground then
		local sunUp = max(0, min(1, sun.z + 0.05))
		local k = 0.18 / math.pi * 0.05 * si * sunUp
		r, g, bl = r + SUN_COL[1] * k * t1, g + SUN_COL[2] * k * t2, bl + SUN_COL[3] * k * t3
	end

	return shoulder(r, g, bl)
end

-- transmittance from altitude h km toward light l
local function transmittance(h, l)
	local oR, oM, oO, lit = lightDepth(0, 0, R_EARTH + h, l.x, l.y, l.z)
	if lit == 0 then return 0, 0, 0 end
	local e1, e2, e3 = extinction(oR, oM, oO)

	return exp(-e1), exp(-e2), exp(-e3)
end

local function discTransmittance(l)
	local ox, oy, oz = 0, 0, R_EARTH + EYE_H
	local len = exitDist(ox, oy, oz, l.x, l.y, l.z, R_ATMO)
	local oR, oM, oO, tPrev = 0, 0, 0, 0
	for i = 1, DISC_STEPS do
		local u = i / DISC_STEPS
		local tNext = len * u * u
		local ds = tNext - tPrev
		local t = tPrev + ds * 0.5
		tPrev = tNext
		local qx, qy, qz = ox + l.x * t, oy + l.y * t, oz + l.z * t
		local dR, dM, dO = density(sqrt(qx * qx + qy * qy + qz * qz) - R_EARTH)
		oR, oM, oO = oR + dR * ds, oM + dM * ds, oO + dO * ds
	end

	local e1, e2, e3 = extinction(oR, oM, oO)

	return exp(-e1), exp(-e2), exp(-e3)
end

local function toSRGB(v)
	v = max(0, min(1, v))

	return v <= 0.0031308 and v * 12.92 or 1.055 * v ^ (1 / 2.4) - 0.055
end

--------------------------------------------------------------------------
-- derived state: sun, moon, fog colour, sky colours and cloud lighting
--------------------------------------------------------------------------
local state = {
	sun = Vector(0, 0, 1), moon = Vector(0, 0, -1), elev = 90,
	fog = { 255, 255, 255 }, overcast = 0,
	horizon = { 0.5, 0.6, 0.7 }, zenith = { 0.2, 0.35, 0.7 },
	light = { 1, 1, 1 }, amb = { 0.3, 0.4, 0.6 }, lightDir = Vector(0, 0, 1),
	disc = { 0, 0, 0 },
}

local lutDirty = true

local function overcastLevel()
	return math.Clamp(procsky.theme.overcast or 0, 0, 1)
end

local active = false

local function todLights()
	local C = tod and tod.CurrentParams
	local sun = C and isangle(C.sun_angles) and -C.sun_angles:Forward() or Vector(0, 0, 1)
	local moon = C and isangle(C.moon_angles) and -C.moon_angles:Forward() or -sun

	return sun, moon, shaderpack.Elevation(sun)
end

local function updateState()
	local theme = procsky.theme
	local mul, fogK = theme.tintMul or ONE, theme.fogScale or 1
	moonGain = theme.moonVisible == false and 0 or 1

	local sun, moon, elev = todLights()
	state.sun, state.moon, state.elev = sun, moon, elev
	local o = overcastLevel()
	state.overcast = o

	-- fog: the horizon averaged over 8 azimuths, grey at its own brightness when overcast
	local fr, fg, fb = 0, 0, 0
	local ce, se = math.cos(HORIZON_ELEV), math.sin(HORIZON_ELEV)
	for i = 0, 7 do
		local a = i * math.pi / 4
		local r, g, b = radiance(math.cos(a) * ce, math.sin(a) * ce, se, sun, moon)
		fr, fg, fb = fr + r, fg + g, fb + b
	end

	fr, fg, fb = fr / 8, fg / 8, fb / 8
	local lum = 0.2126 * fr + 0.7152 * fg + 0.0722 * fb
	fr, fg, fb = fr + (lum - fr) * o, fg + (lum - fg) * o, fb + (lum - fb) * o
	state.fog[1] = toSRGB(fr * fogK * mul[1]) * 255
	state.fog[2] = toSRGB(fg * fogK * mul[2]) * 255
	state.fog[3] = toSRGB(fb * fogK * mul[3]) * 255

	-- clouds: direct light through the air above the layer, ambient from the
	-- sky halfway up opposite the sun and at the zenith
	local s1, s2, s3 = transmittance(CLOUD_H, sun)
	local m1, m2, m3 = transmittance(CLOUD_H, moon)
	local sunUp = max(0, min(1, (elev + 2) / 6))
	local moonUp = max(0, min(1, (moon.z + 0.02) / 0.1)) * moonGain
	local light = state.light
	light[1] = (SUN_COL[1] * s1 * sunUp + MOON_COL[1] * m1 * moonUp * 0.25) * mul[1]
	light[2] = (SUN_COL[2] * s2 * sunUp + MOON_COL[2] * m2 * moonUp * 0.25) * mul[2]
	light[3] = (SUN_COL[3] * s3 * sunUp + MOON_COL[3] * m3 * moonUp * 0.25) * mul[3]

	local ax, ay = -sun.x, -sun.y
	local al = sqrt(ax * ax + ay * ay)
	if al < 0.01 then ax, ay, al = 1, 0, 1 end
	local ar, ag, ab = radiance(ax / al * 0.7, ay / al * 0.7, 0.714, sun, moon)
	local zr, zg, zb = radiance(0, 0, 1, sun, moon)
	state.amb[1], state.amb[2], state.amb[3] = (ar + zr) * 0.5 * mul[1], (ag + zg) * 0.5 * mul[2], (ab + zb) * 0.5 * mul[3]

	local skyK = INTENSITY * (1 - 0.3 * o)
	local zl = 0.2126 * zr + 0.7152 * zg + 0.0722 * zb
	local hz, zn = state.horizon, state.zenith
	hz[1], hz[2], hz[3] = fr * skyK, fg * skyK, fb * skyK
	zn[1] = (zr + (zl - zr) * o) * skyK
	zn[2] = (zg + (zl - zg) * o) * skyK
	zn[3] = (zb + (zl - zb) * o) * skyK

	state.lightDir = sunUp > 0.05 and sun or (moonUp > 0 and moon or Vector(0, 0, 1))

	local d1, d2, d3 = discTransmittance(sun)
	local dk = 20 * SUN_DISC
	state.disc[1], state.disc[2], state.disc[3] = SUN_COL[1] * dk * d1, SUN_COL[2] * dk * d2, SUN_COL[3] * dk * d3
	lutDirty = true
end

function procsky.IsActive()
	return active
end

-- direction to the sun and moon, and the sun's elevation in degrees
function procsky.GetLights()
	return state.sun, state.moon, state.elev
end

-- light direction, direct light colour and ambient colour for the clouds
function procsky.GetCloudLighting()
	return state.lightDir, state.light, state.amb
end

-- linear horizon and zenith colours of the sky without tonemap scale
function procsky.GetSkyColors()
	return state.horizon, state.zenith
end

function procsky.GetOvercast()
	return state.overcast
end

--------------------------------------------------------------------------
-- theme: the season's look (halloween/tod.lua).  Every key is optional.
--   moonVisible  false hides the moon: its glow here and tod's moon model
--   clouds       false hides the build clouds (sh_tod_build)
--   auroraHue    hue shift of the auroras in radians (sh_aurora)
--   stars        star brightness multiplier (sh_aurora)
--   airglow      horizon glow brightness multiplier (sh_aurora)
--   fogScale     fog colour multiplier
--   tintMul      { r, g, b } multiplied into the fog colour and the cloud light
--   tint         DrawColorModify params drawn every frame
--   overcast     0..1: grey fog, a dimmed atmosphere, a cloud deck over the
--                sky (sh_tod_build) and no sun shafts (snow and rain set it)
--   overcastBrightness  deck brightness, 1 is snow's white stratus
--------------------------------------------------------------------------

-- tod's moon model draws through skyboxer's c_moon hook, held here while hidden
local moonHook

local function syncMoon()
	if moonGain > 0 then
		if moonHook then
			skyboxer.AddHook("c_moon", moonHook)
			moonHook = nil
		end
	else
		local removed = skyboxer.RemoveHook("c_moon")
		if removed then
			moonHook = moonHook or removed[1]
		end
	end
end

function procsky.SetTheme(theme)
	procsky.theme = theme or {}
	updateState()
	syncMoon()
end

function procsky.GetTheme()
	return procsky.theme
end

--------------------------------------------------------------------------
-- fog: tod's hook backs off when STOP_STEALING_FOG_CONTROLS is set, so this
-- one applies tod's range with the horizon colour
--------------------------------------------------------------------------
local function setupFog(scale)
	local C = tod and tod.CurrentParams
	if not C then return end
	scale = scale or 1
	render.FogMode(1)
	render.FogStart((C.fog_start or 0) * scale)
	render.FogEnd((C.fog_end or 32000) * scale)
	render.FogColor(state.fog[1], state.fog[2], state.fog[3])
	render.FogMaxDensity(C.fog_max_density or 1)

	return true
end

--------------------------------------------------------------------------
-- rendering
--------------------------------------------------------------------------
local MAT, LUT_MAT, lut
local LUT_W, LUT_H = 256, 128

local function renderLut()
	if not lutDirty then return end
	if not lut then
		local rt = GetRenderTargetEx("ms_procsky_lut_" .. LUT_W .. "x" .. LUT_H, LUT_W, LUT_H, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 8, 0, IMAGE_FORMAT_RGBA16161616F)
		if not rt or rt:IsError() or rt:Width() ~= LUT_W then return end
		lut = rt
		MAT:SetTexture("$basetexture", lut)
	end

	lutDirty = false
	local sun, moon = state.sun, state.moon
	setConstant(LUT_MAT, "$c0", sun.x, sun.y, sun.z)
	setConstant(LUT_MAT, "$c1", moon.x, moon.y, moon.z, MOON_INTENSITY * moonGain)

	render.PushRenderTarget(lut)
	render.SetMaterial(LUT_MAT)
	render.DrawScreenQuad(true)
	render.PopRenderTarget()
end

-- basis from EyeAngles, which is right inside a RenderView too, and the fan
-- from the view setup (fov is the aspect-adjusted horizontal one)
local function viewRays()
	local ang = EyeAngles()
	local halfW, halfH = shaderpack.ViewTan()

	return ang:Forward(), ang:Right(), halfW, halfH
end

local function drawSky()
	if not lut then return end
	local fwd, right, halfW, halfH = viewRays()
	local sun, disc = state.sun, state.disc

	setConstant(MAT, "$c0", fwd.x, fwd.y, fwd.z, INTENSITY * render.GetToneMappingScaleLinear().x * (1 - 0.3 * state.overcast))
	setConstant(MAT, "$c1", right.x * halfW, right.y * halfW, right.z * halfW, halfH)
	setConstant(MAT, "$c2", sun.x, sun.y, sun.z)
	setConstant(MAT, "$c3", disc[1], disc[2], disc[3])

	render.SetMaterial(MAT)
	render.DrawScreenQuad(true)
end

local nextUpdate = 0
local function think()
	if RealTime() < nextUpdate then return end
	nextUpdate = RealTime() + UPDATE_INTERVAL
	updateState()
	syncMoon()
	if active and tod and tod.CurrentParams then
		tod.CurrentParams.STOP_STEALING_FOG_CONTROLS = true
	end
end

local function stop()
	active = false
	skyboxer.RemoveHook("a_procsky")
	hook.Remove("PreRender", "ms_procsky")
	hook.Remove("SetupWorldFog", "ms_procsky")
	hook.Remove("SetupSkyboxFog", "ms_procsky")
	if tod and tod.CurrentParams then
		tod.CurrentParams.STOP_STEALING_FOG_CONTROLS = nil
	end
end

local function start()
	stop()
	MAT = MAT or CreateShaderMaterial("ms_procsky_" .. os.time(), {
		["$pixshader"] = "sky_ps30",
		["$vertexshader"] = "aurora_vs30",
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$c0_x"] = 1, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 1,
		["$c1_x"] = 0, ["$c1_y"] = 1, ["$c1_z"] = 0, ["$c1_w"] = 1,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 1, ["$c2_w"] = 0,
		["$c3_x"] = 0, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
	})

	LUT_MAT = LUT_MAT or CreateShaderMaterial("ms_procsky_lut_" .. os.time(), {
		["$pixshader"] = "skylut_ps30",
		["$vertexshader"] = "aurora_vs30",
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 1, ["$c0_w"] = LUT_W,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = -1, ["$c1_w"] = 0,
		["$c2_x"] = 1, ["$c2_y"] = LUT_H, ["$c2_z"] = 0, ["$c2_w"] = 0,
	})

	updateState()
	active = true
	hook.Add("PreRender", "ms_procsky", renderLut)
	skyboxer.AddHook("a_procsky", drawSky)
	hook.Add("SetupWorldFog", "ms_procsky", setupFog)
	hook.Add("SetupSkyboxFog", "ms_procsky", setupFog)
	if tod and tod.CurrentParams then
		tod.CurrentParams.STOP_STEALING_FOG_CONTROLS = true
	end
end

local apply = shaderpack.Toggle("ms_procsky", SKY_ENABLED, SHADERS, start, stop)

-- the lights, the theme and the tint stay live while the sky itself is off:
-- the sun shafts, the clouds and the night sky read them
hook.Add("Think", "ms_procsky", think)
hook.Add("RenderScreenspaceEffects", "ms_procsky_tint", function()
	local tint = procsky.theme.tint
	if tint then
		DrawColorModify(tint)
	end
end)

apply()
