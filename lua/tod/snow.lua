local config =
{
	["fog_start"] = 0,
	["fog_end"] = 7000,
	["fog_max_density"] = 0.7,
	["fog_color"] = Vector(255,255,255) * 0.8,
	["star_intensity"] = 0,
	["sky_topcolor"] = Vector(1,1,1) * 0.5,
	["sky_bottomcolor"] = Vector(1,1,1) * 0.5,
	["sky_starfade"] = 0,
	["sky_duskintensity"] = 0,
	["light_scale"] = 0.8,
}

tod.AddOverrideConfig("snow", config, 0.2)

if CLIENT then
	local lastOvercast
	local DEFAULT_TINT = Vector(0.31, 0.35, 0.46)
	local GAMMA_INV = 1 / 2.2
	local FROST = 0.75
	local snowPaths = {}
	local snowTint = DEFAULT_TINT

	tod.snow = tod.snow or { amount = 0 }

	function tod.snow.SetTint(tint)
		snowTint = tint or DEFAULT_TINT
		for _, path in ipairs(snowPaths) do
			tod.SetTextureColor(path, snowTint)
		end
	end

	hook.Add("Think", "tod_snow", function()
		time = RealTime()
		tod.snow.amount = tod.GetWeather("snow")

		-- procsky"s grey sky follows the override as it fades in and out
		local snow = tod.override_configs.snow
		local overcast = snow and snow.lerp or 0
		local procsky = shaderpack and shaderpack.procsky
		if procsky and procsky.SetTheme and overcast ~= lastOvercast then
			lastOvercast = overcast
			procsky.SetTheme(overcast > 0 and { overcast = overcast } or nil)
		end
	end)

	local function isGround(path)
		return
			(
				path:find("grass") or
				path:find("mud") or
				path:find("sand")
			) and not
			(
				path:find("water") or
				path:find("gm_flatgrass")
			)
	end

	local GROUND_PROPS = { grass = true, mud = true, sand = true }

	local function isGroundProp(mat, key)
		local prop = mat:GetString(key)

		return prop ~= nil and GROUND_PROPS[prop:lower()] == true
	end

	hook.Add("TOD_ReplaceGrassTexture", "tod_snow", function(path)
		path = path:lower()
		local source = Material(path)
		if source:IsError() then return end

		if isGround(path) or isGroundProp(source, "$surfaceprop") then
			local mat = tod.ReplaceTexture(path, "nature/snowfloor002a")
			local second = mat and mat:GetTexture("$basetexture2")
			if second and not second:IsError() and (isGround(second:GetName():lower()) or isGroundProp(source, "$surfaceprop2")) then
				tod.ReplaceTexture(path, "nature/snowfloor002a", "$basetexture2")
			end

			snowPaths[#snowPaths + 1] = path
			tod.SetTextureColor(path, snowTint)
			tod.SetDetailBlend(path, 0)
		end
	end)

	include("tod/grasskey.lua")

	local function alreadyHandled(path, key)
		local replaced = tod.replaced_textures[path]

		return replaced ~= nil and (replaced.NewColor ~= nil or (replaced.OldTextures and replaced.OldTextures[key]) ~= nil)
	end

	local function replaceLayer(layer, tex)
		tod.ReplaceTexture(layer.path, tex, layer.key)
		if layer.color then
			tod.SetMaterialVector(layer.path, "$color", layer.color)
		end
	end

	hook.Add("TOD_TexturesReplaced", "tod_snow", function()
		local snowTexture = Material("nature/snowfloor002a"):GetTexture("$basetexture")
		local tr, tg, tb = DEFAULT_TINT.x ^ GAMMA_INV, DEFAULT_TINT.y ^ GAMMA_INV, DEFAULT_TINT.z ^ GAMMA_INV
		local version = util.CRC(tostring(DEFAULT_TINT) .. GAMMA_INV)

		tod.grasskey.Run("snow", {
			version = version,
			overlay = snowTexture,
			skip = alreadyHandled,
			compose = function(_, _, _, r, g, b)
				return r * tr, g * tg, b * tb
			end,
			apply = replaceLayer,
			done = function()
				tod.grasskey.Run("frost", {
					source = "props",
					version = version .. FROST,
					overlay = snowTexture,
					skip = alreadyHandled,
					compose = function(r, g, b, sr, sg, sb)
						return r + (sr * tr - r) * FROST, g + (sg * tg - g) * FROST, b + (sb * tb - b) * FROST
					end,
					apply = replaceLayer,
				})
			end,
		})
	end)

	hook.Add("PlayerFootstep", "snow", function(ply, pos, foot, sound, volume, rf)
		sound = sound:lower()
		if sound:find("grass", nil, true) or sound:find("dirt", nil, true) then
			ply:EmitSound(("player/footsteps/snow%s.wav"):format(math.random(6)), 60, math.random(95,105))
			return true
		end
	end)
end