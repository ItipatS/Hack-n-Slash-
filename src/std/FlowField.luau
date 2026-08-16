-- std/FlowField.luau
-- Multi-source "flow field" over the directed waypoint graph.
--
-- Once per tick we flood OUTWARD from the source nodes (the players' nearest
-- waypoints) across the REVERSED edges. Every node then knows:
--   • dist[node]  — cost of the cheapest LEGAL path from it to the nearest source
--   • flow[node]  — the neighbor to step to next along that path (nil at a source)
--
-- This replaces per-mob A*: one flood, then each mob is an O(1) `:next(node)`
-- lookup — the thing that scales to 10k. One-way edges (cliff drops) are honored
-- intrinsically: a zombie may step N->M only when Neighbors[N][M] == true, so the
-- flood relaxes dist[N] through M only across legal forward moves.
--
-- Graph shape (shared with PathFinder):
--   Waypoints[serial] = { Vector3 position, label, weight }
--   Neighbors[serial] = { [neighborSerial] = true | false }   -- false = blocked dir
--!optimize 2
--!native
--!strict

local FlowField = {}
FlowField.__index = FlowField

type Waypoints = { [number]: { any } }
type Neighbors = { [number]: { [number]: boolean } }

export type FlowField = typeof(setmetatable(
    {} :: {
        Waypoints: Waypoints,
        _radjNode: { [number]: { number } },
        _radjCost: { [number]: { number } },
        _dist: { [number]: number },
        _flow: { [number]: number },
        _ver: { [number]: number },
        _curVer: number,
        _heapNode: { number },
        _heapDist: { number },
        _heapN: number,
        _maxDist: number, -- flood radius (studs); math.huge = unbounded
    },
    FlowField
))

function FlowField.new(Waypoints: Waypoints, Neighbors: Neighbors): FlowField
    local self = setmetatable({}, FlowField) :: FlowField
    self.Waypoints = Waypoints

    -- Reverse adjacency with precomputed edge cost. For every legal forward move
    -- N->M (Neighbors[N][M] == true) store, under M, the pair (N, cost(N->M)).
    -- Reversed-graph Dijkstra from the sources then relaxes dist[N] via dist[M].
    local radjNode: { [number]: { number } } = {}
    local radjCost: { [number]: { number } } = {}
    for n, neigh in Neighbors do
        local wn = Waypoints[n]
        if not wn then continue end
        local pn = wn[1] :: Vector3
        for m, ok in neigh do
            if ok ~= true then continue end -- one-way wrong dir / blocked
            local wm = Waypoints[m]
            if not wm then continue end
            local cost = ((wm[1] :: Vector3) - pn).Magnitude
            local bn = radjNode[m]
            if not bn then
                bn = {}
                radjNode[m] = bn
                radjCost[m] = {}
            end
            local bc = radjCost[m]
            bn[#bn + 1] = n
            bc[#bc + 1] = cost
        end
    end
    self._radjNode = radjNode
    self._radjCost = radjCost

    -- Version-stamped dist/flow so we never clear ~1300 entries per tick: a value
    -- counts only if its _ver matches the current flood's version.
    self._dist = {}
    self._flow = {}
    self._ver = {}
    self._curVer = 0

    -- Binary min-heap (parallel arrays) with lazy decrease-key (skip stale pops).
    self._heapNode = {}
    self._heapDist = {}
    self._heapN = 0
    self._maxDist = math.huge
    return self
end

-- ── Binary min-heap helpers ───────────────────────────────────────────────────
local function heapPush(self: FlowField, node: number, dist: number)
    local hNode, hDist = self._heapNode, self._heapDist
    local i = self._heapN + 1
    self._heapN = i
    hNode[i] = node
    hDist[i] = dist
    while i > 1 do
        local p = i // 2
        if hDist[p] <= hDist[i] then break end
        hNode[p], hNode[i] = hNode[i], hNode[p]
        hDist[p], hDist[i] = hDist[i], hDist[p]
        i = p
    end
end

local function heapPop(self: FlowField): (number?, number?)
    local n = self._heapN
    if n == 0 then return nil, nil end
    local hNode, hDist = self._heapNode, self._heapDist
    local topNode, topDist = hNode[1], hDist[1]
    hNode[1], hDist[1] = hNode[n], hDist[n]
    hNode[n], hDist[n] = nil, nil
    n -= 1
    self._heapN = n
    local i = 1
    while true do
        local l = i * 2
        local r = l + 1
        local s = i
        if l <= n and hDist[l] < hDist[s] then s = l end
        if r <= n and hDist[r] < hDist[s] then s = r end
        if s == i then break end
        hNode[s], hNode[i] = hNode[i], hNode[s]
        hDist[s], hDist[i] = hDist[i], hDist[s]
        i = s
    end
    return topNode, topDist
end

-- ── Flood ─────────────────────────────────────────────────────────────────────
-- The flood is SPLIT into beginFlood (seed) + floodStep (bounded work) so a caller can spread a big
-- flood across frames instead of blocking for the whole thing in one tick. A full flood over a dense
-- (100k+ node) navmesh is ~tens of ms — done in one call it stalls the frame; done in budgeted chunks
-- it's a few ms/tick. Pair with double-buffering (flood an INACTIVE field, swap when done) so readers
-- never see a half-built field. :compute() below keeps the old one-shot behaviour for any caller.

-- Seed the sources and reset the heap for a NEW flood. Bumps the version so prior dist/flow go stale
-- (so :next/:reached only report once this flood actually reaches a node).
function FlowField.beginFlood(self: FlowField, sources: { number }, maxDist: number?)
    self._curVer += 1
    self._maxDist = maxDist or math.huge -- bound the flood to a radius (MMO-style) or flood everything
    local ver = self._curVer
    local dist, flow, vmap = self._dist, self._flow, self._ver
    self._heapN = 0
    for _, s in sources do
        if vmap[s] == ver and dist[s] == 0 then continue end -- already seeded this flood
        dist[s] = 0
        flow[s] = nil :: any -- a source IS the target cell — no next hop
        vmap[s] = ver
        heapPush(self, s, 0)
    end
end

-- Do up to `maxPops` heap pops of the in-progress flood. Returns true when the heap is drained (flood
-- COMPLETE). Resumable: all state lives on self, so call it across frames until it returns true.
function FlowField.floodStep(self: FlowField, maxPops: number): boolean
    local ver = self._curVer
    local maxDist = self._maxDist
    local dist, flow, vmap = self._dist, self._flow, self._ver
    local radjNode, radjCost = self._radjNode, self._radjCost
    local pops = 0
    while pops < maxPops do
        local m, md = heapPop(self)
        if not m then return true end -- heap empty → flood complete
        pops += 1
        if vmap[m] ~= ver or (md :: number) > dist[m] then continue end -- stale heap entry
        -- past the flood radius? the heap pops in increasing distance, so EVERY remaining node is also
        -- beyond it → stop the whole flood here (this is the MMO local-pathing early-out).
        if dist[m] > maxDist then self._heapN = 0; return true end
        local bn = radjNode[m]
        if not bn then continue end
        local bc = radjCost[m]
        local base = dist[m]
        for i = 1, #bn do
            local nNode = bn[i]
            local nd = base + bc[i]
            if vmap[nNode] ~= ver or nd < dist[nNode] then
                dist[nNode] = nd
                flow[nNode] = m -- from nNode, step to m toward the nearest player
                vmap[nNode] = ver
                heapPush(self, nNode, nd)
            end
        end
    end
    return false -- budget spent, flood not yet complete
end

-- One-shot full flood (blocks until complete). Kept for callers that don't need to amortize.
function FlowField.compute(self: FlowField, sources: { number })
    self:beginFlood(sources)
    while not self:floodStep(2 ^ 53) do end
end

-- Next hop from `node` toward the nearest player, or nil if `node` is a source
-- (already in a player's cell) OR unreachable. Disambiguate with :reached.
function FlowField.next(self: FlowField, node: number): number?
    if self._ver[node] == self._curVer then
        return self._flow[node]
    end
    return nil
end

-- True if `node` has any legal path to a player this tick.
function FlowField.reached(self: FlowField, node: number): boolean
    return self._ver[node] == self._curVer
end

function FlowField.distance(self: FlowField, node: number): number
    if self._ver[node] == self._curVer then
        return self._dist[node]
    end
    return math.huge
end

return FlowField
