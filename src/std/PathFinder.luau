local Path = {}
Path.__index = Path

Path.new = function() -- Creates a new Pathfinder with no Waypoints or Waypoint Connections
	local self = setmetatable({},Path)
	self.Waypoints = {} -- Dictionary of WaypointIndex:Waypoint
	self.Neighbors = {} -- Dictionary of WaypointIndex:{WaypointIndex:WaypointDistance}}
	self.NextSerial = 1 -- The serial of the next waypoint. Incremented with each call of AddWaypoint
	-- Performance caches (safe because the graph is static for the lifetime of a
	-- built pathfinder — the only mutators below invalidate both):
	--   _Spatial   : 3D cell-bucket index so GetNearestWaypoint is ~O(1) not O(N).
	--   _PathCache : memoized A* serial routes keyed "startSerial:endSerial".
	--                The A* ignores the CanReachFunction arg (routes are purely
	--                geometric), so a route between two serials never changes.
	self._Spatial = nil
	self._CellSize = 32
	self._PathCache = {}
	self._PathCacheCount = 0
	return self
end

-- Drops the perf caches. Call after any structural change to waypoints/edges.
function Path:_Invalidate()
	self._Spatial = nil
	self._PathCache = {}
	self._PathCacheCount = 0
end
Path.fromWaypoints = function(Waypoints,Neighbors) -- Creates a new Pathfinder with the Given Waypoints and Waypoint Connections
	local self = Path.new()
	local LargestSerial = 0
	for WaypointSerial,Waypoint in pairs(Waypoints) do
		if WaypointSerial>LargestSerial then
			LargestSerial = WaypointSerial
		end
		self.Waypoints[WaypointSerial] = Waypoint
	end
	self.Neighbors = Neighbors
	self.NextSerial = LargestSerial+1 -- Next free serial.
	return self
end
-- 
function Path:SetWaypointPosition(WaypointSerial:number,NewPosition:Vector3)
	assert(self.Waypoints[WaypointSerial],"No waypoint by serial: " .. tostring(WaypointSerial))
	self.Waypoints[WaypointSerial][1] = NewPosition
	self:_Invalidate()
end
function Path:SetWaypointLabel(WaypointSerial:number,NewLabel:string)
	assert(self.Waypoints[WaypointSerial],"No waypoint by serial: " .. tostring(WaypointSerial))
	self.Waypoints[WaypointSerial][2] = NewLabel
end
function Path:SetWaypointWeight(WaypointSerial:number,NewWeight:number)
	assert(self.Waypoints[WaypointSerial],"No waypoint by serial: " .. tostring(WaypointSerial))
	self.Waypoints[WaypointSerial][3] = NewWeight
end
--
function Path:AddWaypoint(Position:Vector3,Label:string,Weight:number) -- Adds a new  waypoint with the given information. Returns the NewWaypoint's serial.
	local WaypointData = {Position,tostring(Label) or "",tonumber(Weight) or 255}
	local WaypointSerial = self.NextSerial
	self.Waypoints[WaypointSerial] = WaypointData
	self.Neighbors[WaypointSerial] = {}
	self.NextSerial += 1
	self:_Invalidate()
	return WaypointSerial
end
function Path:RemoveWaypoint(WaypointSerial:number) -- Removes this Waypoint
	self.Waypoints[WaypointSerial] = nil
	for ConnectedSerial, _ in pairs(self.Neighbors[WaypointSerial]) do
		self:DisconnectWaypoints(WaypointSerial,ConnectedSerial)
	end
	self.Neighbors[WaypointSerial] = nil
	self:_Invalidate()
end
--
function Path:ConnectWaypoints(WaypointSerial1:number,WaypointSerial2:number,BiDirectional:boolean) -- Connect two waypoints.
	if WaypointSerial1 == WaypointSerial2 then warn(tostring(WaypointSerial1) .. " == " .. tostring(WaypointSerial2)) return end
	if not self.Neighbors[WaypointSerial1] then warn("Waypoint by serial: " .. tostring(WaypointSerial1) .. " does not exist") return end
	if not self.Neighbors[WaypointSerial2] then warn("Waypoint by serial: " .. tostring(WaypointSerial2) .. " does not exist") return end
	if BiDirectional then -- Waypoints are accessible by each other
		self.Neighbors[WaypointSerial1][WaypointSerial2] = true
		self.Neighbors[WaypointSerial2][WaypointSerial1] = true
	else -- Waypoint1 can reach Waypoint2 but not the other way around
		self.Neighbors[WaypointSerial1][WaypointSerial2] = true
		self.Neighbors[WaypointSerial2][WaypointSerial1] = false
	end
	self:_Invalidate()
end
function Path:DisconnectWaypoints(WaypointSerial1:number,WaypointSerial2:number) -- Disconnect the two waypoints.
	if not self.Neighbors[WaypointSerial1] then warn("Waypoint by serial: " .. tostring(WaypointSerial1) .. " does not exist") return end
	if not self.Neighbors[WaypointSerial2] then warn("Waypoint by serial: " .. tostring(WaypointSerial2) .. " does not exist") return end
	self.Neighbors[WaypointSerial1][WaypointSerial2] = nil -- Remove from memory
	self.Neighbors[WaypointSerial2][WaypointSerial1] = nil -- Remove from memory
	self:_Invalidate()
end
--
function Path:GetWaypointAtSerial(WaypointSerial:number) -- Returns the Waypoint's information at the given node serial. Return nil if there is no Waypoint at that serial.
	local WaypointData = self.Waypoints[WaypointSerial]
	if WaypointData then
		return {
			Position = WaypointData[1],
			Label = WaypointData[2], 
			Weight = WaypointData[3],
		} 
	else
		warn("No waypoint at serial: " .. tostring(WaypointSerial))
		return nil
	end
end
local function _cellKey(cx, cy, cz)
	return cx .. "_" .. cy .. "_" .. cz
end

-- Builds the 3D cell-bucket index over all waypoints (lazy; rebuilt after mutation).
function Path:_BuildSpatial()
	local cell = self._CellSize
	local buckets = {}
	for serial, data in pairs(self.Waypoints) do
		local p = data[1]
		local key = _cellKey(math.floor(p.X / cell), math.floor(p.Y / cell), math.floor(p.Z / cell))
		local b = buckets[key]
		if not b then b = {}; buckets[key] = b end
		b[#b + 1] = serial
	end
	self._Spatial = buckets
end

-- O(N) fallback (used only if the spatial search somehow finds nothing).
function Path:_GetNearestLinear(Position:Vector3)
	local best, bestDist = nil, math.huge
	for serial, data in pairs(self.Waypoints) do
		local d = (data[1] - Position).Magnitude
		if d < bestDist then bestDist = d; best = serial end
	end
	return best
end

function Path:GetNearestWaypoint(Position:Vector3) -- Returns the Waypoint closest to this position
	if not self._Spatial then self:_BuildSpatial() end
	local cell = self._CellSize
	local buckets = self._Spatial
	local cx = math.floor(Position.X / cell)
	local cy = math.floor(Position.Y / cell)
	local cz = math.floor(Position.Z / cell)

	local best, bestDist = nil, math.huge
	local MAX_RADIUS = 48 -- cell shells; generous cap before falling back to linear
	local r = 0
	while r <= MAX_RADIUS do
		-- scan only the shell at Chebyshev radius r
		for dx = -r, r do
			for dy = -r, r do
				for dz = -r, r do
					if math.max(math.abs(dx), math.abs(dy), math.abs(dz)) == r then
						local b = buckets[_cellKey(cx + dx, cy + dy, cz + dz)]
						if b then
							for _, serial in ipairs(b) do
								local d = (self.Waypoints[serial][1] - Position).Magnitude
								if d < bestDist then bestDist = d; best = serial end
							end
						end
					end
				end
			end
		end
		-- Once we have a candidate, points in shells beyond ceil(bestDist/cell)
		-- can't be closer — one extra shell past that is safe to stop.
		if best and (r * cell) >= bestDist then break end
		r += 1
	end

	if best then return best end
	return self:_GetNearestLinear(Position)
end

-- Returns the serials of every waypoint inside the world-space AABB [minV, maxV].
-- Uses the spatial buckets so it is cheap even on a dense graph.
function Path:GetWaypointsInRegion(minV, maxV)
	if not self._Spatial then self:_BuildSpatial() end
	local cell = self._CellSize
	local out = {}
	local cx0, cy0, cz0 = math.floor(minV.X/cell), math.floor(minV.Y/cell), math.floor(minV.Z/cell)
	local cx1, cy1, cz1 = math.floor(maxV.X/cell), math.floor(maxV.Y/cell), math.floor(maxV.Z/cell)
	for cx = cx0, cx1 do
		for cy = cy0, cy1 do
			for cz = cz0, cz1 do
				local bucket = self._Spatial[_cellKey(cx, cy, cz)]
				if bucket then
					for _, serial in ipairs(bucket) do
						local p = self.Waypoints[serial][1]
						if p.X >= minV.X and p.X <= maxV.X and p.Y >= minV.Y and p.Y <= maxV.Y and p.Z >= minV.Z and p.Z <= maxV.Z then
							table.insert(out, serial)
						end
					end
				end
			end
		end
	end
	return out
end
--
-- A* over the graph. Returns the ordered serial list start..goal (or nil if
-- unreachable). `validator(serial) -> boolean` optionally blocks waypoints
-- (e.g. ones occupied by stations); the goal is always allowed so the target
-- stays reachable. Routes are memoized by serial pair ONLY when no validator is
-- given (an avoidance route depends on dynamic station state, so it's not cached).
function Path:_AStarSerials(StartNodeSerial, EndNodeSerial, validator)
	local useCache = (validator == nil)
	local cacheKey = StartNodeSerial .. ":" .. EndNodeSerial
	if useCache then
		local cached = self._PathCache[cacheKey]
		if cached ~= nil then
			if cached == false then return nil end
			return cached
		end
	end

	local EndNode = self.Waypoints[EndNodeSerial]
	local OpenGCost = {[StartNodeSerial] = 0}
	local ClosedNodeSerials = {}
	local ParentLinks = {}
	local result = nil

	while true do
		local CurrentNodeSerial = nil
		local CurrentNodeGCost = nil
		local CurrentNodeFCost = math.huge

		for NodeSerial, StoredGCost in pairs(OpenGCost) do
			local Node = self.Waypoints[NodeSerial]
			local HCost = (Node[1] - EndNode[1]).Magnitude
			local FCost = StoredGCost + HCost
			if FCost < CurrentNodeFCost then
				CurrentNodeSerial = NodeSerial
				CurrentNodeGCost = StoredGCost
				CurrentNodeFCost = FCost
			end
		end

		if not CurrentNodeSerial then break end -- open set drained — no path

		OpenGCost[CurrentNodeSerial] = nil
		ClosedNodeSerials[CurrentNodeSerial] = true

		if CurrentNodeSerial == EndNodeSerial then
			local serials = {}
			local nextSerial = EndNodeSerial
			while nextSerial do
				table.insert(serials, 1, nextSerial)
				nextSerial = ParentLinks[nextSerial]
			end
			result = serials
			break
		end

		local CurrentNode = self.Waypoints[CurrentNodeSerial]
		local Neighbors = self.Neighbors[CurrentNodeSerial]
		if Neighbors then
			for NeighborSerial, CanReachNeighbor in pairs(Neighbors) do
				if not CanReachNeighbor then continue end
				if ClosedNodeSerials[NeighborSerial] then continue end
				-- Skip validator-blocked waypoints, but never block the goal itself
				-- (keeps the target, e.g. the Stockpile, reachable).
				if validator and NeighborSerial ~= EndNodeSerial and not validator(NeighborSerial) then continue end
				local NeighborNode = self.Waypoints[NeighborSerial]
				if not NeighborNode then continue end
				local TentativeGCost = CurrentNodeGCost + (NeighborNode[1] - CurrentNode[1]).Magnitude + (NeighborNode[3] or 0)
				local StoredGCost = OpenGCost[NeighborSerial]
				if StoredGCost == nil or TentativeGCost < StoredGCost then
					OpenGCost[NeighborSerial] = TentativeGCost
					ParentLinks[NeighborSerial] = CurrentNodeSerial
				end
			end
		end
	end

	-- Memoize (cap entries to bound memory; false marks a known-unreachable pair).
	if useCache and self._PathCacheCount < 8000 then
		self._PathCache[cacheKey] = result or false
		self._PathCacheCount += 1
	end
	return result
end
--
function Path:GetOrderedWaypoints(StartPosition:Vector3,EndPosition:Vector3,CanReachFunction:()->boolean) -- Returns an ordered path from StartPosition to EndPosition
	if StartPosition == EndPosition then -- Move directly to end position
		return {
			{Position = EndPosition,Label = "",Weight = 0}
		}
	end
	--
	local StartNodeSerial = self:GetNearestWaypoint(StartPosition)
	local EndNodeSerial = self:GetNearestWaypoint(EndPosition)

	if not StartNodeSerial or not EndNodeSerial then return nil end

	-- Cached A* (static graph) — returns the ordered serial route start..end.
	local serials = self:_AStarSerials(StartNodeSerial, EndNodeSerial, CanReachFunction)
	if not serials then return nil end

	-- Build the path from the cached serial route, then append the caller's true
	-- end position. The endpoint smoothing below uses the caller's real
	-- Start/End positions, so per-clone accuracy is preserved even though the
	-- core route is shared from the cache.
	local Path = {}
	for _, serial in ipairs(serials) do
		table.insert(Path, self:GetWaypointAtSerial(serial))
	end
	table.insert(Path, {Position=EndPosition, Label="", Weight=0})

	-- Endpoint smoothing — iteratively drop the first/last graph node when it
	-- (a) backtracks relative to the next/prior leg or (b) sits redundantly close
	-- to the start/end position. Both cause stiff micro-turns near objectives.
	-- Horizontal-only checks; vertical detours from ramps are intentional.
	local SKIP_NEAR_THRESHOLD = 6 -- studs; drop endpoint graph nodes closer than this
	local function horizontalDot(a, b)
		local ah = Vector3.new(a.X, 0, a.Z)
		local bh = Vector3.new(b.X, 0, b.Z)
		if ah.Magnitude < 0.01 or bh.Magnitude < 0.01 then return 1 end
		return ah.Unit:Dot(bh.Unit)
	end
	local function horizontalMag(a, b)
		local d = a - b
		return Vector3.new(d.X, 0, d.Z).Magnitude
	end

	-- Trim from the start side
	while #Path >= 2 do
		local toFirst = Path[1].Position - StartPosition
		local firstToSecond = Path[2].Position - Path[1].Position
		local backward = horizontalDot(toFirst, firstToSecond) < 0
		local redundant = horizontalMag(Path[1].Position, StartPosition) < SKIP_NEAR_THRESHOLD
		if backward or redundant then
			table.remove(Path, 1)
		else
			break
		end
	end

	-- Trim from the end side (Path[#Path] is the appended EndPosition; we trim
	-- the graph node sitting just before it).
	while #Path >= 3 do
		local prev = Path[#Path - 2].Position
		local last = Path[#Path - 1].Position
		local endPos = Path[#Path].Position
		local prevToLast = last - prev
		local lastToEnd = endPos - last
		local backward = horizontalDot(prevToLast, lastToEnd) < 0
		local redundant = horizontalMag(last, endPos) < SKIP_NEAR_THRESHOLD
		if backward or redundant then
			table.remove(Path, #Path - 1)
		else
			break
		end
	end
	--
	return Path
end
--
-- Debug visualizer — drops marker parts + connecting beams along a computed
-- route so the user can SEE what the pathfinder returns. Pass an optional
-- `parent` Instance to scope the markers (defaults to Workspace), and an
-- optional `tag` string used as the marker name + a folder grouping.
-- Returns the Folder containing the markers so the caller can :Destroy() it.
function Path:DebugVisualize(StartPosition:Vector3, EndPosition:Vector3, Parent:Instance?, Tag:string?)

	local Workspace = game:GetService("Workspace")
	local route = self:GetOrderedWaypoints(StartPosition, EndPosition, function() return true end)
	if not route or #route == 0 then return nil end

	local tagName = Tag or "PathDebug"
	local container = Instance.new("Folder")
	container.Name = tagName
	container.Parent = Parent or Workspace

	-- Start marker
	local startMarker = Instance.new("Part")
	startMarker.Name = "Start"
	startMarker.Shape = Enum.PartType.Ball
	startMarker.Size = Vector3.new(2, 2, 2)
	startMarker.Color = Color3.fromRGB(80, 220, 80)
	startMarker.Material = Enum.Material.Neon
	startMarker.Anchored = true
	startMarker.CanCollide = false
	startMarker.CanQuery = false
	startMarker.CanTouch = false
	startMarker.Position = StartPosition
	startMarker.Parent = container

	-- Waypoint markers — orange spheres at each routed node
	for i, waypoint in ipairs(route) do
		local marker = Instance.new("Part")
		marker.Name = `Node{i}`
		marker.Shape = Enum.PartType.Ball
		marker.Size = Vector3.new(1.5, 1.5, 1.5)
		marker.Color = Color3.fromRGB(240, 160, 30)
		marker.Material = Enum.Material.Neon
		marker.Transparency = 0.2
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.Position = waypoint.Position
		marker.Parent = container
	end

	-- End marker (overrides last waypoint's ball)
	local endMarker = Instance.new("Part")
	endMarker.Name = "End"
	endMarker.Shape = Enum.PartType.Ball
	endMarker.Size = Vector3.new(2, 2, 2)
	endMarker.Color = Color3.fromRGB(220, 60, 60)
	endMarker.Material = Enum.Material.Neon
	endMarker.Anchored = true
	endMarker.CanCollide = false
	endMarker.CanQuery = false
	endMarker.CanTouch = false
	endMarker.Position = EndPosition
	endMarker.Parent = container

	-- Connecting segments — thin cyan rods from prev to next
	local function makeSegment(from:Vector3, to:Vector3, name:string)
		local delta = to - from
		local length = delta.Magnitude
		if length < 0.01 then return end
		local segment = Instance.new("Part")
		segment.Name = name
		segment.Size = Vector3.new(0.25, 0.25, length)
		segment.Color = Color3.fromRGB(80, 200, 240)
		segment.Material = Enum.Material.Neon
		segment.Transparency = 0.3
		segment.Anchored = true
		segment.CanCollide = false
		segment.CanQuery = false
		segment.CanTouch = false
		segment.CFrame = CFrame.lookAt(from + delta * 0.5, to)
		segment.Parent = container
	end

	makeSegment(StartPosition, route[1].Position, "Seg_StartToNode1")
	for i = 1, #route - 1 do
		makeSegment(route[i].Position, route[i + 1].Position, `Seg_{i}To{i+1}`)
	end

	return container
end
--
return Path