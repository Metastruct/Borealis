local TAG = "ms_shaderpack_bench"
local SETTLE, MEASURE = 20, 30
local VIEWS = { { "horizon", 0 }, { "up", -30 } }
local GENERAL = { "cl_draw_procsky", "cl_draw_clouds", "cl_draw_skyterrain", "cl_draw_sunshafts", "cl_draw_water", "cl_draw_grass", "cl_draw_vclouds" }
local RAIN = { "cl_draw_precipitations", "cl_draw_fog" }
local NIGHT = { "cl_draw_auroras" }

local running

local function enabled(list)
	local out = {}
	for _, name in ipairs(list) do
		local cv = GetConVar(name)
		if cv and cv:GetBool() then
			out[#out + 1] = name
		end
	end

	return out
end

local function merged(...)
	local out = {}
	for _, list in ipairs({ ... }) do
		for _, name in ipairs(enabled(list)) do
			out[#out + 1] = name
		end
	end

	return out
end

local function conditions()
	if not tod then
		return { { name = "as is", cvars = merged(GENERAL) } }
	end

	local list = { { name = "day", weather = "clear", cycle = 0.5, cvars = merged(GENERAL) } }
	list[#list + 1] = { name = "day rain", weather = "rain", cycle = 0.5, cvars = merged(GENERAL, RAIN) }
	list[#list + 1] = { name = "night", weather = "clear", cycle = 0, cvars = merged(GENERAL, NIGHT) }
	list[#list + 1] = { name = "night rain", weather = "rain", cycle = 0, cvars = merged(GENERAL, RAIN, NIGHT) }

	return list
end

local function median(t)
	table.sort(t)

	return t[math.ceil(#t / 2)] or 0
end

local function short(name)
	return (name:gsub("^cl_draw_", ""))
end

local function header()
	local aa = GetConVar("mat_antialias")
	local on, off = {}, {}
	for _, list in ipairs({ GENERAL, RAIN, NIGHT }) do
		for _, name in ipairs(list) do
			local cv = GetConVar(name)
			if cv and cv:GetBool() then on[#on + 1] = short(name) elseif cv then off[#off + 1] = short(name) end
		end
	end

	return {
		string.format("shaderpack bench  %dx%d  msaa %d  hdr %s  dxlevel %d", ScrW(), ScrH(), aa and aa:GetInt() or 0, tostring(render.GetHDREnabled()), render.GetDXLevel()),
		"on:  " .. (#on > 0 and table.concat(on, ", ") or "-"),
		"off: " .. (#off > 0 and table.concat(off, ", ") or "-"),
		"ms per frame (median)",
	}
end

local function row(name, values, fmt)
	local s = string.format("  %-22s", name)
	for _, v in ipairs(values) do
		s = s .. string.format(fmt or "%9.2f", v)
	end

	return s
end

local function conditionTable(c, data)
	local names, base = {}, {}
	for vi, v in ipairs(VIEWS) do
		names[vi] = v[1]
		local d = data[vi]
		base[vi] = (median(d.base1) + median(d.base2)) * 0.5
	end

	local rows = {}
	for _, cvar in ipairs(c.cvars) do
		local values, worst = {}, -math.huge
		for vi = 1, #VIEWS do
			values[vi] = base[vi] - median(data[vi][cvar])
			worst = math.max(worst, values[vi])
		end

		rows[#rows + 1] = { short(cvar), values, worst }
	end

	table.sort(rows, function(a, b) return a[3] > b[3] end)

	local lines = {
		"",
		row(c.name, names, "%9s"),
		string.format("  sun %.0f, rain %.2f, overcast %.2f", c.sun or 0, c.rain or 0, c.overcast or 0),
		row("frame, all on", base),
	}
	for _, r in ipairs(rows) do
		lines[#lines + 1] = row(r[1], r[2], "%+9.2f")
	end

	return lines
end

local function schedule(conds)
	local blocks = {}
	for ci, c in ipairs(conds) do
		for vi = 1, #VIEWS do
			blocks[#blocks + 1] = { cond = ci, view = vi, key = "base1" }
			for _, cvar in ipairs(c.cvars) do
				blocks[#blocks + 1] = { cond = ci, view = vi, key = cvar, off = cvar }
			end

			blocks[#blocks + 1] = { cond = ci, view = vi, key = "base2" }
		end
	end

	return blocks
end

local function start()
	local conds = conditions()
	local blocks = schedule(conds)
	local original = {}
	for _, list in ipairs({ GENERAL, RAIN, NIGHT }) do
		for _, name in ipairs(list) do
			local cv = GetConVar(name)
			if cv then original[name] = cv:GetString() end
		end
	end

	local prevWeather = tod and tod.force_weather
	local prevCycle = tod and tod.current_cycle
	local results = {}
	for ci = 1, #conds do
		results[ci] = {}
		for vi = 1, #VIEWS do
			results[ci][vi] = {}
		end
	end

	local bi, frame, last = 1, 0, nil

	local function setCvars(off)
		for name, value in pairs(original) do
			local want = name == off and "0" or value
			if GetConVar(name):GetString() ~= want then
				RunConsoleCommand(name, want)
			end
		end
	end

	local function apply(b)
		local c = conds[b.cond]
		if tod then
			tod.force_weather = c.weather or prevWeather
			tod.current_cycle = c.cycle or prevCycle
		end

		setCvars(b.off)
	end

	local function finish(aborted)
		hook.Remove("CalcView", TAG)
		hook.Remove("PostRender", TAG)
		hook.Remove("HUDPaint", TAG)
		setCvars(nil)
		if tod then
			tod.force_weather = prevWeather
			tod.current_cycle = prevCycle
		end

		running = nil
		if aborted then
			print(TAG .. ": aborted, everything restored")
			return
		end

		local lines = header()
		for ci, c in ipairs(conds) do
			for _, l in ipairs(conditionTable(c, results[ci])) do
				lines[#lines + 1] = l
			end
		end

		for _, l in ipairs(lines) do
			print(l)
		end

		SetClipboardText("```\n" .. table.concat(lines, "\n") .. "\n```")
		print(TAG .. ": copied to clipboard")
	end

	running = true

	hook.Add("HUDPaint", TAG, function()
		local b = blocks[bi]
		if not b then return end

		local x = ScrW() * 0.5
		draw.SimpleTextOutlined("BENCHMARK RUNNING", "DermaLarge", x, 40, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 2, color_black)
		draw.SimpleTextOutlined("Stay still and keep the game window active until it finishes", "DermaDefaultBold", x, 80, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black)
		draw.SimpleTextOutlined(string.format("step %d of %d", bi, #blocks), "DermaDefault", x, 100, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black)
	end)

	hook.Add("CalcView", TAG, function(_, pos, ang, fov)
		return { origin = pos, angles = Angle(VIEWS[blocks[bi].view][2], ang.y, 0), fov = fov }
	end)

	local function step()
		if not system.HasFocus() then
			MsgC(Color(255, 80, 80), TAG .. ": stopped, the game window lost focus\n")
			finish(true)
			return
		end

		local now = SysTime()
		local dt = last and now - last
		last = now
		if not dt then
			apply(blocks[bi])
			return
		end

		frame = frame + 1
		local b = blocks[bi]
		if frame > SETTLE then
			local store = results[b.cond][b.view]
			store[b.key] = store[b.key] or {}
			table.insert(store[b.key], dt * 1000)
			if frame == SETTLE + 1 and b.key == "base1" then
				local c = conds[b.cond]
				c.sun = procsky and procsky.GetLights and select(3, procsky.GetLights()) or 0
				c.rain = tod and tod.rain and tod.rain.amount or 0
				c.overcast = procsky and procsky.GetOvercast and procsky.GetOvercast() or 0
			end
		end

		if frame < SETTLE + MEASURE then return end

		frame = 0
		bi = bi + 1
		local nb = blocks[bi]
		if not nb then
			finish(false)
			return
		end

		if nb.cond ~= b.cond or nb.view ~= b.view then
			print(string.format("%s: %s / %s", TAG, conds[nb.cond].name, VIEWS[nb.view][1]))
		end

		apply(nb)
	end

	hook.Add("PostRender", TAG, function()
		local ok, err = pcall(step)
		if not ok then
			print(TAG .. ": " .. tostring(err))
			finish(true)
		end
	end)
end

concommand.Add(TAG, function()
	if running then return end

	local fpsMax = GetConVar("fps_max")
	if fpsMax and fpsMax:GetFloat() ~= 0 then
		MsgC(Color(255, 80, 80), TAG .. ": Your FPS are capped at " .. fpsMax:GetString() .. ", the benchmark would be meaningless, remove the cap (fps_max 0) and try again\n")
		return
	end

	local vsync = GetConVar("mat_vsync")
	if vsync and vsync:GetBool() then
		MsgC(Color(255, 80, 80), TAG .. ": You have VSync enabled, the benchmark would be meaningless, disable vsync (mat_vsync 0) and try again\n")
		return
	end

	start()
end)
