local HAS_SHADER_TO_GMA = file.Exists("includes/modules/shader_to_gma.lua", "LUA")
if HAS_SHADER_TO_GMA then
	require("shader_to_gma")
end

if SERVER then
	if not resource.AddShader then return end

	resource.AddShader("fog_vs30")
	resource.AddShader("fog_ps30")
	resource.AddFile("materials/procsky/fognoise.vtf")

	return
end

-- Volumetric fog: a height layer ray marched per pixel by fog_ps30 and
-- composited over the frame before the translucent pass, so glass, particles
-- and the viewmodel draw on top.  Depth comes from two sources and the nearer
-- wins: the engine's depth pass (exact, but only what the engine draws) and a
-- coarse slice capture of the real frame (SLICES depth-tested alpha-only quads
-- writing their index into the frame's alpha, so Lua-drawn things like PAC3
-- parts occlude the fog too).
--
-- Density follows tod's weather: fog weather (tod.fog) is a ground layer,
-- rain (tod.rain) a taller thin haze, the two profiles blended by their share
-- of the total.  The base follows the ground under the player.  Colour is the
-- horizon colour tod set as the engine fog colour.

local FOG_ENABLED = CreateClientConVar("cl_draw_fog", "1", true, false, "draw volumetric fog in fog and rain weather")

local FOG_PROFILE = { density = 0.0002, falloff = 250, noise = 0.8 } -- extinction per unit at the base, height falloff in units, noise strength
local RAIN_PROFILE = { density = 0.00025, falloff = 600, noise = 0.4 }
local SUN_GAIN = 1 -- sun in-scatter share, 0..1
local NEAR = 12 -- the fog quad sits this far in front of the eye
local QUAD_OVERSIZE = 6 -- quads are sized past the frustum, the shader uses the clip position
local SLICES = 64 -- log-spaced from SLICE_NEAR to SLICE_FAR, both baked into fog_ps30 too
local SLICE_NEAR = 16
local SLICE_FAR = 5000
local BASE_LIFT = 40 -- fog base above the ground under the player
local BASE_RATE = 0.5 -- share of the remaining gap closed per second when the ground changes
local BASE_TRACE_INTERVAL = 0.25
local PS, VS = "fog_ps30", "fog_vs30"

local sliceDist = {}
do
	local ratio = (SLICE_FAR / SLICE_NEAR) ^ (1 / (SLICES - 1))
	for k = 0, SLICES - 1 do
		sliceDist[k] = SLICE_NEAR * ratio ^ k
	end
end

--------------------------------------------------------------------------
-- material, a new one every start so a kept one never lacks a constant
--------------------------------------------------------------------------
local MAT
local materialSerial = 0

local function build()
	local depth = render.GetResolvedFullFrameDepth()
	if not depth or depth:IsError() then return false end

	materialSerial = materialSerial + 1
	MAT = CreateMaterial("ms_fog_" .. os.time() .. "_" .. materialSerial, "screenspace_general", {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$basetexture"] = "",
		["$texture1"] = "",
		["$texture2"] = "procsky/fognoise",
		["$linearread_basetexture"] = 0,
		["$linearread_texture1"] = 1, -- depth and noise are data
		["$linearread_texture2"] = 1,
		["$linearwrite"] = 0,
		["$ignorez"] = 1,
		["$vertexcolor"] = 1,
		["$vertextransform"] = 1,
		["$additive"] = 0,
		["$alpha_blend"] = 0,
		["$nocull"] = 1,
		["<dx90"] = { ["$no_draw"] = 1 },
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
		["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 1, ["$c2_w"] = 0,
		["$c3_x"] = 1, ["$c3_y"] = 1, ["$c3_z"] = 1, ["$c3_w"] = 1,
	})
	MAT:SetTexture("$basetexture", render.GetScreenEffectTexture())
	MAT:SetTexture("$texture1", depth)

	return true
end

--------------------------------------------------------------------------
-- weather, sun and base
--------------------------------------------------------------------------
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

-- total density and the density-weighted falloff and noise strength, or 0
local function weather()
	local f = tod and tod.fog and tod.fog.amount or 0
	local r = tod and tod.rain and tod.rain.amount or 0
	local df, dr = FOG_PROFILE.density * f, RAIN_PROFILE.density * r
	local d = df + dr
	if d <= 0 then return 0 end
	local wf, wr = df / d, dr / d

	return d, FOG_PROFILE.falloff * wf + RAIN_PROFILE.falloff * wr, FOG_PROFILE.noise * wf + RAIN_PROFILE.noise * wr
end

local base, targetBase, nextTrace = nil, nil, 0

-- eased so level changes on stacked maps do not snap the layer
local function currentBase()
	local now = RealTime()
	if now >= nextTrace then
		nextTrace = now + BASE_TRACE_INTERVAL
		local eye = EyePos()
		local tr = util.TraceLine({ start = eye, endpos = eye - Vector(0, 0, 4000), mask = MASK_SOLID_BRUSHONLY })
		if tr.Hit then targetBase = tr.HitPos.z + BASE_LIFT end
	end
	if not targetBase then return base or EyePos().z - 24 end
	if not base then base = targetBase end
	base = base + (targetBase - base) * math.min(1, RealFrameTime() * BASE_RATE)

	return base
end

local active = false

local function think()
	active = weather() > 0
end

--------------------------------------------------------------------------
-- rendering
--------------------------------------------------------------------------
local ALPHA0 = Color(0, 0, 0, 0)
local sliceColor = Color(0, 0, 0, 0)
local quadColor = Color(SUN_GAIN * 255, 0, 0, 255)

-- frame alpha = index of the farthest slice in front of the surface, 0 nearer
-- than the first.  Alpha writes only, blending forced to replace, the near
-- quad ignores depth to clear, the slices are depth tested with the colour
-- material which does not write depth.  3D quads: the surface library ignores
-- the overrides.
local function captureSlices(eye, fwd, halfW, halfH)
	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	render.SetColorMaterial()
	render.OverrideDepthEnable(true, false)
	render.DrawQuadEasy(eye + fwd * NEAR, -fwd, halfW * NEAR * QUAD_OVERSIZE, halfH * NEAR * QUAD_OVERSIZE, ALPHA0, 0)
	render.OverrideDepthEnable(false, false)
	for k = 0, SLICES - 1 do
		local t = sliceDist[k]
		sliceColor.a = k + 1
		render.DrawQuadEasy(eye + fwd * t, -fwd, halfW * t * QUAD_OVERSIZE, halfH * t * QUAD_OVERSIZE, sliceColor, 0)
	end
	render.OverrideBlend(false)
	render.OverrideAlphaWriteEnable(false, false)
	render.OverrideColorWriteEnable(false, false)
end

local function draw(bDepth, bSkybox, b3DSky)
	if bDepth or bSkybox or b3DSky or render.GetRenderTarget() then return end
	local density, falloff, noise = weather()
	if density <= 0 then return end

	local eye = EyePos()
	local fwd = EyeAngles():Forward()
	local vs = render.GetViewSetup()
	local halfW = math.tan(math.rad(vs.fov) * 0.5)
	local halfH = halfW / vs.aspect
	local sun = sunDir()
	local tonemap = render.GetToneMappingScaleLinear().x
	local fr, fg, fb = render.GetFogColor()

	MAT:SetFloat("$c0_x", eye.x)
	MAT:SetFloat("$c0_y", eye.y)
	MAT:SetFloat("$c0_z", eye.z)
	MAT:SetFloat("$c0_w", density)
	MAT:SetFloat("$c1_x", fwd.x)
	MAT:SetFloat("$c1_y", fwd.y)
	MAT:SetFloat("$c1_z", fwd.z)
	MAT:SetFloat("$c1_w", CurTime() % 3600)
	MAT:SetFloat("$c2_x", sun.x)
	MAT:SetFloat("$c2_y", sun.y)
	MAT:SetFloat("$c2_z", sun.z)
	MAT:SetFloat("$c2_w", currentBase())
	MAT:SetFloat("$c3_x", toLinear(fr) * tonemap)
	MAT:SetFloat("$c3_y", toLinear(fg) * tonemap)
	MAT:SetFloat("$c3_z", toLinear(fb) * tonemap)
	MAT:SetFloat("$c3_w", falloff)

	captureSlices(eye, fwd, halfW, halfH)
	render.UpdateScreenEffectTexture()

	-- the fog quad writes alpha 1 everywhere, restoring the frame's alpha
	quadColor.g = noise * 255
	render.OverrideDepthEnable(true, false)
	render.SetMaterial(MAT)
	render.DrawQuadEasy(eye + fwd * NEAR, -fwd, halfW * NEAR * QUAD_OVERSIZE, halfH * NEAR * QUAD_OVERSIZE, quadColor, 0)
	render.OverrideDepthEnable(false, false)
end

--------------------------------------------------------------------------
-- lifecycle
--------------------------------------------------------------------------
local function stop()
	hook.Remove("Think", "ms_fog")
	hook.Remove("NeedsDepthPass", "ms_fog")
	hook.Remove("PreDrawTranslucentRenderables", "ms_fog")
	active = false
end

local function start()
	stop()
	if not build() then return end
	hook.Add("Think", "ms_fog", think)
	hook.Add("NeedsDepthPass", "ms_fog", function() return active end)
	hook.Add("PreDrawTranslucentRenderables", "ms_fog", draw)
end

local function shadersAvailable()
	return file.Exists("shaders/fxc/" .. PS .. ".vcs", "GAME") and file.Exists("shaders/fxc/" .. VS .. ".vcs", "GAME")
end

local function apply()
	if not FOG_ENABLED:GetBool() then
		stop()
		return
	end

	if shadersAvailable() then
		start()
	elseif HAS_SHADER_TO_GMA and not SHADER_MOUNTED then
		hook.Add("ShaderMounted", "ms_fog", function()
			hook.Remove("ShaderMounted", "ms_fog")
			if FOG_ENABLED:GetBool() and shadersAvailable() then
				start()
			end
		end)
	end
end

cvars.RemoveChangeCallback("cl_draw_fog", "ms_fog")
cvars.AddChangeCallback("cl_draw_fog", apply, "ms_fog")
hook.Remove("ShaderMounted", "ms_fog")
apply()
