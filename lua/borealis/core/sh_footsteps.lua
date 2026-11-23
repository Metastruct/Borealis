local NET = "borealis_footstep"

if SERVER then
	util.AddNetworkString(NET)

	if game.SinglePlayer() then
		hook.Add("PlayerFootstep", "borealis_footsteps", function(ply, pos, foot, sound, volume)
			net.Start(NET, true)
			net.WriteVector(pos)
			net.WriteUInt(foot, 1)
			net.WriteString(sound)
			net.WriteFloat(volume)
			net.Send(ply)
		end)
	end

	return
end

local footsteps = shaderpack.footsteps or {}
shaderpack.footsteps = footsteps

local handlers = footsteps.handlers or {}
footsteps.handlers = handlers

function footsteps.Add(name, fn)
	handlers[name] = fn
	hook.Add("PlayerFootstep", name, fn)
end

function footsteps.Remove(name)
	handlers[name] = nil
	hook.Remove("PlayerFootstep", name)
end

net.Receive(NET, function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	local pos = net.ReadVector()
	local foot = net.ReadUInt(1)
	local sound = net.ReadString()
	local volume = net.ReadFloat()
	for _, fn in pairs(handlers) do
		fn(ply, pos, foot, sound, volume)
	end
end)
