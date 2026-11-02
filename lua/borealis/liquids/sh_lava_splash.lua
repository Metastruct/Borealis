local PS, VS = "borealis_lavasplash_ps30", "borealis_fog_vs30"
local NET = "borealis_lava_splash"
local NOISE_TEXTURE = "shaderpack/procsky/fognoise"

if SERVER then
	shaderpack.AddResources({ VS, PS }, { NOISE_TEXTURE })
	util.AddNetworkString(NET)

	local lava = shaderpack.lava or {}
	shaderpack.lava = lava

	local SEND_GAP = 0.05
	local lastSend = 0

	function lava.Splash(ent)
		local now = CurTime()
		if now - lastSend < SEND_GAP then return end

		lastSend = now
		local pos = ent:WorldSpaceCenter()
		net.Start(NET)
		net.WriteVector(pos)
		net.WriteFloat(ent:BoundingRadius())
		net.WriteFloat(ent:GetVelocity().z)
		net.SendPVS(pos)
	end

	return
end

local lava, depthslices = shaderpack.lava, shaderpack.depthslices
local setConstant = shaderpack.SetConstant

local ORDER = 0.65
local GLOW_MAT = "sprites/light_glow02_add"
local SMOKE_MAT = "particle/particle_smokegrenade"
local LAVA_TEXTURE = "metastruct_4/rock_lava01a"
local SPLASH_SOUND = "^ambient/water/water_splash%d%.wav$"
local SPLASH_MATS = { "effects/splash1", "effects/splash2", "effects/splash3", "effects/splash4", "effects/splashwake1", "effects/splashwake3", "effects/splashwake4" }
local SIZZLES = { "ambient/levels/canals/toxic_slime_sizzle2.wav", "ambient/levels/canals/toxic_slime_sizzle3.wav", "ambient/levels/canals/toxic_slime_sizzle4.wav" }
local GURGLES = {}
for i = 2, 8 do
	GURGLES[#GURGLES + 1] = "ambient/levels/canals/toxic_slime_gurgle" .. i .. ".wav"
end

local IGNITE = "ambient/fire/ignite.wav"
local MATERIAL_VAR_NO_DRAW = 4

local SURFACE_TOLERANCE = 4
local BULLET_SCALE = 0.6
local MIN_SCALE, MAX_SCALE = 0.3, 3
local ENTITY_RADIUS, ENTITY_SPEED = 24, 600
local GRAVITY = 750
local DROPS, DROPS_MAX, DROP_LIFE = 22, 80, 1.4
local CORE, SMOKE, SMOKE_MAX = 3, 3, 8
local LIGHTS, LIGHT_KEY = 4, 0x1A7A0
local IMPACT_RADIUS, IMPACT_LIFE, IMPACT_HEIGHT, IMPACTS_MAX = 90, 2.5, 1.5, 24
local CROWN_SEGMENTS, CROWN_RINGS, CROWNS_MAX, CROWN_VARIANTS = 18, 5, 16, 8
local CROWN_RADIUS, CROWN_HEIGHT, CROWN_LIFE, CROWN_FLARE, CROWN_FLING = 22, 70, 0.8, 0.8, 0.45
local SPATTER_LIFE, SPATTER_SIZE, SPATTERS_MAX = 3, 10, 64
local TRACE_STEPS, TRACE_TAIL = 5, 0.4
local EMISSIVE, GLOW_BOOST, CROWN_BOOST, LIGHT_BRIGHTNESS = 2.2, Vector(2.5, 2.5, 2.5), Vector(2.6, 2.6, 2.6), 5
local SCALE_JITTER, LEAN_MAX, JET_CHANCE, JET_BOOST = 0.25, 0.5, 0.15, 1.6
local FOLLOW_CHANCE, FOLLOW_MAX, FOLLOW_DISTANCE = 0.4, 3, 60

local impacts, crowns, spatters, pending, later = {}, {}, {}, {}, {}
local emitter
local active = false
local IMPACT_MAT, CROWN_MAT, SPATTER_MAT, GLOW

local function build()
	IMPACT_MAT = CreateShaderMaterial("borealis_lavasplash_" .. os.time(), {
		["$pixshader"] = PS,
		["$vertexshader"] = VS,
		["$texture1"] = NOISE_TEXTURE,
		["$linearread_texture1"] = 1,
		["$linearwrite"] = 0,
		["$additive"] = 1,
		["$nocull"] = 1,
		["$ignorez"] = 0,
		["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
		["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
	})
	CROWN_MAT = CreateMaterial("borealis_lava_crown", "UnlitGeneric", {
		["$basetexture"] = LAVA_TEXTURE,
		["$vertexcolor"] = 1,
		["$vertexalpha"] = 1,
		["$translucent"] = 1,
		["$nocull"] = 1,
	})
	CROWN_MAT:SetVector("$color", CROWN_BOOST)
	GLOW = CreateMaterial("borealis_lava_glow", "UnlitGeneric", {
		["$basetexture"] = Material(GLOW_MAT):GetString("$basetexture") or "sprites/light_glow02",
		["$additive"] = 1,
		["$vertexcolor"] = 1,
		["$vertexalpha"] = 1,
		["$nocull"] = 1,
	})
	GLOW:SetVector("$color", GLOW_BOOST)
	SPATTER_MAT = GLOW
end

local function hideSplashes(hide)
	if hide == (lava.splashesHidden or false) then return end

	lava.splashesHidden = hide
	for _, name in ipairs(SPLASH_MATS) do
		local mat = Material(name)
		local flags = mat:GetInt("$flags")
		mat:SetInt("$flags", hide and bit.bor(flags, MATERIAL_VAR_NO_DRAW) or bit.band(flags, bit.bnot(MATERIAL_VAR_NO_DRAW)))
	end
end

local landTrace = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector(), output = {} }

local function arcAt(out, o, v, t)
	out:SetUnpacked(o.x + v.x * t, o.y + v.y * t, o.z + v.z * t - 0.5 * GRAVITY * t * t)
end

local function predictLanding(o, v, surface)
	local tSurface = (v.z + math.sqrt(math.max(v.z * v.z + 2 * GRAVITY * (o.z - surface), 0))) / GRAVITY
	if lava.Surface(o.x + v.x * tSurface, o.y + v.y * tSurface) then return end

	local tEnd = math.min(DROP_LIFE, tSurface + TRACE_TAIL)
	local tPrev = 0
	landTrace.start:Set(o)
	for s = 1, TRACE_STEPS do
		local t = tEnd * s / TRACE_STEPS
		arcAt(landTrace.endpos, o, v, t)
		local tr = util.TraceLine(landTrace)
		if tr.Hit then
			if tr.StartSolid or tr.HitPos.z < surface then return end

			return tPrev + (t - tPrev) * tr.Fraction, Vector(tr.HitPos), Vector(tr.HitNormal)
		end

		landTrace.start:Set(landTrace.endpos)
		tPrev = t
	end
end

local function dropThink(surface)
	return function(p)
		local f = p:GetLifeTime() / p:GetDieTime()
		p:SetColor(255 - 90 * f, 170 - 140 * f, 60 - 50 * f)
		if p:GetVelocity().z < 0 and p:GetPos().z < surface then
			p:SetLifeTime(p:GetDieTime())

			return
		end

		p:SetNextThink(CurTime())
	end
end

local gravity = Vector(0, 0, -GRAVITY)

local function launchDrop(origin, vel, think, surface)
	local p = emitter:Add(GLOW, origin)
	if not p then return end

	local life = DROP_LIFE
	local t, pos, normal = predictLanding(origin, vel, surface)
	if t then
		life = t
		pending[#pending + 1] = { at = CurTime() + t, pos = pos, normal = normal }
	end

	p:SetVelocity(vel)
	p:SetGravity(gravity)
	p:SetDieTime(life)
	p:SetStartAlpha(255)
	p:SetEndAlpha(255)
	p:SetStartSize(math.Rand(3, 5.5))
	p:SetEndSize(1.5)
	p:SetStartLength(math.Rand(10, 18))
	p:SetEndLength(4)
	p:SetColor(255, 170, 60)
	p:SetLighting(false)
	p:SetThinkFunction(think)
	p:SetNextThink(CurTime())
end

local vel, spot = Vector(), Vector()

local function burst(pos, scale, lean)
	local flash = emitter:Add(GLOW, pos)
	if flash then
		flash:SetDieTime(math.Rand(0.25, 0.45))
		flash:SetStartAlpha(255)
		flash:SetEndAlpha(0)
		flash:SetStartSize(math.min(90 * scale * math.Rand(0.8, 1.3), 260))
		flash:SetEndSize(10)
		flash:SetColor(255, math.random(110, 170), math.random(30, 70))
		flash:SetLighting(false)
	end

	for _ = 1, CORE + math.random(0, 2) do
		local p = emitter:Add(GLOW, pos)
		if p then
			vel:SetUnpacked(math.Rand(-20, 20), math.Rand(-20, 20), math.Rand(60, 140) * scale)
			p:SetVelocity(vel)
			p:SetDieTime(math.Rand(0.35, 0.5))
			p:SetStartAlpha(255)
			p:SetEndAlpha(0)
			p:SetStartSize(math.Rand(10, 16) * scale)
			p:SetEndSize(2)
			p:SetColor(255, 180, 70)
			p:SetLighting(false)
		end
	end

	local speed = math.sqrt(scale)
	local think = dropThink(pos.z)
	for _ = 1, math.min(DROPS_MAX, math.Round(DROPS * scale ^ 1.2 * math.Rand(0.6, 1.4))) do
		local up = math.Rand(220, 420) * speed * (math.random() < JET_CHANCE and JET_BOOST or 1)
		local vx = (math.Rand(-140, 140) + lean.x * up) * speed
		local vy = (math.Rand(-140, 140) + lean.y * up) * speed
		launchDrop(pos, Vector(vx, vy, up), think, pos.z)
	end

	for _ = 1, math.min(SMOKE_MAX, math.ceil(SMOKE * scale)) do
		spot:SetUnpacked(pos.x + math.Rand(-12, 12) * scale, pos.y + math.Rand(-12, 12) * scale, pos.z + 4)
		local smoke = emitter:Add(SMOKE_MAT, spot)
		if smoke then
			vel:SetUnpacked(math.Rand(-8, 8), math.Rand(-8, 8), math.Rand(35, 60))
			smoke:SetVelocity(vel)
			smoke:SetDieTime(math.Rand(2.2, 3.2))
			smoke:SetStartAlpha(120)
			smoke:SetEndAlpha(0)
			smoke:SetStartSize(14 * scale)
			smoke:SetEndSize(80 * scale)
			smoke:SetColor(40, 22, 18)
			smoke:SetRoll(math.Rand(0, 360))
			smoke:SetRollDelta(math.Rand(-1, 1))
			smoke:SetLighting(false)
		end
	end
end

local lightSlot = 0

local function flashLight(pos, scale)
	lightSlot = (lightSlot + 1) % LIGHTS
	local light = DynamicLight(LIGHT_KEY + lightSlot)
	if not light then return end

	local size = 260 * math.sqrt(scale)
	light.pos = pos + vector_up * 24
	light.r, light.g, light.b = 255, math.random(90, 130), 30
	light.brightness = LIGHT_BRIGHTNESS
	light.size = size
	light.decay = size / 0.35
	light.dietime = CurTime() + 0.4
end

local function noise(pos, scale)
	sound.Play(SIZZLES[math.random(#SIZZLES)], pos, 80, math.random(90, 110), 0.9)
	sound.Play(GURGLES[math.random(#GURGLES)], pos, 75, math.random(70, 90), 0.8)
	if scale > 1 then
		sound.Play(IGNITE, pos, 85, math.random(80, 95), 1)
		sound.Play(GURGLES[math.random(#GURGLES)], pos, 85, math.random(45, 60), 1)
	end
end

local variants = {}

local function buildVariant()
	local raw, spikes, wobble = {}, {}, {}
	for s = 1, CROWN_SEGMENTS do
		raw[s] = math.Rand(0.5, 1.7)
	end

	for s = 1, CROWN_SEGMENTS do
		local prev, next = raw[(s - 2) % CROWN_SEGMENTS + 1], raw[s % CROWN_SEGMENTS + 1]
		spikes[s] = (prev + 4 * raw[s] + next) / 6
		wobble[s] = math.Rand(0.85, 1.15)
	end

	local function point(s, f)
		local seg = s % CROWN_SEGMENTS
		local ang = s / CROWN_SEGMENTS * math.pi * 2
		local radius = (1 + CROWN_FLARE * f * f) * wobble[seg + 1]

		return math.cos(ang) * radius, math.sin(ang) * radius, f * Lerp(f, 1, spikes[seg + 1])
	end

	local pos = Vector()
	local function vertex(s, f)
		local x, y, z = point(s, f)
		local heat = 1 - f * 0.7
		pos:SetUnpacked(x, y, z)
		mesh.Position(pos)
		mesh.Color(255, 110 + 90 * heat, 40 + 40 * heat, 255 * (1 - 0.5 * f * f * f))
		mesh.TexCoord(0, s / CROWN_SEGMENTS * 2, f * 0.5)
		mesh.AdvanceVertex()
	end

	local m = Mesh(CROWN_MAT)
	mesh.Begin(m, MATERIAL_TRIANGLES, CROWN_SEGMENTS * CROWN_RINGS * 2)
	for k = 0, CROWN_RINGS - 1 do
		local f0, f1 = k / CROWN_RINGS, (k + 1) / CROWN_RINGS
		for s = 0, CROWN_SEGMENTS - 1 do
			vertex(s, f0)
			vertex(s + 1, f0)
			vertex(s + 1, f1)
			vertex(s, f0)
			vertex(s + 1, f1)
			vertex(s, f1)
		end
	end
	mesh.End()

	local tips = {}
	for s = 0, CROWN_SEGMENTS - 1, 2 do
		tips[#tips + 1] = { point(s, 1) }
	end

	return { mesh = m, tips = tips }
end

local function dropVariants()
	for _, v in ipairs(variants) do
		v.mesh:Destroy()
	end

	variants = {}
end

local function newCrown(pos, scale, now, lean)
	return {
		pos = Vector(pos), scale = scale, t0 = now, life = CROWN_LIFE * math.sqrt(scale) * math.Rand(0.85, 1.2),
		height = CROWN_HEIGHT * scale * math.Rand(0.7, 1.3), lean = lean, rot = math.Rand(0, math.pi * 2), variant = math.random(CROWN_VARIANTS),
	}
end

local function push(list, item, max)
	if #list >= max then
		table.remove(list, 1)
	end

	list[#list + 1] = item
end

local function splash(pos, scale, follow)
	scale = math.Clamp(scale * math.Rand(1 - SCALE_JITTER, 1 + SCALE_JITTER), MIN_SCALE, MAX_SCALE)
	local now = CurTime()
	local a, lean = math.Rand(0, math.pi * 2), math.Rand(0, LEAN_MAX)
	local leanDir = Vector(math.cos(a) * lean, math.sin(a) * lean, 0)
	push(impacts, {
		pos = Vector(pos), t0 = now, radius = IMPACT_RADIUS * scale * math.Rand(0.8, 1.2), seed = math.random(),
		intensity = math.min(1, 0.6 + scale * 0.3) * EMISSIVE * math.Rand(0.8, 1.2), rate = math.Rand(0.7, 1.4),
	}, IMPACTS_MAX)
	push(crowns, newCrown(pos, scale, now, leanDir), CROWNS_MAX)
	burst(pos, scale, leanDir)
	flashLight(pos, scale)
	noise(pos, scale)

	if follow or math.random() > FOLLOW_CHANCE then return end

	for _ = 1, math.random(1, FOLLOW_MAX) do
		local r, b = math.Rand(0.3, 1) * FOLLOW_DISTANCE * math.sqrt(scale), math.Rand(0, math.pi * 2)
		later[#later + 1] = { at = now + math.Rand(0.15, 0.4), x = pos.x + math.cos(b) * r + leanDir.x * FOLLOW_DISTANCE, y = pos.y + math.sin(b) * r + leanDir.y * FOLLOW_DISTANCE, scale = scale * math.Rand(0.25, 0.45) }
	end
end

local function fling(c, base, height)
	local think = dropThink(c.pos.z)
	local speed = math.sqrt(c.scale)
	local co, si = math.cos(c.rot), math.sin(c.rot)
	for _, tip in ipairs(variants[c.variant].tips) do
		local ux, uy, uz = tip[1], tip[2], tip[3]
		local dx, dy = base * (co * ux - si * uy) + c.lean.x * height * uz, base * (si * ux + co * uy) + c.lean.y * height * uz
		local len = math.max(math.sqrt(dx * dx + dy * dy), 1)
		local out = math.Rand(120, 220) * speed
		launchDrop(Vector(c.pos.x + dx, c.pos.y + dy, c.pos.z + height * uz), Vector(dx / len * out, dy / len * out, math.Rand(80, 160) * speed), think, c.pos.z)
	end
end

local crownMatrix, uvMatrix = Matrix(), Matrix()

local function drawCrowns(now)
	if #variants == 0 then
		for i = 1, CROWN_VARIANTS do
			variants[i] = buildVariant()
		end
	end

	for i = #crowns, 1, -1 do
		local c = crowns[i]
		local t = (now - c.t0) / c.life
		if t >= 1 then
			table.remove(crowns, i)
		else
			local height = c.height * math.sin(math.pi * t)
			local base = CROWN_RADIUS * c.scale * (0.35 + 0.65 * (1 - (1 - t) ^ 2))
			if not c.flung and t >= CROWN_FLING then
				c.flung = true
				fling(c, base, height)
			end

			local co, si = math.cos(c.rot), math.sin(c.rot)
			crownMatrix:SetUnpacked(
				base * co, -base * si, c.lean.x * height, c.pos.x,
				base * si, base * co, c.lean.y * height, c.pos.y,
				0, 0, height, c.pos.z,
				0, 0, 0, 1
			)
			uvMatrix:SetUnpacked(1, 0, 0, 0, 0, 1, 0, t * 0.4, 0, 0, 1, 0, 0, 0, 0, 1)
			CROWN_MAT:SetFloat("$alpha", t < 0.7 and 1 or (1 - t) / 0.3)
			CROWN_MAT:SetMatrix("$basetexturetransform", uvMatrix)
			render.SetMaterial(CROWN_MAT)
			cam.PushModelMatrix(crownMatrix)
			variants[c.variant].mesh:Draw()
			cam.PopModelMatrix()
		end
	end
end

local quadPos = Vector()

local function drawImpacts(now)
	render.SetMaterial(IMPACT_MAT)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
	for i = #impacts, 1, -1 do
		local im = impacts[i]
		local age = now - im.t0
		if age > IMPACT_LIFE then
			table.remove(impacts, i)
		else
			setConstant(IMPACT_MAT, "$c0", im.pos.x, im.pos.y, im.pos.z, age)
			setConstant(IMPACT_MAT, "$c1", im.radius, im.intensity, im.seed, im.rate)
			quadPos:SetUnpacked(im.pos.x, im.pos.y, im.pos.z + IMPACT_HEIGHT)
			render.DrawQuadEasy(quadPos, vector_up, im.radius * 2, im.radius * 2, color_white, 0)
		end
	end
	render.OverrideBlend(false)
end

local spatterColor = Color(255, 255, 255, 255)

local function drawSpatters(now)
	render.SetMaterial(SPATTER_MAT)
	for i = #spatters, 1, -1 do
		local sp = spatters[i]
		local h = 1 - (now - sp.t0) / SPATTER_LIFE
		if h <= 0 then
			table.remove(spatters, i)
		else
			h = h * h
			spatterColor.r, spatterColor.g, spatterColor.b, spatterColor.a = 255, 60 + 110 * h, 20 + 30 * h, 255 * h
			quadPos:Set(sp.normal)
			quadPos:Mul(0.8)
			quadPos:Add(sp.pos)
			render.DrawQuadEasy(quadPos, sp.normal, sp.size, sp.size, spatterColor, sp.rot)
		end
	end
end

local drawNow = 0

local function drawAll()
	drawImpacts(drawNow)
	drawCrowns(drawNow)
	drawSpatters(drawNow)
end

local function draw()
	if #impacts == 0 and #crowns == 0 and #spatters == 0 then return end

	drawNow = CurTime()
	render.OverrideDepthEnable(true, false)
	depthslices.KeepAlpha(drawAll)
	render.OverrideDepthEnable(false, false)
end

local function land(drop)
	push(spatters, { pos = drop.pos, normal = drop.normal, t0 = CurTime(), size = SPATTER_SIZE * math.Rand(0.6, 1.3), rot = math.Rand(0, 360) }, SPATTERS_MAX)
	util.Decal("FadingScorch", drop.pos + drop.normal * 4, drop.pos - drop.normal * 4)
	if math.random() < 0.3 then
		sound.Play(SIZZLES[math.random(#SIZZLES)], drop.pos, 60, math.random(120, 140), 0.4)
	end
end

local function think()
	hideSplashes(lava.Fade() > 0)
	emitter:SetPos(EyePos())

	local now = CurTime()
	for i = #pending, 1, -1 do
		if pending[i].at <= now then
			land(table.remove(pending, i))
		end
	end

	for i = #later, 1, -1 do
		local f = later[i]
		if f.at <= now then
			table.remove(later, i)
			local surface = lava.Surface(f.x, f.y)
			if surface then
				splash(Vector(f.x, f.y, surface), f.scale, true)
			end
		end
	end
end

local function emitSound(t)
	if lava.Fade() <= 0 or not t.Pos or not t.SoundName:find(SPLASH_SOUND) then return end

	local surface = lava.Surface(t.Pos.x, t.Pos.y)
	if not surface or math.abs(t.Pos.z - surface) > SURFACE_TOLERANCE then return end

	splash(Vector(t.Pos.x, t.Pos.y, surface), BULLET_SCALE)

	return false
end

net.Receive(NET, function()
	local pos, radius, vz = net.ReadVector(), net.ReadFloat(), net.ReadFloat()
	if not active or lava.Fade() <= 0 then return end

	local surface = lava.Surface(pos.x, pos.y)
	if not surface then return end

	splash(Vector(pos.x, pos.y, surface), radius / ENTITY_RADIUS * (0.6 + math.min(math.abs(vz) / ENTITY_SPEED, 1) * 0.6))
end)

local function stop()
	hook.Remove("Think", "borealis_lava_splash")
	hook.Remove("EntityEmitSound", "borealis_lava_splash")
	depthslices.RemoveEffect("borealis_lava_splash")
	hideSplashes(false)
	if emitter then
		emitter:Finish()
		emitter = nil
	end

	impacts, crowns, spatters, pending, later = {}, {}, {}, {}, {}
	dropVariants()
	active = false
end

local function start()
	stop()
	build()
	emitter = ParticleEmitter(EyePos())
	hook.Add("Think", "borealis_lava_splash", think)
	hook.Add("EntityEmitSound", "borealis_lava_splash", emitSound)
	depthslices.AddEffect("borealis_lava_splash", ORDER, draw)
	active = true
end

shaderpack.AfterWorld("borealis_lava_splash", shaderpack.Toggle("borealis_lava_splash", GetConVar("borealis_lava"), { PS, VS }, start, stop, { NOISE_TEXTURE }))
