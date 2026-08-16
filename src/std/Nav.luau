-- std/Nav.luau
-- The active pathfinding graph, resolved ONCE at boot. main.server.luau calls Nav.init() BEFORE
-- start(systems), so the (yielding) navmesh bake finishes before ANY system loads — the horde reads a
-- ready graph instead of racing the bake. USE_NAVMESH on → bake from workspace.Map; off → the
-- hand-painted PathData. Same { Waypoints, Neighbours } contract either way.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local std      = ReplicatedStorage.std
local Config   = require(std.config)
local pathData = require(std.PathData)

local Nav = {}

Nav.Waypoints = (nil :: any) :: { [number]: { any } }
Nav.Neighbours = (nil :: any) :: { [number]: { number } }
Nav.ready = false

-- Resolve the graph. Idempotent. When USE_NAVMESH is on this BAKES (yields) — call it from the
-- server bootstrap before start(systems) so the graph exists before a single mob does.
function Nav.init()
    if Nav.ready then return end

    if Config.Debug.USE_NAVMESH then
        print("[Nav] USE_NAVMESH=true → baking navmesh from workspace.Map …")
        Workspace:WaitForChild("Map") -- the bake reads it; make sure it's present
        local NavBake = require(std.NavBake)
        local t0 = os.clock()
        local navmesh = NavBake.connect(NavBake.bake({
            bakeRegion = NavBake.regionFromMap(),
            gridSpacing = Config.Nav.SPACING, -- master perf knob: node count ≈ area / spacing²
        }), {
            maxStepHeight = Config.Nav.MAX_STEP,  -- tallest two-way step (grid/bridge); above = one-way drop
            maxDropHeight = Config.Nav.MAX_DROP,  -- how far a mob may FALL in one one-way drop edge
            dropRadius    = Config.Nav.DROP_RADIUS, -- how far outward the drop search walks to its landing
        })
        Nav.Waypoints, Nav.Neighbours = NavBake.toGraph(navmesh)
        print(("[Nav] navmesh BAKED in %.2fs"):format(os.clock() - t0))
        if Config.Debug.NAV_DEBUG_SHOW then
            require(std.NavDebug).Show(navmesh)
        elseif Config.Debug.NAV_DEBUG_COMPONENTS then
            require(std.NavDebug).ShowComponents(navmesh) -- green = main surface; other colours = islands
        elseif Config.Debug.NAV_DEBUG_LINKS then
            require(std.NavDebug).ShowLinks(navmesh) -- arrows for one-way drop edges
        end
    else
        print("[Nav] USE_NAVMESH=false → using hand-painted PathData")
        Nav.Waypoints, Nav.Neighbours = pathData[1], pathData[2]
    end

    -- PROVE what the horde will actually flow over: node count, Y span, and (the bug that bit us)
    -- how many nodes have ZERO usable edges. If most nodes are isolated the flow field can't route and
    -- mobs beeline — so this line is the first thing to read when "mobs ignore the navmesh".
    local count, edges, isolated, minY, maxY = 0, 0, 0, math.huge, -math.huge
    for id, wp in Nav.Waypoints do
        count += 1
        local y = (wp[1] :: Vector3).Y
        if y < minY then minY = y end
        if y > maxY then maxY = y end
        local deg = 0
        local nb = Nav.Neighbours[id]
        if nb then for _, ok in nb do if ok == true then deg += 1 end end end
        edges += deg
        if deg == 0 then isolated += 1 end
    end
    print(("[Nav] ACTIVE GRAPH: %d nodes | %d directed edges | %d ISOLATED | Y[%.1f..%.1f]")
        :format(count, edges, isolated, count > 0 and minY or 0, count > 0 and maxY or 0))

    Nav.ready = true
end

return Nav
