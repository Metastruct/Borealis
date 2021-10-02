local tag = "cl_aurora"
CreateConVar(tag, 1, FCVAR_NONE, "", 0, 1)
local SPRITE = Material("particle/Particle_Glow_04")

hook.Add("PreDrawEffects", tag, function()
	if not tobool(GetConVar(tag):GetInt()) then return end
	local off = LocalPlayer():GetPos()
	local origin = Vector(-20870.8286132813 + off.x, 7008.7553710938 + off.y, 8000 + off.z)
	now = CurTime() / 2
	local col = HSVToColor(160 + math.cos(now) * 10, 1, 1)
	cam.Start3D()

	for i = 1, 125 do
		math.randomseed(i)
		local w = math.cos(1 / 12 * (now + i)) * 1000
		local h = 5000 + math.sin(now + math.random(1, 10)) * 2000
		local sprite_pos = origin + Vector(i * 300, w, h / 4)
		col.a = math.max(i - 10, 5)
		render.SetMaterial(SPRITE)
		render.DrawSprite(sprite_pos, 1500, h, col)
	end

	cam.End3D()
end)