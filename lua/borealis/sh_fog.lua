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
-- wins: the engine's depth pass (exact, but only what the engine draws) and the
-- coarse slice capture in sh_depthslices, shared with the volumetric clouds, so
-- Lua-drawn things like PAC3 parts occlude the fog too.
--
-- Density follows tod's weather: fog weather (tod.fog) is a ground layer,
-- rain (tod.rain) a taller thin haze, the two profiles blended by their share
-- of the total.  The base follows the ground under the player.  Colour is the
-- horizon colour tod set as the engine fog colour.

local FOG_ENABLED = CreateClientConVar("cl_draw_fog", "1", true, false, "draw volumetric fog in fog and rain weather")

local FOG_PROFILE = { density = 0.0007, falloff = 250, noise = 0.8 } -- extinction per unit at the base, height falloff in units, noise strength
local RAIN_PROFILE = { density = 0.00025, falloff = 600, noise = 0.4 }
local SUN_GAIN = 1 -- sun in-scatter share, 0..1
local NEAR = 12 -- the fog quad sits this far in front of the eye
local QUAD_OVERSIZE = 6 -- quads are sized past the frustum, the shader uses the clip position
local BASE_LIFT = 40 -- fog base above the ground under the player
local BASE_RATE = 0.5 -- share of the remaining gap closed per second when the ground changes
local BASE_TRACE_INTERVAL = 0.25
local PS, VS = "fog_ps30", "fog_vs30"

--------------------------------------------------------------------------
-- material, a new one every start so a kept one never lacks a constant
--------------------------------------------------------------------------
local MAT
local materialSerial = 0

-- The render targets do not exist yet while the map loads, and asking for one
-- then hands back a 32 x 32 error texture that answers IsError with false.
-- Bound as the depth, it reads as garbage and every pixel marches the full
-- distance, so the frame comes out an opaque wall.  A retry hits this and a
-- cold start does not: the shaders are already mounted on a retry, so start
-- runs at load instead of waiting for ShaderMounted.
local function usableRT(t)
	return t ~= nil and not t:IsError() and t:Width() > 64
end

local function build()
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
local quadColor = Color(SUN_GAIN * 255, 0, 0, 255)
local ORDER = 20 -- the near volume: this composites over the clouds

local function draw()
	local density, falloff, noise = weather()
	if density <= 0 then return end

	-- rebound every frame: the targets are recreated across a map change and a
	-- material built before they existed holds the error texture forever
	local depth, fb = render.GetResolvedFullFrameDepth(), render.GetScreenEffectTexture()
	if not usableRT(depth) or not usableRT(fb) then return end
	if not MAT and not build() then return end

	MAT:SetTexture("$texture1", depth)
	MAT:SetTexture("$basetexture", fb)

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

	depthslices.Capture()
	render.UpdateScreenEffectTexture()

	-- alpha writes stay off so the slice indices survive for the next effect;
	-- sh_depthslices puts the frame's alpha back after the translucent pass
	quadColor.g = noise * 255
	depthslices.KeepAlpha(function()
		render.OverrideDepthEnable(true, false)
		render.SetMaterial(MAT)
		render.DrawQuadEasy(eye + fwd * NEAR, -fwd, halfW * NEAR * QUAD_OVERSIZE, halfH * NEAR * QUAD_OVERSIZE, quadColor, 0)
		render.OverrideDepthEnable(false, false)
	end)

	return true
end

--------------------------------------------------------------------------
-- lifecycle
--------------------------------------------------------------------------
local function stop()
	hook.Remove("Think", "ms_fog")
	hook.Remove("NeedsDepthPass", "ms_fog")
	hook.Remove("PreDrawTranslucentRenderables", "ms_fog")
	depthslices.RemoveEffect("ms_fog")
	active = false
end

local function start()
	stop()
	hook.Add("Think", "ms_fog", think)
	-- NeedsDepthPass takes the FIRST non-nil return of all its hooks, so
	-- returning false here would cancel another consumer's true and leave the
	-- depth buffer stale.  Ask when it is needed, stay silent otherwise.
	hook.Add("NeedsDepthPass", "ms_fog", function()
		if active then return true end
	end)
	depthslices.AddEffect("ms_fog", ORDER, draw, true)
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
