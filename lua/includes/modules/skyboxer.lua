AddCSLuaFile()

local TAG = "skyboxer"

local skyboxer = _G.skyboxer or {}
_G.skyboxer = skyboxer

local hooklist = skyboxer.hooks or {}
skyboxer.hooks = hooklist

local function sort(a, b)
	return a[2] < b[2]
end

local function AddSkyBoxHook(name, cb)
	assert(isstring(name))
	assert(isfunction(cb))

	table.insert(hooklist, { cb, name })
	table.sort(hooklist, sort)
end

skyboxer.AddHook = AddSkyBoxHook

function skyboxer.RemoveHook(what)
	for k, v in next, hooklist do
		if v[1] == what or v[2] == what then
			table.remove(hooklist, k)
			return v
		end
	end
end

local function PostDraw2DSkyBox()
	for i = 1, #hooklist do
		hooklist[i][1]()
	end
end

hook.Add("PostDraw2DSkyBox", TAG, PostDraw2DSkyBox)

return skyboxer
