local chunks = shaderpack.chunks or {}
shaderpack.chunks = chunks
chunks.grids = chunks.grids or {}

local grids = chunks.grids
chunks.MAX_DISTANCE = jit.arch == "x64" and 16384 or 6144

local MIN_BUDGET_MS, MAX_BUDGET_MS = 8, 12
local TARGET_FRAME_MS = 16
local EVICT_INTERVAL = 2

local Grid = {}
Grid.__index = Grid

function chunks.Key(cx, cy)
	return cx * 65536 + cy
end

local view = { frame = -1 }

function chunks.View()
	local eye, ang = EyePos(), EyeAngles()
	if view.frame == FrameNumber() and view.eye == eye and view.ang == ang then return view end

	local vs = render.GetViewSetup()
	view.frame, view.eye, view.ang = FrameNumber(), eye, ang
	view.fwd, view.right, view.up = EyeVector(), ang:Right(), ang:Up()
	view.amb, view.tonemap = render.GetAmbientLightColor(), render.GetToneMappingScaleLinear().x
	view.tanH = math.tan(math.rad(vs.fov or 90) * 0.5)
	view.tanV = view.tanH / (vs.aspect or (ScrW() / ScrH()))

	return view
end

local Sight = {}
Sight.__index = Sight

function chunks.Sight()
	return setmetatable({}, Sight)
end

function Sight:Begin(eye)
	local bspdata = bspdata
	self.cluster = bspdata.ClusterAt(eye.x, eye.y, eye.z)
	self.pvs = bspdata.PVS(self.cluster)
end

function Sight:Shows(g)
	local c = g.cluster
	if c == self.cluster then return true end

	local pvs = self.pvs
	if pvs ~= nil and c >= 0 and not pvs[c] then return false end

	return true
end

local stepStart, stepBudget, lastThinkMs = 0, MIN_BUDGET_MS, 0

function chunks.YieldIfOverBudget()
	if (SysTime() - stepStart) * 1000 > stepBudget then
		coroutine.yield()
	end
end

function Grid:Start()
	self:Stop()
	self.chunks, self.queue = {}, {}
	self.queueDirty, self.evictNext = false, 0
	self.loader = coroutine.create(self.cfg.load)
	self.started = true
end

function Grid:Stop()
	if self.chunks and self.cfg.destroy then
		for _, ch in pairs(self.chunks) do
			self.cfg.destroy(ch)
		end
	end

	table.Empty(self.visible)
	self.chunks, self.queue, self.current, self.loader = nil, nil, nil, nil
	self.started, self.ready = false, false
end

function Grid:SetPaused(paused)
	self.paused = paused
end

function Grid:fail(message)
	ErrorNoHalt("[" .. self.cfg.name .. "] off: " .. tostring(message) .. "\n")
	self:Stop()
	if self.cfg.failed then self.cfg.failed() end
end

function Grid:stepLoad()
	local ok, res, why = coroutine.resume(self.loader)
	if not ok then
		self:fail(res)
	elseif coroutine.status(self.loader) == "dead" then
		if res then
			self.ready = true
			if self.preload then self:queuePreload() end
		else
			self:fail(why)
		end
	end
end

function Grid:queuePreload()
	local gridChunks, queue = self.chunks, self.queue
	for _, c in ipairs(self.preload) do
		local key = chunks.Key(c.cx, c.cy)
		if not gridChunks[key] then
			local ch = { cx = c.cx, cy = c.cy }
			gridChunks[key] = ch
			queue[#queue + 1] = ch
		end
	end

	self.queueDirty = true
end

function Grid:Preload(list)
	self.preload = list
	if self.ready and list then self:queuePreload() end
end

local function byPrioDesc(a, b)
	return a.prio > b.prio
end

function Grid:refreshQueue(eye, fwd)
	if not self.queueDirty and eye:DistToSqr(self.queueEye) <= self.size * self.size then return end

	self.queueDirty = false
	self.queueEye:Set(eye)
	local size, queue, gridChunks = self.size, self.queue, self.chunks
	local half = size * 0.5
	local n = 0
	for i = 1, #queue do
		local ch = queue[i]
		queue[i] = nil
		if not ch.built and gridChunks[chunks.Key(ch.cx, ch.cy)] == ch then
			local dx, dy = ch.cx * size + half - eye.x, ch.cy * size + half - eye.y
			local dist = math.sqrt(dx * dx + dy * dy)
			local behind = dist > size and (dx * fwd.x + dy * fwd.y) / dist < -0.35
			ch.prio = dist + (behind and self.radius or 0)
			n = n + 1
			queue[n] = ch
		end
	end

	table.sort(queue, byPrioDesc)
end

function Grid:bestQueued()
	local count = #self.queue

	return count > 0 and count or nil
end

function Grid:begin(index)
	local queue = self.queue
	local count = #queue
	local ch = queue[index]
	queue[index] = queue[count]
	queue[count] = nil
	ch.co = coroutine.create(self.cfg.build)
	self.current = ch
end

function Grid:finish(ch, cost)
	ch.built, ch.cost, ch.co = true, cost, nil
	self.current = nil
end

function Grid:stepBuild()
	local ch = self.current
	local ok, cost = coroutine.resume(ch.co, ch)
	if not ok then
		ErrorNoHalt("[" .. self.cfg.name .. "] chunk build failed: " .. tostring(cost) .. "\n")
		if self.cfg.destroy then self.cfg.destroy(ch) end
		self:finish(ch, 0)
	elseif coroutine.status(ch.co) == "dead" then
		self:finish(ch, cost or 0)
	end
end

local function byDrawDist(a, b)
	return a.drawDist < b.drawDist
end

function Grid:Visible(v)
	local eye, fwd, right, up, tanH, tanV = v.eye, v.fwd, v.right, v.up, v.tanH, v.tanV
	local kH, kV = math.sqrt(1 + tanH * tanH), math.sqrt(1 + tanV * tanV)
	local size, radius, pad = self.size, self.radius, self.pad
	local half = size * 0.5
	local gridChunks, visible = self.chunks, self.visible
	local n = math.ceil(radius / size)
	local ecx, ecy = math.floor(eye.x / size), math.floor(eye.y / size)
	local nvis = 0
	for cy = ecy - n, ecy + n do
		for cx = ecx - n, ecx + n do
			local ddx, ddy = cx * size + half - eye.x, cy * size + half - eye.y
			local dist = math.sqrt(ddx * ddx + ddy * ddy)
			if dist - half * 1.42 < radius then
				local key = chunks.Key(cx, cy)
				local ch = gridChunks[key]
				if not ch then
					ch = { cx = cx, cy = cy }
					gridChunks[key] = ch
					self.queue[#self.queue + 1] = ch
					self.queueDirty = true
				elseif ch.built and ch.cost > 0 then
					local ddz, r = ch.cz - eye.z, ch.radius + pad
					local fz = ddx * fwd.x + ddy * fwd.y + ddz * fwd.z
					if fz > -r then
						local fx = ddx * right.x + ddy * right.y + ddz * right.z
						local fy = ddx * up.x + ddy * up.y + ddz * up.z
						if math.abs(fx) < fz * tanH + r * kH and math.abs(fy) < fz * tanV + r * kV then
							ch.drawDist = dist
							nvis = nvis + 1
							visible[nvis] = ch
						end
					end
				end
			end
		end
	end

	for i = #visible, nvis + 1, -1 do
		visible[i] = nil
	end

	table.sort(visible, byDrawDist)

	return visible
end

function Grid:evict(eye)
	local now = RealTime()
	if now < self.evictNext then return end
	self.evictNext = now + EVICT_INTERVAL

	local size = self.size
	local half = size * 0.5
	local limit = (self.radius + size * 2) ^ 2
	local gridChunks = self.chunks
	local far, cached = {}, 0
	for key, ch in pairs(gridChunks) do
		local dx, dy = ch.cx * size + half - eye.x, ch.cy * size + half - eye.y
		local d = dx * dx + dy * dy
		if d > limit and ch ~= self.current then
			if not ch.built then
				if not self.preload then
					gridChunks[key] = nil
					self.queueDirty = true
				end
			elseif ch.cost > 0 then
				ch.evictDist = d
				far[#far + 1] = ch
				cached = cached + ch.cost
			end
		end
	end

	if cached <= self.cacheLimit then return end

	table.sort(far, function(a, b) return a.evictDist > b.evictDist end)
	for _, ch in ipairs(far) do
		if cached <= self.cacheLimit then break end
		cached = cached - ch.cost
		if self.cfg.destroy then self.cfg.destroy(ch) end
		gridChunks[chunks.Key(ch.cx, ch.cy)] = nil
	end
end

function chunks.Grid(cfg)
	local old = grids[cfg.name]
	if old then old:Stop() end

	local grid = setmetatable({
		cfg = cfg,
		size = cfg.size or 512,
		radius = cfg.radius or 3072,
		pad = cfg.pad or 0,
		cacheLimit = cfg.cacheLimit or math.huge,
		visible = {},
		queueEye = Vector(),
		started = false, ready = false, paused = false,
	}, Grid)
	grids[cfg.name] = grid

	return grid
end

local active

local function pickNext(eye, fwd)
	local best, bestIndex, bestPrio
	for _, grid in pairs(grids) do
		if grid.started and grid.ready and not grid.paused then
			local prio, index
			if grid.current then
				prio = grid.current.prio
			else
				grid:refreshQueue(eye, fwd)
				index = grid:bestQueued()
				prio = index and grid.queue[index].prio
			end

			if prio and (not bestPrio or prio < bestPrio) then
				best, bestIndex, bestPrio = grid, index, prio
			end
		end
	end

	if best and bestIndex then best:begin(bestIndex) end

	return best
end

local function think()
	local loading, any
	for _, grid in pairs(grids) do
		if grid.started and not grid.paused then
			any = true
			if not grid.ready then
				loading = grid
				break
			end
		end
	end

	if not any then return end

	local t0 = SysTime()
	stepStart = t0
	stepBudget = math.Clamp(TARGET_FRAME_MS - RealFrameTime() * 1000 + lastThinkMs, MIN_BUDGET_MS, MAX_BUDGET_MS)

	if loading then loading:stepLoad() end

	local eye, fwd = EyePos(), EyeVector()
	while (SysTime() - t0) * 1000 < stepBudget do
		if not active or not active.started or active.paused or not active.current then
			active = pickNext(eye, fwd)
			if not active then break end
		end

		active:stepBuild()
	end

	for _, grid in pairs(grids) do
		if grid.started and grid.ready and not grid.paused then
			grid:evict(eye)
		end
	end

	lastThinkMs = (SysTime() - t0) * 1000
end

hook.Add("Think", "borealis_chunks", think)
