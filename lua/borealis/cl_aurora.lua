
local tag = "auroras"
local drawcvar = CreateClientConVar("cl_draw_auroras", 1, true, false, "show draw auroras")
local Particle_Glow_04 = Material("particle/Particle_Glow_04")
local tmpvec = Vector(0, 0, 0)
local offset = Vector(-20870, 7008, 8000)
local seed = 2147483646
local function random32()
	seed = seed * 16807 % 2147483647
	return seed
end

local function get_tod_time()
	local mode = GetConVar("sv_tod"):GetInt()

	if mode == 0 or mode == 2 then
		return tod.GetCycle()
	elseif mode == 1 then
		local H, M, S = os.date("%H"), os.date("%M"), os.date("%S")
		local frac = (H * 3600 + M * 60 + S) / 86400

		return frac
	end
end

local function onDraw()
	if not drawcvar:GetBool() then return end
	if not tod then return end

	local time = get_tod_time()
	if not time then return end
	if time > .05 and time < .95 then return end

	local origin = EyePos()
	origin:Mul(0.9) -- slight parallax effect to make it seem not infinitely far
	origin:Add(offset)

	local now = CurTime() * .5
	local mode = render.GetFogMode()
	local col = FastHSVToColor(160 + math.cos(now) * 10, 1, 1)

	render.SetMaterial(Particle_Glow_04)

	cam.Start3D() --nil, nil, nil, nil, nil, nil, nil, 1024, 65535)
		render.FogMode(0)

		seed = 2147483646
		for i = 1, 125 do
			local w = math.cos(1 / 12 * (now + i)) * 1000
			--TODO: math.floor seems to not be required?
			local h = 5000 + math.sin(now + 1 + math.floor((random32() - 1) * (11 / 2147483646))) * 2000
			local sprite_pos = tmpvec
			sprite_pos:SetUnpacked(i * 300, w, h * .25)
			sprite_pos:Add(origin)
			col.a = math.max(i - 10, 5)
			render.DrawSprite(sprite_pos, 1500, h, col)
		end
	cam.End3D()

	render.FogMode(mode)
end

pcall(require,"skyboxer")
if skyboxer then
	skyboxer.RemoveHook("cc_aurora")
	skyboxer.RemoveHook("cc_aurora")
	skyboxer.AddHook("cc_aurora", onDraw)

	hook.Add("PreDrawEffects", tag, function() end)
	hook.Remove("PreDrawEffects", tag)
	hook.Remove("PreDrawEffects", "cl_aurora")
else
	hook.Add("PreDrawEffects", tag, onDraw)
end

