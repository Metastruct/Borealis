if SERVER then return end

-- Coarse depth capture of the real frame, shared by the volumetric fog and the
-- volumetric clouds.  The engine's depth pass only holds what the engine draws,
-- so anything coming from a Lua hook (PAC3 parts, clientside models drawn by
-- hand) is missing from it and a volumetric effect paints straight over it.
--
-- This writes, into the frame's alpha, the index of the farthest slice still in
-- front of each surface: SLICES depth-tested alpha-only quads at log-spaced
-- distances, after a near quad that ignores depth to clear.  A shader turns the
-- index back into a distance and takes whichever is nearer, that or the depth
-- pass.  Alpha writes only, blending forced to replace, and the colour material
-- does not write depth.  3D quads throughout: the surface library ignores the
-- overrides.
--
-- One capture serves every effect in the frame, so an effect must draw its own
-- quad with alpha writes OFF or it wipes the indices the next one still needs.
-- The alpha is put back once, after the translucent pass.

depthslices = depthslices or {}

local SLICES = 32 -- both ends and the ratio are baked into fog_ps30 and vclouds_ps30
local NEAR = 16
local FAR = 8000
local QUAD_NEAR = 12 -- the clearing quad sits this far in front of the eye
local OVERSIZE = 6 -- quads are sized past the frustum

depthslices.SLICES, depthslices.NEAR, depthslices.FAR = SLICES, NEAR, FAR

local dist = {}
do
	local ratio = (FAR / NEAR) ^ (1 / (SLICES - 1))
	depthslices.RATIO = ratio
	for k = 0, SLICES - 1 do
		dist[k] = NEAR * ratio ^ k
	end
end

local ALPHA0 = Color(0, 0, 0, 0)
local ALPHA1 = Color(0, 0, 0, 255)
local sliceColor = Color(0, 0, 0, 0)
local capturedFrame = -1

local function quad(eye, fwd, halfW, halfH, t, col)
	render.DrawQuadEasy(eye + fwd * t, -fwd, halfW * t * OVERSIZE, halfH * t * OVERSIZE, col, 0)
end

-- Safe to call from several effects in one frame: only the first does the work.
function depthslices.Capture()
	if capturedFrame == FrameNumber() then return end
	capturedFrame = FrameNumber()

	local eye = EyePos()
	local fwd = EyeAngles():Forward()
	local vs = render.GetViewSetup()
	local halfW = math.tan(math.rad(vs.fov) * 0.5)
	local halfH = halfW / vs.aspect

	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	render.SetColorMaterial()
	render.OverrideDepthEnable(true, false)
	quad(eye, fwd, halfW, halfH, QUAD_NEAR, ALPHA0)
	render.OverrideDepthEnable(false, false)
	for k = 0, SLICES - 1 do
		sliceColor.a = k + 1
		quad(eye, fwd, halfW, halfH, dist[k], sliceColor)
	end
	render.OverrideBlend(false)
	render.OverrideAlphaWriteEnable(false, false)
	render.OverrideColorWriteEnable(false, false)
end

-- an effect's own quad must not touch alpha, or the next effect reads its
-- output instead of the slice indices
function depthslices.KeepAlpha(draw)
	render.OverrideAlphaWriteEnable(true, false)
	draw()
	render.OverrideAlphaWriteEnable(false, false)
end

hook.Add("PostDrawTranslucentRenderables", "ms_depthslices_restore", function(bDepth, bSkybox, b3DSky)
	if bDepth or bSkybox or b3DSky then return end
	if capturedFrame ~= FrameNumber() then return end

	local eye = EyePos()
	local fwd = EyeAngles():Forward()
	local vs = render.GetViewSetup()
	local halfW = math.tan(math.rad(vs.fov) * 0.5)
	local halfH = halfW / vs.aspect

	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	render.SetColorMaterial()
	render.OverrideDepthEnable(true, false)
	quad(eye, fwd, halfW, halfH, QUAD_NEAR, ALPHA1)
	render.OverrideDepthEnable(false, false)
	render.OverrideBlend(false)
	render.OverrideAlphaWriteEnable(false, false)
	render.OverrideColorWriteEnable(false, false)
end)
