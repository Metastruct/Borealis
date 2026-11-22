local TAG = "borealis_menu"
local PS, VS = "borealis_menu_ps30", "borealis_passthrough_vs30"

local menu = shaderpack.menu or {}
shaderpack.menu = menu

local function mix(a, b, t)
	return Color(math.Round(Lerp(t, a.r, b.r)), math.Round(Lerp(t, a.g, b.g)), math.Round(Lerp(t, a.b, b.b)))
end

local PHOSPHOR = Color(120, 255, 196)
local SCREEN = Color(5, 11, 10)
local BLACK = Color(0, 0, 0)
local WHITE = Color(255, 255, 255)

local COL = {
	screen = SCREEN,
	hover = mix(SCREEN, PHOSPHOR, 0.1),
	line = mix(SCREEN, PHOSPHOR, 0.2),
	dim = mix(SCREEN, PHOSPHOR, 0.38),
	mid = mix(SCREEN, PHOSPHOR, 0.62),
	ink = PHOSPHOR,
	bright = Color(214, 255, 236),
	amber = Color(255, 178, 72),
	danger = Color(255, 92, 84),
}

local CASE = {
	body = Color(56, 55, 50),
	top = Color(78, 76, 69),
	edge = Color(96, 94, 86),
	shade = Color(30, 29, 26),
	recess = Color(12, 12, 11),
	plate = Color(18, 18, 17),
	metal = Color(82, 80, 73),
	metalTop = Color(104, 101, 92),
	hi = Color(130, 126, 115),
	lo = Color(22, 21, 19),
	ink = Color(190, 184, 166),
	orange = Color(222, 108, 36),
	cap = Color(184, 180, 166),
	capInk = Color(36, 35, 32),
	ledOff = Color(34, 33, 30),
	shadow = Color(0, 0, 0, 170),
}

local GRADIENT = Material("gui/gradient_down")

local MODE_NAMES = { [0] = "MANUAL", [1] = "REALTIME", [2] = "DEMO" }
local MONTHS = { "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" }

local EFFECT_GROUPS = {
	{ "SKY", {
		{ "borealis_procsky", "Atmosphere", "Shift sky colour with the time of day" },
		{ "borealis_clouds", "Clouds", "Drift clouds across the sky" },
		{ "borealis_vclouds", "Volumetric clouds", "Replace clouds with thick 3D clouds" },
		{ "borealis_auroras", "Auroras", "Show northern lights on some nights" },
		{ "borealis_sunshafts", "Sun shafts", "Cast sunbeams through gaps and treetops" },
	} },
	{ "WEATHER", {
		{ "borealis_precipitations", "Rain and snow", "Drop rain and snow in bad weather" },
		{ "borealis_fog", "Volumetric fog", "Thicken fog so lights shine through it" },
		{ "borealis_wetness", "Wet surfaces", "Darken wet ground and form puddles" },
		{ "borealis_drips", "Roof drips", "Drip rain off roof edges" },
		{ "borealis_snow", "Deep snow", "Pile up snow in winter and keep footprints" },
		{ "borealis_snow_powder", "Snow powder", "Kick up snow under cars and explosions" },
	} },
	{ "NATURE", {
		{ "borealis_water", "Water", "Upgrade water above and below the surface" },
		{ "borealis_lava", "Lava", "Make lava glow, shimmer and spark", show = function()
			return GetGlobal2Vector("borealis_lava_area_mins", vector_origin) ~= GetGlobal2Vector("borealis_lava_area_maxs", vector_origin)
		end },
		{ "borealis_grass", "Grass", "Grow grass on grassy ground" },
		{ "borealis_seagrass", "Seagrass", "Grow seagrass on sandy sea floors" },
		{ "borealis_kelp", "Kelp", "Grow kelp forests on rocky sea floors" },
		{ "borealis_leaves", "Leaves", "Drop leaves from trees in autumn" },
	} },
	{ "ADVANCED", {
		{ "borealis_skybox3d", "3D skybox depth", "Extend fog and weather to distant scenery" },
		{ "borealis_ssao", "Ambient occlusion", "Shade corners and the ground under objects" },
		{ "borealis_ssao_halfres", "Half-res occlusion", "Trade shading sharpness for speed" },
		{ "borealis_sharpen", "Sharpening", "Sharpen the picture" },
		{ "borealis_grade", "Colour grading", "Tint the picture by time of day" },
		{ "borealis_rain_mute_losefocus", "Mute rain unfocused", "Silence rain while the game is in the background" },
	} },
}

local EFFECT_SLIDERS = {
	{ "borealis_grass_distance", "Grass distance", 1024, 8192, 0, "Set how far away grass shows" },
	{ "borealis_snow_distance", "Snow distance", 1024, 8192, 0, "Set how far away deep snow shows" },
	{ "borealis_sharpen_strength", "Sharpening", 0, 1, 2, "Set sharpening strength" },
	{ "borealis_ssao_strength", "Occlusion", 0, 1, 2, "Set shading darkness" },
	{ "borealis_rain_volume", "Rain volume", 0, 1, 2, "Set how loud rain, drips and thunder are" },
}

local GLYPHS = {
	clear = { "#..#..#", ".......", "..###..", "#.###.#", "..###..", ".......", "#..#..#" },
	night = { "...###.", "..##...", ".##....", ".##....", ".##....", "..##...", "...###." },
	rain = { "..###..", ".#####.", "#######", ".......", "#..#..#", ".#..#..", "..#..#." },
	snow = { "..###..", ".#####.", "#######", ".......", "#.#.#.#", ".......", ".#.#.#." },
	fog = { ".......", "#######", ".......", ".######", ".......", "#####..", "......." },
	cloud = { ".......", "..##...", ".####..", ".#####.", "#######", "#######", "......." },
}

for name, rows in pairs(GLYPHS) do
	local cells = {}
	for r, row in ipairs(rows) do
		for c = 1, #row do
			if row:sub(c, c) == "#" then cells[#cells + 1] = { c - 1, r - 1 } end
		end
	end
	GLYPHS[name] = cells
end

local TITLE = "BOREALIS"
local WINDOW_W, WINDOW_H = 1080, 720
local TTY_CPS = 1400
local SEGMENTS = 20

local SOUND = {
	click = "borealis/menu/click.wav",
	tick = "borealis/menu/detent.wav",
	release = "borealis/menu/release.wav",
	on = "borealis/menu/power_on.wav",
	onShort = "borealis/menu/power_on_short.wav",
	off = "borealis/menu/power_off.wav",
	tab = "borealis/menu/tab.wav",
	hum = "ambient/machines/60hzhum.wav",
	typing = "ambient/machines/keyboard_fast1_1second.wav",
}
local CLICK_VOLUME, TAB_VOLUME = 0.5, 0.5
local TICK_VOLUME, TICK_GAP = 0.3, 0.025
local ON_VOLUME, OFF_VOLUME = 0.5, 0.4
local JINGLE_IDLE = 600
local HUM_VOLUME, HUM_FADE = 0.08, 0.3
local TYPING_VOLUME = 0.25

local function playUI(path, volume, pitch)
	local ply = LocalPlayer()
	if IsValid(ply) then ply:EmitSound(path, 0, pitch or 100, volume, CHAN_STATIC) end
end

local function loopUI(path, volume)
	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	local patch = CreateSound(ply, path)
	patch:SetSoundLevel(0)
	patch:PlayEx(volume, 100)

	return patch
end

local lastTick = 0
local function tick()
	local now = RealTime()
	if now - lastTick < TICK_GAP then return end

	lastTick = now
	playUI(SOUND.tick, TICK_VOLUME, math.random(96, 104))
end

local uiScale = 1
local H, FONT = {}, {}

local function px(v)
	return math.floor(v * uiScale + 0.5)
end

local function buildTitle(length)
	FONT.title = "borealis_menu_title"

	local function create(size)
		surface.CreateFont(FONT.title, { font = "Nine Circles", size = size, weight = 400, antialias = true, extended = true })
		surface.SetFont(FONT.title)

		return surface.GetTextSize(TITLE)
	end

	local size = math.floor(100 * length / create(100))
	while size > 10 and create(size) > length do
		size = size - 1
	end
end

local function buildFonts()
	uiScale = math.Clamp(ScrH() / 1080, 0.7, 2)

	local function font(key, face, size)
		local name = "borealis_menu_" .. key
		local height = math.max(10, math.floor(size * uiScale))
		FONT[key], H[key] = name, height
		surface.CreateFont(name, { font = face, size = height, weight = 400, antialias = true, extended = true })
	end

	buildTitle(px(WINDOW_H))
	font("huge", "VT323", 84)
	font("big", "VT323", 46)
	font("med", "VT323", 32)
	font("body", "VT323", 24)
	font("small", "VT323", 20)
	font("plate", "Audiowide", 13)
	font("key", "Audiowide", 12)
	font("label", "Audiowide", 12)
end

buildFonts()

local function text(str, font, x, y, col, ax, ay)
	return draw.SimpleText(str, font, math.floor(x), math.floor(y), col, ax, ay)
end

local function rect(x, y, w, h, col)
	surface.SetDrawColor(col)
	surface.DrawRect(math.floor(x), math.floor(y), math.floor(w), math.floor(h))
end

local function outline(x, y, w, h, col)
	surface.SetDrawColor(col)
	surface.DrawOutlinedRect(math.floor(x), math.floor(y), math.floor(w), math.floor(h))
end

local tty = { start = 0, used = 0 }

local function budget()
	return (RealTime() - tty.start) * TTY_CPS - tty.used
end

local function ready()
	return budget() > 0
end

local function reveal(cost)
	local left = budget()
	tty.used = tty.used + cost

	return math.Clamp(left / cost, 0, 1)
end

local function say(str, font, x, y, col, ax, ay)
	surface.SetFont(font)
	local tw, th = surface.GetTextSize(str)
	local n = math.floor(budget())
	tty.used = tty.used + #str
	if n <= 0 then return tw, th end

	x = math.floor(x - (ax == TEXT_ALIGN_RIGHT and tw or ax == TEXT_ALIGN_CENTER and tw / 2 or 0))
	y = math.floor(y - (ay == TEXT_ALIGN_BOTTOM and th or ay == TEXT_ALIGN_CENTER and th / 2 or 0))
	surface.SetTextColor(col)
	surface.SetTextPos(x, y)

	if n >= #str then
		surface.DrawText(str)
	else
		local part = str:sub(1, n)
		surface.DrawText(part)
		rect(x + surface.GetTextSize(part) + 1, y + th * 0.2, th * 0.42, th * 0.62, col)
	end

	return tw, th
end

local function section(x, y, w, label, status, statusCol)
	surface.SetFont(FONT.small)
	local tw = surface.GetTextSize(label) + px(12)
	local hh = H.small + px(2)
	local f = reveal(#label)

	if f > 0 then
		rect(x, y, tw * f, hh, COL.ink)
		rect(x + tw, y + hh - 1, (w - tw) * f, 1, COL.line)
	end
	if f >= 1 then text(label, FONT.small, x + px(6), y + px(1), COL.screen) end
	if status then say(status, FONT.small, x + w, y + px(1), statusCol or COL.mid, TEXT_ALIGN_RIGHT) end

	return hh
end

local function leader(x, y, w, label, value, col)
	local lw = say(label, FONT.body, x, y, COL.mid)
	local f = reveal(8)
	surface.SetFont(FONT.body)
	local vw = surface.GetTextSize(value)

	if f > 0 then
		surface.SetDrawColor(COL.line)
		local x1, x2 = x + lw + px(8), x + w - vw - px(8)
		local dy = math.floor(y + H.body * 0.68)
		for dx = x1, x1 + (x2 - x1) * f, px(6) do
			surface.DrawRect(math.floor(dx), dy, px(2), px(2))
		end
	end

	say(value, FONT.body, x + w, y, col or COL.bright, TEXT_ALIGN_RIGHT)
end

local function glyph(name, x, y, cell, col)
	surface.SetDrawColor(col)
	for _, c in ipairs(GLYPHS[name] or GLYPHS.cloud) do
		surface.DrawRect(math.floor(x + c[1] * cell), math.floor(y + c[2] * cell), cell, cell)
	end
end

local function wrap(str, font, width)
	surface.SetFont(font)
	local lines, line = {}, ""
	for word in str:gmatch("%S+") do
		local try = line == "" and word or line .. " " .. word
		if line ~= "" and surface.GetTextSize(try) > width then
			lines[#lines + 1] = line
			line = word
		else
			line = try
		end
	end
	if line ~= "" then lines[#lines + 1] = line end

	return lines
end

local function duration(sec)
	sec = math.max(0, math.floor(sec))
	local d, h, m = math.floor(sec / 86400), math.floor(sec % 86400 / 3600), math.floor(sec % 3600 / 60)
	if d > 0 then return string.format("%dD %02dH", d, h) end
	if h > 0 then return string.format("%dH %02dM", h, m) end

	return string.format("%dM", m)
end

local function clock(cycle)
	local minutes = math.floor(cycle * 1440 + 0.5) % 1440

	return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

local function percent(v)
	return string.format("%d%%", math.Round(math.Clamp(v or 0, 0, 1) * 100))
end

local function isAdmin()
	local lp = LocalPlayer()

	return IsValid(lp) and lp:IsAdmin()
end

local function control(action, arg)
	if util.NetworkStringToID(TAG) == 0 then
		notification.AddLegacy("This server does not run the Borealis menu controls", NOTIFY_ERROR, 4)
		return
	end

	net.Start(TAG)
	net.WriteString(action)
	net.WriteString(arg or "")
	net.SendToServer()
end

local function currentCycle()
	if not tod then return 0 end
	if tod.GetMode() == 1 then return tod.GetRealTime() end

	local cycle = tod.GetCycle()

	return cycle >= 0 and cycle or 0
end

local function slotCycle(start)
	if tod.GetMode() == 1 then return (tod.GetRealTime() + (start - os.time()) / 86400) % 1 end

	return currentCycle()
end

local function utcLabel()
	local offset = tod.GetUTCOffset() or 0
	local sign = offset < 0 and "-" or "+"
	offset = math.abs(offset)

	return string.format("UTC%s%02d:%02d", sign, math.floor(offset / 3600), math.floor(offset % 3600 / 60))
end

local function weatherNames()
	local names = {}
	for name in pairs(tod and tod.weathers or {}) do
		names[#names + 1] = name
	end
	table.sort(names)
	table.insert(names, 1, "clear")

	return names
end

local function weatherAmount(name)
	if name ~= "clear" then return tod.GetWeather(name) end

	local most = 0
	for other in pairs(tod.weathers) do
		most = math.max(most, tod.GetWeather(other))
	end

	return 1 - most
end

local forecast = { slot = -1, names = {} }

local function getForecast()
	local slot = math.floor(os.time() / tod.WEATHER_SLOT)
	local count = table.Count(tod.weathers)
	if forecast.slot == slot and forecast.count == count then return forecast end

	forecast.slot, forecast.count = slot, count
	for i = 0, 23 do
		forecast.names[i] = tod.GetSlotWeather(slot + i)
	end

	forecast.next, forecast.nextSlot = nil, nil
	for i = 1, 24 * 7 do
		local name = i < 24 and forecast.names[i] or tod.GetSlotWeather(slot + i)
		if name ~= forecast.names[0] then
			forecast.next, forecast.nextSlot = name, slot + i
			break
		end
	end

	return forecast
end

local function calendarSeason(month)
	if month >= 12 or month <= 2 then return "winter" end
	if month == 10 or month == 11 then return "autumn" end

	return "summer"
end

local MONTH_SEASONS = {}
for i = 0, 11 do
	MONTH_SEASONS[i] = calendarSeason(i + 1)
end

local function nextCalendarSeason(now)
	local season = calendarSeason(now.month)
	local year, month = now.year, now.month
	for _ = 1, 12 do
		month = month + 1
		if month > 12 then month, year = 1, year + 1 end

		if calendarSeason(month) ~= season then
			return calendarSeason(month), os.time({ year = year, month = month, day = 1, hour = 0 })
		end
	end
end

local function sunCurve()
	local samples = {}
	for i = 0, 96 do
		local t = (i / 96) % 1
		local cfg = tod.AlignSunToLight(tod.SampleCycle(t), t)
		samples[i] = isangle(cfg.sun_angles) and math.deg(math.asin(math.sin(math.rad(cfg.sun_angles.p)))) or 0
	end

	return samples
end

local function elevationAt(samples, hour)
	local f = (hour % 24) / 24 * 96
	local i = math.floor(f)

	return Lerp(f - i, samples[i], samples[math.min(i + 1, 96)])
end

local function weatherGlyph(name, cycle, samples)
	if name == "clear" and elevationAt(samples, cycle * 24) < 0 then return "night" end

	return GLYPHS[name] and name or "cloud"
end

local BUTTON = {}

function BUTTON:Init()
	self:SetText("")
	self.Label = ""
	self.Accent = COL.ink
end

function BUTTON:Setup(label, onPress, help, accent)
	if isfunction(label) then
		self.LabelFn = label
	else
		self.Label = label:upper()
	end
	self.OnPress = onPress
	self.BorealisHelp = help
	self.Accent = accent or COL.ink

	return self
end

function BUTTON:Paint(w, h)
	local label = self.LabelFn and self.LabelFn():upper() or self.Label
	if reveal(#label + 4) <= 0 then return end

	if self.IsActive and self:IsActive() then
		rect(0, 0, w, h, self.Accent)
		text(label, FONT.small, w / 2, h / 2, COL.screen, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		return
	end

	local hovered = self:IsHovered()
	if hovered then rect(0, 0, w, h, COL.hover) end
	local edge = hovered and self.Accent or COL.dim
	text("[", FONT.small, px(4), h / 2, edge, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	text("]", FONT.small, w - px(4), h / 2, edge, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	text(label, FONT.small, w / 2, h / 2, hovered and COL.bright or COL.mid, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

function BUTTON:DoClick()
	playUI(SOUND.click, CLICK_VOLUME)
	if self.OnPress then self:OnPress() end
end

vgui.Register("BorealisButton", BUTTON, "DButton")

local TOGGLE = {}

function TOGGLE:Init()
	self:SetText("")
end

function TOGGLE:Setup(label, convar, help)
	self.Label = label:upper()
	self.ConVar = convar
	self.BorealisHelp = help

	return self
end

function TOGGLE:Paint(w, h)
	local on = self.ConVar:GetBool()
	local live = self.Master or GetConVar("borealis_enabled"):GetBool()

	if self:IsHovered() and ready() then rect(0, 0, w, h, COL.hover) end

	local font = self.Master and FONT.med or FONT.body
	local state = on and "ON" or "OFF"
	local stateCol = not live and COL.dim or on and COL.bright or self.Master and COL.danger or COL.dim
	local lw = say(self.Label, font, px(6), h / 2, live and COL.mid or COL.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

	surface.SetFont(font)
	local sw = surface.GetTextSize("OFF")
	local f = reveal(6)
	if f > 0 then
		surface.SetDrawColor(COL.line)
		local x1, x2 = px(6) + lw + px(8), w - px(6) - sw - px(8)
		local dy = math.floor(h / 2 + px(3))
		for dx = x1, x1 + (x2 - x1) * f, px(6) do
			surface.DrawRect(math.floor(dx), dy, px(2), px(2))
		end
	end

	say(state, font, w - px(6), h / 2, stateCol, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
end

function TOGGLE:DoClick()
	playUI(SOUND.click, CLICK_VOLUME)
	RunConsoleCommand(self.ConVar:GetName(), self.ConVar:GetBool() and "0" or "1")
end

vgui.Register("BorealisToggle", TOGGLE, "DButton")

local SLIDER = {}

function SLIDER:Setup(label, min, max, decimals, convar, help)
	self.Label = label:upper()
	self.Min, self.Max, self.Decimals = min, max, decimals
	self.ConVar = convar
	self.BorealisHelp = help
	self:SetCursor("sizewe")

	return self
end

function SLIDER:GetValue()
	if self.Picked ~= nil then return self.Picked end

	return self.ConVar:GetFloat()
end

function SLIDER:Pick()
	local x = self:ScreenToLocal(gui.MouseX(), 0)
	local frac = math.Clamp(x / self:GetWide(), 0, 1)
	self.Picked = math.Round(self.Min + (self.Max - self.Min) * frac, self.Decimals)

	local step = math.Round((self.Picked - self.Min) / (self.Max - self.Min) * SEGMENTS)
	if self.Step and step ~= self.Step then tick() end
	self.Step = step
end

function SLIDER:OnMousePressed(code)
	if code ~= MOUSE_LEFT then return end
	self.Dragging = true
	self.Step = nil
	self:MouseCapture(true)
	self:Pick()
	tick()
end

function SLIDER:OnMouseReleased(code)
	if code ~= MOUSE_LEFT or not self.Dragging then return end
	self.Dragging = false
	self:MouseCapture(false)
	self:Pick()
	playUI(SOUND.release, TICK_VOLUME)
	RunConsoleCommand(self.ConVar:GetName(), tostring(self.Picked))
	self.Picked = nil
end

function SLIDER:Think()
	if self.Dragging then self:Pick() end
end

function SLIDER:Paint(w, h)
	local value = self:GetValue()
	local frac = math.Clamp((value - self.Min) / (self.Max - self.Min), 0, 1)
	local picking = self.Picked ~= nil
	local hovered = self:IsHovered() or picking

	say(self.Label, FONT.small, 0, 0, hovered and COL.bright or COL.mid)
	say(self.Decimals > 0 and string.format("%." .. self.Decimals .. "f", value) or tostring(math.Round(value)), FONT.small, w, 0, COL.bright, TEXT_ALIGN_RIGHT)

	local f = reveal(SEGMENTS)
	local gap = px(3)
	local step = (w + gap) / SEGMENTS
	local filled = math.Round(frac * SEGMENTS)
	local y = H.small + px(6)
	for i = 0, math.floor(SEGMENTS * f) - 1 do
		local x = math.floor(i * step)
		rect(x, y, math.floor((i + 1) * step) - gap - x, h - y, i < filled and (picking and COL.bright or COL.ink) or COL.line)
	end
end

vgui.Register("BorealisSlider", SLIDER, "Panel")

local CHART = {}

function CHART:Init()
	self.Samples = sunCurve()

	local lo, hi = 0, 0
	for i = 0, 96 do
		lo, hi = math.min(lo, self.Samples[i]), math.max(hi, self.Samples[i])
	end
	self.Lo = math.floor(lo / 15) * 15
	self.Hi = math.max(self.Lo + 30, math.ceil(hi / 15) * 15)

	for i = 1, 96 do
		local a, b = self.Samples[i - 1], self.Samples[i]
		local cross = (i - 1 + a / (a - b)) / 4
		if a < 0 and b >= 0 and not self.Rise then self.Rise = cross end
		if a >= 0 and b < 0 and not self.Set then self.Set = cross end
	end
end

function CHART:Area(w, h)
	return px(34), w - px(2), H.small + px(10), h - H.small - px(6)
end

function CHART:HourAt(mx)
	local left, right = self:Area(self:GetSize())

	return math.Round(math.Clamp((mx - left) / (right - left), 0, 1) * 96) / 4
end

function CHART:OnMousePressed(code)
	if not self.Pickable then return end
	if code == MOUSE_RIGHT then
		self.Picked = nil
		return
	end
	if code ~= MOUSE_LEFT then return end

	self.Dragging = true
	self:MouseCapture(true)
	self.Picked = self:HourAt(self:ScreenToLocal(gui.MouseX(), 0))
	tick()
end

function CHART:OnMouseReleased(code)
	if code ~= MOUSE_LEFT or not self.Dragging then return end
	self.Dragging = false
	self:MouseCapture(false)
	playUI(SOUND.release, TICK_VOLUME)
end

function CHART:Think()
	if self.Dragging then
		local hour = self:HourAt(self:ScreenToLocal(gui.MouseX(), 0))
		if hour ~= self.Picked then tick() end
		self.Picked = hour
	end
end

function CHART:Cursor(hour, col, lineCol, boxed, unlabelled)
	local w, h = self:GetSize()
	local left, right, top, bottom = self:Area(w, h)
	local x = math.floor(left + hour / 24 * (right - left))
	local y = math.floor(bottom - (elevationAt(self.Samples, hour) - self.Lo) / (self.Hi - self.Lo) * (bottom - top))

	rect(x, top, 1, bottom - top, lineCol)
	if boxed then rect(x - px(3), y - px(3), px(7), px(7), col) end
	if unlabelled then return end

	local label = clock(hour / 24)
	surface.SetFont(FONT.small)
	local tw = surface.GetTextSize(label) + px(10)
	local lx = math.Clamp(x - tw / 2, left, right - tw)
	local lh = H.small + px(2)
	if boxed then
		rect(lx, 0, tw, lh, col)
		text(label, FONT.small, lx + tw / 2, lh / 2, COL.screen, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	else
		text(label, FONT.small, lx + tw / 2, lh / 2, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
end

function CHART:Paint(w, h)
	local f = reveal(80)
	if f <= 0 then return end

	local left, right, top, bottom = self:Area(w, h)
	local lo, hi = self.Lo, self.Hi
	local samples = self.Samples
	local span = right - left

	local function X(hour) return left + hour / 24 * span end
	local function Y(e) return bottom - (e - lo) / (hi - lo) * (bottom - top) end

	for e = math.ceil(lo / 30) * 30, hi, 30 do
		local y = math.floor(Y(e))
		if e == 0 then
			rect(left, y, span * f, 1, COL.dim)
		else
			surface.SetDrawColor(COL.line)
			for half = 0, 48 * f do
				surface.DrawRect(math.floor(X(half / 2)), y, 1, 1)
			end
		end
		text(e == 0 and "0" or string.format("%+d", e), FONT.small, left - px(8), y, e == 0 and COL.mid or COL.dim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	end

	rect(left, bottom, span * f, 1, COL.line)
	for hour = 0, math.floor(24 * f) do
		local x = math.floor(X(hour))
		local major = hour % 6 == 0
		rect(x, bottom, 1, major and px(6) or px(3), major and COL.mid or COL.line)
		if major then
			text(string.format("%02d", hour % 24), FONT.small, x, bottom + px(6), COL.dim, hour == 0 and TEXT_ALIGN_LEFT or hour == 24 and TEXT_ALIGN_RIGHT or TEXT_ALIGN_CENTER)
		end
	end

	local horizon = math.floor(Y(0))
	surface.SetDrawColor(COL.line)
	for x = left + 1, left + span * f - 1, px(3) do
		local e = elevationAt(samples, (x - left) / span * 24)
		if e > 0 then
			local y = math.floor(Y(e))
			surface.DrawRect(x, y, 1, horizon - y)
		end
	end

	local x0, y0 = X(0), Y(samples[0])
	for i = 1, math.floor(96 * f) do
		local x1, y1 = X(i / 4), Y(samples[i])
		surface.SetDrawColor(samples[i] + samples[i - 1] >= 0 and COL.ink or COL.dim)
		surface.DrawLine(x0, y0, x1, y1)
		surface.DrawLine(x0, y0 - 1, x1, y1 - 1)
		x0, y0 = x1, y1
	end

	if f < 1 then return end

	if self.Pickable and self:IsHovered() and not self.Dragging then
		self:Cursor(self:HourAt(self:ScreenToLocal(gui.MouseX(), 0)), COL.dim, COL.line, false)
	end

	self:Cursor(currentCycle() * 24, COL.bright, COL.mid, true, true)
	if self.Picked then
		self:Cursor(self.Picked, COL.amber, COL.amber, true)
	end
end

vgui.Register("BorealisSunChart", CHART, "Panel")

local KEY = {}

function KEY:Init()
	self:SetText("")
end

function KEY:Setup(label, onPress, cap, help)
	self.Label = label:upper()
	self.OnPress = onPress
	self.Cap = cap or CASE.cap
	self.Lip = mix(self.Cap, BLACK, 0.45)
	self.Shine = mix(self.Cap, WHITE, 0.25)
	self.Lit = mix(self.Cap, WHITE, 0.1)
	self.BorealisHelp = help

	return self
end

function KEY:Paint(w, h)
	local down = self:IsDown() or (self.IsActive and self:IsActive())
	local travel = px(6)
	local sink = down and px(4) or 0
	local fh = h - travel

	rect(0, 0, w, h, CASE.recess)
	rect(0, sink + fh, w, travel - sink, self.Lip)
	rect(0, sink, w, fh, self:IsHovered() and self.Lit or self.Cap)
	rect(0, sink, w, 1, self.Shine)
	text(self.Label, FONT.key, w / 2, sink + fh / 2, CASE.capInk, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

function KEY:DoClick()
	if self.OnPress then self:OnPress() end
end

vgui.Register("BorealisKey", KEY, "DButton")

local function overrideRow(parent, x, y, w, h, specs, labels)
	surface.SetFont(FONT.small)
	local lw = surface.GetTextSize("OVERRIDE") + px(14)
	labels[#labels + 1] = { x, y + h / 2 }

	local gap = px(6)
	local bw = math.floor((w - lw - gap * (#specs - 1)) / #specs)
	for i, spec in ipairs(specs) do
		local button = vgui.Create("BorealisButton", parent)
		button:Setup(spec[1], spec[2], spec[3], spec[5] or COL.amber)
		button.IsActive = spec[4]
		button:SetPos(x + lw + (i - 1) * (bw + gap), y)
		button:SetSize(bw, h)
	end
end

local function buildStatus(tab, w, h)
	if not tod then
		function tab:Paint()
			say("TIME OF DAY IS NOT LOADED", FONT.med, w / 2, h / 2, COL.danger, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		return
	end

	local admin = isAdmin()
	local gap, vgap = px(36), px(30)
	local lw = math.floor((w - gap) * 0.47)
	local rx, rw = lw + gap, w - lw - gap
	local wh = math.floor((h - vgap) / 2)
	local sy = wh + vgap
	local rowH = px(26)
	local headH = H.small + px(2)
	local labels = {}

	local clockY = headH + px(6)
	local sunY = h - H.body - (admin and rowH + px(20) or 0)
	local chartTop = clockY + H.huge
	local chart = vgui.Create("BorealisSunChart", tab)
	chart:SetPos(0, chartTop)
	chart:SetSize(lw, sunY - chartTop - px(20))
	chart.Pickable = admin
	if admin then chart.BorealisHelp = "Select a time, then press Set. Right click to cancel" end
	local samples = chart.Samples

	local big = px(5)
	local glyphY = headH + px(18)
	local stripY = glyphY + big * 7 + px(22)
	local stripH = px(22)
	local cell = rw / 24
	local strip = vgui.Create("Panel", tab)
	strip:SetPos(rx, stripY)
	strip:SetSize(rw, stripH)

	function strip:Slot()
		return math.Clamp(math.floor(self:ScreenToLocal(gui.MouseX(), 0) / cell), 0, 23)
	end

	function strip:BorealisHelp()
		local fc = getForecast()
		local i = self:Slot()
		local start = (fc.slot + i) * tod.WEATHER_SLOT

		return string.format("%s from %s to %s", fc.names[i], os.date("%H:%M", start), os.date("%H:%M", start + tod.WEATHER_SLOT))
	end

	local nameY = sy + headH + px(10)
	local rulerY = nameY + H.big + px(4)
	local rulerH = px(22)

	if admin then
		overrideRow(tab, 0, h - rowH, lw, rowH, {
			{ "Realtime", function() control("time", "realtime") end, "Sync the clock to real time for all players", function() return tod.GetMode() == 1 end, COL.ink },
			{ "Demo", function() control("time", "demo") end, "Run a full day in 20 seconds for all players", function() return tod.GetMode() == 2 end },
			{ function() return chart.Picked and "Set " .. clock(chart.Picked / 24) or "Set --:--" end, function()
				if not chart.Picked then return end
				control("time", tostring(chart.Picked))
				chart.Picked = nil
			end, "Hold the clock at the selected time for all players", function() return chart.Picked ~= nil end },
		}, labels)

		local specs = { { "Auto", function() control("weather", "") end, "Resume the hourly weather schedule", function() return tod.force_weather == nil end, COL.ink } }
		for _, name in ipairs(weatherNames()) do
			specs[#specs + 1] = { name, function() control("weather", name) end, "Lock the weather to " .. name .. " until Auto", function() return tod.force_weather == name end }
		end
		overrideRow(tab, rx, wh - rowH, rw, rowH, specs, labels)

		specs = { { "Auto", function() control("season", "") end, "Follow the calendar from the next map change", function() return tod.season_cvar:GetString() == "" end, COL.ink } }
		for _, season in ipairs({ "summer", "autumn", "winter" }) do
			specs[#specs + 1] = { season, function() control("season", season) end, "Lock the season to " .. season .. " from the next map change", function() return tod.season_cvar:GetString():lower() == season end }
		end
		overrideRow(tab, rx, h - rowH, rw, rowH, specs, labels)
	end

	function tab:Paint()
		local mode = tod.GetMode()
		local cycle = currentCycle()
		section(0, 0, lw, "TIME", MODE_NAMES[mode] or "OFFLINE", mode == 1 and COL.mid or COL.amber)
		local cw = say(clock(cycle), FONT.huge, 0, clockY, COL.bright)
		local ix = cw + px(20)
		local capY = clockY + H.huge * 0.24 - H.small * 0.24
		say(mode == 1 and "SERVER CLOCK" or mode == 2 and "DEMO CYCLE" or "HELD BY ADMIN", FONT.small, ix, capY, mode == 1 and COL.mid or COL.amber)
		say(utcLabel(), FONT.small, ix, capY + H.small, COL.dim)

		local colW = math.floor((lw - px(28)) / 2)
		leader(0, sunY, colW, "SUNRISE", chart.Rise and clock(chart.Rise / 24) or "--:--")
		leader(lw - colW, sunY, colW, "SUNSET", chart.Set and clock(chart.Set / 24) or "--:--")

		local forced = tod.force_weather ~= nil
		local current = tod.GetCurrentWeather()
		local accent = forced and COL.amber or COL.bright
		section(rx, 0, rw, "WEATHER", forced and "FORCED" or "SCHEDULED", forced and COL.amber or COL.mid)
		if reveal(10) > 0 then glyph(weatherGlyph(current, cycle, samples), rx, glyphY, big, accent) end
		local nx = rx + big * 7 + px(18)
		local cy = glyphY + big * 3.5
		local nw = say(current:upper(), FONT.big, nx, cy, accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		local amount = weatherAmount(current)
		if amount < 1 then
			say(percent(amount), FONT.body, nx + nw + px(12), cy + px(4), COL.mid, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end

		local fc = getForecast()
		local hovered = strip:IsHovered() and strip:Slot()
		local g = math.max(2, px(2))
		local f = reveal(48)
		for i = 0, math.floor(24 * f) - 1 do
			local x = math.floor(rx + i * cell)
			local cellW = math.floor(rx + (i + 1) * cell) - x - px(2)
			local col = i == 0 and COL.bright or COL.mid
			if i == hovered then
				rect(x, stripY, cellW, stripH, COL.ink)
				col = COL.screen
			elseif i == 0 then
				outline(x, stripY, cellW, stripH, COL.dim)
			end
			local name = weatherGlyph(fc.names[i], slotCycle((fc.slot + i) * tod.WEATHER_SLOT), samples)
			glyph(name, x + math.floor((cellW - g * 7) / 2), stripY + math.floor((stripH - g * 7) / 2), g, col)
		end

		local ly = stripY + stripH + px(6)
		say("NOW", FONT.small, rx, ly, COL.dim)
		say("+24H", FONT.small, rx + rw, ly, COL.dim, TEXT_ALIGN_RIGHT)
		local ny = ly + H.small + px(10)
		if fc.next then
			leader(rx, ny, rw, "NEXT CHANGE", fc.next:upper() .. " IN " .. duration(fc.nextSlot * tod.WEATHER_SLOT - os.time()))
		else
			leader(rx, ny, rw, "NEXT CHANGE", "NONE THIS WEEK", COL.mid)
		end

		local season = tod.GetSeason()
		local loaded = tod.loaded_season or season
		local now = os.date("*t")
		local calendar = calendarSeason(now.month)
		local seasonForced = tod.season_cvar:GetString() ~= ""
		section(rx, sy, rw, "SEASON", seasonForced and "FORCED" or "CALENDAR", seasonForced and COL.amber or COL.mid)
		say(loaded:upper(), FONT.big, rx, nameY, loaded ~= calendar and COL.amber or COL.bright)
		local noteY = nameY + H.big * 0.8 - H.small * 0.8
		if season ~= loaded then
			say(season:upper() .. " ON NEXT MAP LOAD", FONT.small, rx + rw, noteY, COL.amber, TEXT_ALIGN_RIGHT)
		elseif loaded ~= calendar then
			say("CALENDAR " .. calendar:upper(), FONT.small, rx + rw, noteY, COL.mid, TEXT_ALIGN_RIGHT)
		end

		local month = rw / 12
		f = reveal(24)
		for i = 0, math.floor(12 * f) - 1 do
			local x = math.floor(rx + i * month)
			local cellW = math.floor(rx + (i + 1) * month) - x - px(2)
			local isNow = i + 1 == now.month
			local inSeason = MONTH_SEASONS[i] == calendar
			if isNow then
				rect(x, rulerY, cellW, rulerH, COL.ink)
			else
				rect(x, rulerY + rulerH - 1, cellW, 1, inSeason and COL.mid or COL.line)
			end
			text(MONTHS[i + 1], FONT.small, x + cellW / 2, rulerY + rulerH / 2, isNow and COL.screen or inSeason and COL.bright or COL.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		if f >= 1 then
			local days = os.date("*t", os.time({ year = now.year, month = now.month + 1, day = 0, hour = 12 })).day
			local tx = math.floor(rx + (now.month - 1 + (now.day - 1 + now.hour / 24) / days) * month)
			rect(tx, rulerY + rulerH + px(3), 1, px(5), COL.bright)
		end

		local nextSeason, at = nextCalendarSeason(now)
		if nextSeason then
			leader(rx, rulerY + rulerH + px(16), rw, "NEXT SEASON", nextSeason:upper() .. " IN " .. duration(at - os.time()))
		end

		for _, label in ipairs(labels) do
			say("OVERRIDE", FONT.small, label[1], label[2], COL.amber, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
	end
end

local function buildEffects(tab, w, h)
	local gap = px(24)
	local masterH = px(40)
	local headH = H.small + px(2)
	local rowH = px(26)
	local benchW = px(190)

	local master = vgui.Create("BorealisToggle", tab)
	master:Setup("Borealis effects", GetConVar("borealis_enabled"), "Switch all effects on or off")
	master.Master = true
	master:SetPos(0, 0)
	master:SetSize(w - benchW * 2 - gap * 2, masterH)

	local names = { "borealis_enabled" }
	for _, group in ipairs(EFFECT_GROUPS) do
		for _, entry in ipairs(group[2]) do
			names[#names + 1] = entry[1]
		end
	end
	for _, entry in ipairs(EFFECT_SLIDERS) do
		names[#names + 1] = entry[1]
	end

	local confirmUntil = 0
	local reset = vgui.Create("BorealisButton", tab)
	reset:Setup(function() return RealTime() < confirmUntil and "Confirm reset" or "Factory settings" end, function()
		if RealTime() >= confirmUntil then
			confirmUntil = RealTime() + 3
			return
		end

		confirmUntil = 0
		for _, name in ipairs(names) do
			local convar = GetConVar(name)
			if convar and convar:GetString() ~= convar:GetDefault() then
				RunConsoleCommand(name, convar:GetDefault())
			end
		end
	end, "Restore factory settings. Press twice to confirm", COL.danger)
	reset.IsActive = function() return RealTime() < confirmUntil end
	reset:SetPos(w - benchW * 2 - gap, math.floor((masterH - px(28)) / 2))
	reset:SetSize(benchW, px(28))

	local bench = vgui.Create("BorealisButton", tab)
	bench:Setup("Run benchmark", function()
		menu.Close()
		RunConsoleCommand("borealis_shaderpack_bench")
	end, "Measure the cost of each effect. Copy results to clipboard")
	bench:SetPos(w - benchW, math.floor((masterH - px(28)) / 2))
	bench:SetSize(benchW, px(28))

	local top = masterH + px(22)
	local cols = #EFFECT_GROUPS
	local cw = math.floor((w - gap * (cols - 1)) / cols)
	local groups, tallest = {}, 0

	for i, group in ipairs(EFFECT_GROUPS) do
		local x = (i - 1) * (cw + gap)
		local y = top + headH + px(10)
		local convars = {}
		for _, entry in ipairs(group[2]) do
			local convar = GetConVar(entry[1])
			if convar and (not entry.show or entry.show()) then
				local toggle = vgui.Create("BorealisToggle", tab)
				toggle:Setup(entry[2], convar, entry[3])
				toggle:SetPos(x, y)
				toggle:SetSize(cw, rowH)
				convars[#convars + 1] = convar
				y = y + rowH
			end
		end

		groups[i] = { x = x, name = group[1], convars = convars }
		tallest = math.max(tallest, y - top)
	end

	local dy = top + tallest + px(26)
	local sw = math.floor((w - gap * (#EFFECT_SLIDERS - 1)) / #EFFECT_SLIDERS)
	local n = 0
	for _, entry in ipairs(EFFECT_SLIDERS) do
		local convar = GetConVar(entry[1])
		if convar then
			local slider = vgui.Create("BorealisSlider", tab)
			slider:Setup(entry[2], entry[3], entry[4], entry[5], convar, entry[6])
			slider:SetPos(n * (sw + gap), dy + headH + px(16))
			slider:SetSize(sw, H.small + px(20))
			n = n + 1
		end
	end

	function tab:Paint()
		for _, group in ipairs(groups) do
			local count = 0
			for _, convar in ipairs(group.convars) do
				if convar:GetBool() then count = count + 1 end
			end
			section(group.x, top, cw, group.name, count .. "/" .. #group.convars)
		end

		section(0, dy, w, "DETAIL")
	end
end

local CARD = {}

function CARD:Init()
	self:SetText("")
	self.Avatar = vgui.Create("AvatarImage", self)
	self.Avatar:SetMouseInputEnabled(false)
end

local AVATAR = 48

function CARD:Setup(entry, width)
	self.Lines = wrap((entry.role or ""):upper(), FONT.small, width - px(AVATAR) - px(30))

	if entry.url then
		self.URL = entry.url
		self.Name = entry.name:upper()
		self.Icon = entry.icon and Material(entry.icon, "smooth")
		self.BorealisHelp = "Open " .. entry.url:gsub("^https?://", "")
		self.Avatar:SetVisible(false)
		return self
	end

	local id = entry.steamid
	if id:find("^STEAM_") then id = util.SteamIDTo64(id) end
	self.URL = "https://steamcommunity.com/profiles/" .. id
	self.Name = (entry.name or id):upper()
	self.BorealisHelp = "Open Steam profile"
	self.Avatar:SetSteamID(id, 64)

	if not entry.name then
		steamworks.RequestPlayerInfo(id, function(name)
			if IsValid(self) and name and name ~= "" then self.Name = name:upper() end
		end)
	end

	return self
end

function CARD:PerformLayout(w, h)
	local size = px(AVATAR)
	self.Avatar:SetPos(px(10), math.floor((h - size) / 2))
	self.Avatar:SetSize(size, size)
end

function CARD:Paint(w, h)
	local shown = reveal(4) > 0
	self.Avatar:SetAlpha(shown and 255 or 0)
	if not shown then return end

	local hovered = self:IsHovered()
	if hovered then
		rect(0, 0, w, h, COL.hover)
		rect(0, 0, px(3), h, COL.ink)
	end

	local size = px(AVATAR)
	local ay = math.floor((h - size) / 2)
	outline(px(9), ay - 1, size + 2, size + 2, hovered and COL.ink or COL.dim)
	if self.Icon then
		surface.SetMaterial(self.Icon)
		surface.SetDrawColor(255, 255, 255)
		surface.DrawTexturedRect(px(10), ay, size, size)
	end

	local x = size + px(22)
	local y = px(4)
	say(self.Name, FONT.body, x, y, hovered and COL.ink or COL.bright)
	y = y + H.body - px(2)
	for _, line in ipairs(self.Lines) do
		say(line, FONT.small, x, y, COL.mid)
		y = y + H.small
	end
end

function CARD:DoClick()
	playUI(SOUND.click, CLICK_VOLUME)
	gui.OpenURL(self.URL)
end

vgui.Register("BorealisCreditCard", CARD, "DButton")

local function buildCredits(tab, w, h)
	local gap, vgap = px(24), px(12)
	local cols = 3
	local cw = math.floor((w - gap * (cols - 1)) / cols)
	local ch = px(68)
	local top = H.small + px(20)
	local credits = table.Copy(shaderpack.credits or {})
	local lp = LocalPlayer()
	local you = IsValid(lp) and lp:SteamID64()
	for _, entry in ipairs(credits) do
		if entry.steamid == you then you = nil end
	end
	if you then
		credits[#credits + 1] = { steamid = you, name = lp:Nick(), role = "For your interest, and your GPU" }
	end

	for i, entry in ipairs(credits) do
		local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
		local card = vgui.Create("BorealisCreditCard", tab)
		card:Setup(entry, cw)
		card:SetPos(col * (cw + gap), top + row * (ch + vgap))
		card:SetSize(cw, ch)
	end

	function tab:Paint()
		section(0, 0, w, "CREDITS", #credits .. (#credits == 1 and " ENTRY" or " ENTRIES"))
		say("TYPEFACES  NINE CIRCLES BY HIVEHEAD, AUDIOWIDE BY ASTIGMATIC, VT323 BY PETER HULL, SIL OPEN FONT LICENSE", FONT.small, 0, h - H.small, COL.dim)
	end
end

local TABS = {
	{ "status", "Status", buildStatus },
	{ "effects", "Effects", buildEffects },
	{ "credits", "Credits", buildCredits },
}

local MAT

local function shaderReady()
	if not shaderpack.Available({ PS, VS }) then return false end

	if not MAT then
		MAT = CreateShaderMaterial("borealis_menu_" .. os.time(), {
			["$pixshader"] = PS,
			["$vertexshader"] = VS,
			["$basetexture"] = "_rt_FullFrameFB",
			["$linearread_basetexture"] = 0,
			["$linearwrite"] = 0,
			["$alpha_blend"] = 0,
			["$additive"] = 0,
			["$ignorez"] = 1,
			["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 1, ["$c0_w"] = 1,
			["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
			["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
			["$c3_x"] = 1, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
		})
	end

	return true
end

local FRAME = {}

function FRAME:Init()
	self.Opened = RealTime()
	self.Shadow = px(6)

	surface.SetFont(FONT.title)
	local _, th = surface.GetTextSize(TITLE)
	self.TitleW = th
	self.WindowX = th + self.Shadow + px(12)

	self:SetSize(self.WindowX + px(WINDOW_W), px(WINDOW_H))
	self:Center()
	self:MakePopup()
	self:SetKeyboardInputEnabled(false)

	local w, h = self:GetSize()
	self.Side, self.TopH, self.BotH = px(22), px(44), px(78)
	self.ScreenX, self.ScreenY = self.WindowX + self.Side, self.TopH
	self.ScreenW, self.ScreenH = w - self.ScreenX - self.Side, h - self.TopH - self.BotH

	local pad = px(30)
	self.ContentX, self.ContentW = self.ScreenX + pad, self.ScreenW - pad * 2
	self.HeadY = self.ScreenY + px(20)
	self.PromptY = self.ScreenY + self.ScreenH - px(20) - H.small
	local cy = self.HeadY + H.small + px(20)
	local ch = self.PromptY - px(16) - cy

	self.Tabs, self.Keys = {}, {}
	local keyW, keyH = px(124), px(40)
	self.KeyY = h - self.BotH + px(26)
	local kx = self.ScreenX
	for _, spec in ipairs(TABS) do
		local id = spec[1]
		local key = vgui.Create("BorealisKey", self)
		key:Setup(spec[2], function() self:SetTab(id) end)
		key.IsActive = function() return self.Active == id end
		key:SetPos(kx, self.KeyY)
		key:SetSize(keyW, keyH)
		self.Keys[#self.Keys + 1] = key
		kx = kx + keyW + px(10)

		local tab = vgui.Create("EditablePanel", self)
		tab:SetPos(self.ContentX, cy)
		tab:SetSize(self.ContentW, ch)
		tab:SetVisible(false)
		spec[3](tab, self.ContentW, ch)
		self.Tabs[id] = tab
	end

	local offW = px(84)
	self.OffX = w - self.Side - offW
	local off = vgui.Create("BorealisKey", self)
	off:Setup("Off", function() self:Close() end, CASE.orange, "Close")
	off:SetPos(self.OffX, self.KeyY)
	off:SetSize(offW, keyH)

	self:SetTab(menu.LastTab or "status")
	tty.start = self.Opened + 0.32

	local idle = not menu.LastUsed or RealTime() - menu.LastUsed >= JINGLE_IDLE
	playUI(idle and SOUND.on or SOUND.onShort, ON_VOLUME)
	self.Hum = loopUI(SOUND.hum, HUM_VOLUME)
end

function FRAME:StopTyping()
	if self.Typing then
		self.Typing:Stop()
		self.Typing = nil
	end
end

function FRAME:SetTab(id)
	if self.Active ~= id then
		tty.start = RealTime() + 0.04
		if self.Active then playUI(SOUND.tab, TAB_VOLUME) end
	end
	self.Active = id
	menu.LastTab = id
	for tabId, tab in pairs(self.Tabs) do
		tab:SetVisible(tabId == id)
	end
end

function FRAME:Close()
	if self.Closing then return end

	playUI(SOUND.off, OFF_VOLUME)
	self:StopTyping()
	if self.Hum then
		self.Hum:FadeOut(HUM_FADE)
		self.Hum = nil
	end

	if not shaderReady() then
		self:Remove()
		return
	end

	self.Closing = RealTime()
	self:SetMouseInputEnabled(false)
end

function FRAME:Think()
	if self.Closing and RealTime() - self.Closing > 0.3 then
		self:SetVisible(false)
		self:Remove()
	end
end

function FRAME:Power()
	if self.Closing then return math.Clamp((RealTime() - self.Closing) / 0.2, 0, 1) end

	return 1 - math.Clamp((RealTime() - self.Opened - 0.08) / 0.28, 0, 1)
end

function FRAME:Fade()
	if self.Closing then return 1 - math.Clamp((RealTime() - self.Closing - 0.18) / 0.1, 0, 1) end

	return math.Clamp((RealTime() - self.Opened) / 0.12, 0, 1)
end

function FRAME:TitlePass(cx, cy, col)
	surface.SetFont(FONT.title)
	local tw, th = surface.GetTextSize(TITLE)
	local sx, sy = self:LocalToScreen(cx, cy)
	local m = Matrix()
	m:Translate(Vector(sx, sy, 0))
	m:Rotate(Angle(0, -90, 0))
	m:Translate(Vector(-sx, -sy, 0))

	cam.PushModelMatrix(m, true)
	surface.SetTextColor(col)
	surface.SetTextPos(cx - math.floor(tw / 2), cy - math.floor(th / 2))
	surface.DrawText(TITLE)
	cam.PopModelMatrix()
end

function FRAME:DrawTitle()
	local cx, cy = math.floor(self.TitleW / 2), math.floor(self:GetTall() / 2)

	surface.DisableClipping(true)
	self:TitlePass(cx + self.Shadow, cy + self.Shadow, color_black)
	self:TitlePass(cx, cy, color_white)
	surface.DisableClipping(false)
end

local function bevel(x, y, w, h, hi, lo)
	rect(x, y, w, 1, hi)
	rect(x, y, 1, h, hi)
	rect(x, y + h - 1, w, 1, lo)
	rect(x + w - 1, y, 1, h, lo)
end

local function engrave(str, font, x, y, ax)
	text(str, font, x, y - 1, CASE.lo, ax, TEXT_ALIGN_CENTER)
	text(str, font, x, y + 1, CASE.hi, ax, TEXT_ALIGN_CENTER)

	return text(str, font, x, y, CASE.ink, ax, TEXT_ALIGN_CENTER)
end

local function rivet(x, y)
	local r = px(3)
	draw.RoundedBox(r, x - r + 1, y - r + 1, r * 2, r * 2, CASE.lo)
	draw.RoundedBox(r, x - r, y - r, r * 2, r * 2, CASE.metalTop)
	rect(x - 1, y - 1, 1, 1, CASE.hi)
end

function FRAME:Led(x, y, w, h, col)
	local r = px(3)
	rect(x - r, y - r, w + r * 2, h + r * 2, CASE.lo)
	rect(x - r, y + h + r, w + r * 2, 1, CASE.hi)
	rect(x - r + 1, y - r + 1, w + r * 2 - 2, h + r * 2 - 2, CASE.recess)

	if not col then
		rect(x, y, w, h, CASE.ledOff)
		rect(x, y, w, 1, mix(CASE.ledOff, WHITE, 0.12))
		return
	end

	render.OverrideBlend(true, BLEND_SRC_ALPHA, BLEND_ONE, BLENDFUNC_ADD)
	for i = 3, 1, -1 do
		local g = i * px(3)
		draw.RoundedBox(g, x - g, y - g, w + g * 2, h + g * 2, ColorAlpha(col, 22 - i * 5))
	end
	render.OverrideBlend(false)

	rect(x, y, w, h, col)
	rect(x, y, w, 1, mix(col, WHITE, 0.65))
	rect(x, y + h - 1, w, 1, mix(col, BLACK, 0.25))
end

function FRAME:DrawPlate(x, cy)
	local h = px(28)
	local y = cy - math.floor(h / 2)
	local inset = px(4)
	local block = h - inset * 2
	local label, model = "ATMOSPHERIC MONITOR", "MODEL BX-26"
	surface.SetFont(FONT.plate)
	local lw = surface.GetTextSize(label) + px(24)
	surface.SetFont(FONT.label)
	local mw = surface.GetTextSize(model)
	local w = px(14) + block + lw + px(12) + mw + px(20)

	rect(x + 1, y + 1, w, h, CASE.shadow)
	rect(x, y, w, h, CASE.metal)
	surface.SetMaterial(GRADIENT)
	surface.SetDrawColor(CASE.metalTop)
	surface.DrawTexturedRect(x, y, w, h)
	bevel(x, y, w, h, CASE.hi, CASE.lo)

	local ox, by = x + px(14), y + inset
	rect(ox, by, block, block, CASE.orange)
	bevel(ox, by, block, block, mix(CASE.orange, WHITE, 0.35), mix(CASE.orange, BLACK, 0.4))

	local lx = ox + block + px(2)
	rect(lx, by, lw, block, CASE.plate)
	bevel(lx, by, lw, block, BLACK, CASE.hi)
	text(label, FONT.plate, lx + px(12), cy, CASE.ink, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

	engrave(model, FONT.label, lx + lw + px(12), cy)

	rivet(x + px(7), cy)
	rivet(x + w - px(7), cy)
end

function FRAME:DrawCasing(w, h)
	local x0 = self.WindowX
	local ww = w - x0

	surface.DisableClipping(true)
	rect(x0 + self.Shadow, self.Shadow, ww, h, CASE.shadow)
	surface.DisableClipping(false)

	rect(x0, 0, ww, h, CASE.body)
	surface.SetMaterial(GRADIENT)
	surface.SetDrawColor(CASE.top)
	surface.DrawTexturedRect(x0, 0, ww, math.floor(h * 0.6))
	rect(x0, 0, ww, 1, CASE.edge)
	rect(x0, 0, 1, h, CASE.edge)
	rect(w - 1, 0, 1, h, CASE.shade)
	rect(x0, h - 1, ww, 1, CASE.shade)

	local sx, sy, sw, sh = self.ScreenX, self.ScreenY, self.ScreenW, self.ScreenH
	local lip = px(8)
	rect(sx - lip, sy - lip, sw + lip * 2, sh + lip * 2, CASE.shade)
	rect(sx - lip, sy + sh + lip - 1, sw + lip * 2, 1, CASE.edge)
	rect(sx - px(3), sy - px(3), sw + px(6), sh + px(6), CASE.recess)

	local seam = sy + sh + px(16)
	rect(x0 + 1, seam, ww - 2, 1, CASE.shade)
	rect(x0 + 1, seam + 1, ww - 2, 1, CASE.edge)

	local py = math.floor((sy - lip) / 2)
	self:DrawPlate(sx - px(6), py)

	local lx = sx + sw - px(16)
	self:Led(lx, py - px(2), px(16), px(5), isAdmin() and COL.ink)
	engrave("ADMIN", FONT.label, lx - px(12), py, TEXT_ALIGN_RIGHT)

	for _, key in ipairs(self.Keys) do
		local kx = key:GetPos()
		self:Led(kx + math.floor(key:GetWide() / 2) - px(8), self.KeyY - px(12), px(16), px(4), key:IsActive() and COL.ink)
	end

	for i = 1, 10 do
		rect(self.OffX - px(24) - i * px(8), self.KeyY + px(4), px(3), px(28), CASE.shade)
	end
end

function FRAME:DrawScreen()
	local sx, sy, sw, sh = self.ScreenX, self.ScreenY, self.ScreenW, self.ScreenH
	local cx, cw = self.ContentX, self.ContentW
	rect(sx, sy, sw, sh, COL.screen)

	say("MAP " .. game.GetMap():upper(), FONT.small, cx, self.HeadY, COL.mid)
	say(os.date("%d %b %Y  %H:%M:%S"):upper(), FONT.small, cx + cw, self.HeadY, COL.mid, TEXT_ALIGN_RIGHT)
	rect(cx, self.HeadY + H.small + px(4), cw, 1, COL.line)

	local hovered = vgui.GetHoveredPanel()
	local help
	while IsValid(hovered) and hovered ~= self do
		help = hovered.BorealisHelp
		if help then break end
		hovered = hovered:GetParent()
	end
	if isfunction(help) then help = help(hovered) end

	if help ~= self.Help then
		self.Help = help
		self.HelpStart = RealTime()
		self:StopTyping()
		if help and not self.Closing then self.Typing = loopUI(SOUND.typing, TYPING_VOLUME) end
	end

	rect(cx, self.PromptY - px(8), cw, 1, COL.line)
	if not help then return end

	local str = "> " .. help:upper()
	local n = 2 + math.floor((RealTime() - self.HelpStart) * 120)
	if n >= #str then self:StopTyping() end
	local tw = text(str:sub(1, n), FONT.small, cx, self.PromptY, COL.ink)
	if n < #str or (RealTime() - self.HelpStart) % 1 < 0.55 then
		rect(cx + tw + px(3), self.PromptY + H.small * 0.2, H.small * 0.42, H.small * 0.62, COL.ink)
	end
end

local underRT, underMat

local function underlay()
	local w, h = ScrW(), ScrH()
	if not underRT or underRT:Width() ~= w or underRT:Height() ~= h then
		local name = "borealis_menu_under_" .. w .. "x" .. h
		underRT = GetRenderTargetEx(name, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGB888)
		underMat = CreateMaterial(name, "UnlitGeneric", {
			["$basetexture"] = underRT:GetName(),
			["$vertexalpha"] = 1,
			["$vertexcolor"] = 1,
			["$ignorez"] = 1,
		})
	end

	return underRT, underMat
end

function FRAME:Paint(w, h)
	tty.used = 0
	local fade = self:Fade()
	self.Underlay = fade < 1 and fade or nil
	if self.Underlay then
		local rt = underlay()
		render.CopyRenderTargetToTexture(rt)
	end
	self:DrawTitle()
	self:DrawCasing(w, h)
	self:DrawScreen()
end

local setConstant = shaderpack.SetConstant

function FRAME:PaintOver(w, h)
	local sx, sy, sw, sh = self.ScreenX, self.ScreenY, self.ScreenW, self.ScreenH
	local p = self:Power()

	if shaderReady() then
		if p < 1 then
			local x, y = self:LocalToScreen(sx, sy)
			render.UpdateScreenEffectTexture()
			MAT:SetTexture("$basetexture", render.GetScreenEffectTexture())
			setConstant(MAT, "$c0", x, y, sw, sh)
			setConstant(MAT, "$c1", 1 / ScrW(), 1 / ScrH(), RealTime() % 1000)
			setConstant(MAT, "$c2", 0.45, 0.18, 0.6, 0.012)
			setConstant(MAT, "$c3", p)

			surface.SetMaterial(MAT)
			surface.SetDrawColor(255, 255, 255)
			surface.DrawTexturedRect(sx, sy, sw, sh)
		else
			rect(sx, sy, sw, sh, BLACK)
		end
	end

	if self.Underlay then
		local _, mat = underlay()
		local x, y = self:LocalToScreen(0, 0)
		local fw, fh = w + self.Shadow, h + self.Shadow
		local scrW, scrH = ScrW(), ScrH()
		surface.SetMaterial(mat)
		surface.SetDrawColor(255, 255, 255, (1 - self.Underlay) * 255)
		surface.DisableClipping(true)
		surface.DrawTexturedRectUV(0, 0, fw, fh, x / scrW, y / scrH, (x + fw) / scrW, (y + fh) / scrH)
		surface.DisableClipping(false)
	end
end

function FRAME:OnRemove()
	menu.LastUsed = RealTime()
	hook.Remove("OnPauseMenuShow", TAG)
	self:StopTyping()
	if self.Hum then
		self.Hum:Stop()
		self.Hum = nil
	end
end

vgui.Register("BorealisMenu", FRAME, "EditablePanel")

function menu.Open()
	if IsValid(menu.Frame) then menu.Frame:Remove() end

	menu.Frame = vgui.Create("BorealisMenu")
	hook.Add("OnPauseMenuShow", TAG, function()
		if IsValid(menu.Frame) then
			menu.Frame:Close()
			return false
		end
	end)
end

function menu.Close()
	if IsValid(menu.Frame) then menu.Frame:Close() end
end

function menu.Toggle()
	if IsValid(menu.Frame) and not menu.Frame.Closing then
		menu.Close()
	else
		menu.Open()
	end
end

concommand.Add(TAG, menu.Toggle)

hook.Add("OnScreenSizeChanged", TAG, function()
	buildFonts()
	if IsValid(menu.Frame) then menu.Open() end
end)

list.Set("DesktopWindows", "BorealisMenu", {
	title = "Borealis",
	icon = "shaderpack/menu/icon64.png",
	width = 1,
	height = 1,
	onewindow = false,
	init = function(_, window)
		window:Remove()
		menu.Open()
	end,
})
