-- std/NavBake.luau
-- Navmesh BAKER — step 1: the sample pass. Replaces the hand-painted PathData *producer*: instead of
-- hand-placed nodes, scan the real walkable geometry under workspace.Map and emit a grid-indexed node
-- graph (positions only — edges are step 2).
--
-- Two-shape design: the rich `Navmesh` below carries normals + grid coords for edge-building and debug
-- visualization; `NavBake.toGraph(navmesh)` exports it to the EXISTING { Waypoints, Neighbours } contract
-- that FlowField / PathFinder / NodeGrid already consume — so adopting this is a clean swap of
-- std/PathData, no consumer changes. Standalone this step: no integration, no runtime queries, no
-- serialization, single XZ grid (no multi-floor).
--!strict

local Workspace = game:GetService("Workspace")

local NavBake = {}

local UP = Vector3.yAxis
local YIELD_EVERY = 256 -- cells processed between task.wait() yields (a big bake is millions of casts)

export type Region = { cframe: CFrame, size: Vector3 }

export type Node = {
    position: Vector3,
    normal: Vector3,
    gx: number,           -- integer grid-cell indices (0-based) — edge-building reads these
    gz: number,
    neighbours: { number }, -- filled in step 2; empty {} until then
}

export type Navmesh = {
    nodes: { [number]: Node },                        -- id (serial) -> node
    gridIndex: { [number]: { [number]: number } },    -- gx -> gz -> id (O(1) neighbour lookup)
    metadata: {
        region: Region,
        spacing: number,
        params: { maxSlope: number, entityRadius: number, entityHeight: number },
        nodeCount: number,
        bakeTime: number,
    },
}

export type BakeParams = {
    bakeRegion: Region,
    gridSpacing: number?,  -- stud spacing between samples (default 2)
    maxSlope: number?,     -- max surface angle from vertical, degrees (default 45)
    entityRadius: number?, -- clearance radius for the upward spherecast (default 2)
    entityHeight: number?, -- clearance height required above a node (default 5)
}

export type ConnectParams = {
    maxStepHeight: number?, -- max Y delta for a BIDIRECTIONAL step (default spacing+1)
    neighbourMode: number?, -- 4 or 8 grid-adjacency (default 4)
    linkRadius: number?,    -- studs: BRIDGE PASS reach to fuse surfaces split by an unbaked steep face
                            -- (the gap a steep slope leaves between two levels). Default 8.
    maxDropHeight: number?, -- studs a mob may FALL in one hop, as a ONE-WAY drop edge (default 24)
    dropRadius: number?,    -- studs: max horizontal reach of a drop to its landing node. Default spacing*1.5
}

-- Collect the COLLIDABLE BaseParts under workspace.Map. Non-collidable parts inside Map are
-- decoration and must not produce (or block) nodes, so they're filtered out of the cast set.
local function collectMapParts(): { BasePart }
    local parts: { BasePart } = {}
    local map = Workspace:FindFirstChild("Map")
    if not map then return parts end
    for _, d in map:GetDescendants() do
        if d:IsA("BasePart") and d.CanCollide then
            parts[#parts + 1] = d
        end
    end
    return parts
end

-- Bake the sample pass. Returns a Navmesh with positions only (nodes[id].neighbours == {}).
function NavBake.bake(params: BakeParams): Navmesh
    local t0 = os.clock()

    local region = params.bakeRegion
    local spacing = params.gridSpacing
    if not spacing or spacing <= 0 then spacing = 2 end
    local maxSlope = params.maxSlope or 45
    local entityRadius = params.entityRadius or 2
    local entityHeight = params.entityHeight or 5

    -- normal·up >= cos(maxSlope)  ⟺  surface angle from vertical <= maxSlope
    local cosMaxSlope = math.cos(math.rad(maxSlope))

    -- one filter for both casts: only the collidable Map geometry (Include). The upward clearance
    -- cast starts above the floor, so it never re-hits the surface we just stood on.
    local castParams = RaycastParams.new()
    castParams.FilterType = Enum.RaycastFilterType.Include
    castParams.FilterDescendantsInstances = collectMapParts()
    castParams.IgnoreWater = true

    local center = region.cframe.Position
    local half = region.size / 2
    local minX, maxX = center.X - half.X, center.X + half.X
    local minZ, maxZ = center.Z - half.Z, center.Z + half.Z
    local topY = center.Y + half.Y
    local rayLen = region.size.Y
    local down = Vector3.new(0, -rayLen, 0)
    local up = Vector3.new(0, entityHeight, 0)

    local nodes: { [number]: Node } = {}
    local gridIndex: { [number]: { [number]: number } } = {}
    local id = 0
    local processed = 0
    -- WHY a column makes no node — the levels-won't-connect diagnostic. High too-steep ⇒ ramps between
    -- levels are steeper than maxSlope so no bridge nodes bake on them ⇒ disconnected components.
    local cMiss, cSteep, cClear = 0, 0, 0

    local gx = 0
    local x = minX
    while x <= maxX + 1e-3 do
        local gz = 0
        local z = minZ
        while z <= maxZ + 1e-3 do
            -- 1) downward ray onto the walkable surface
            local hit = Workspace:Raycast(Vector3.new(x, topY, z), down, castParams)
            if not hit then
                cMiss += 1
            elseif hit.Normal:Dot(UP) < cosMaxSlope then
                cSteep += 1 -- surface steeper than maxSlope → treated as wall, no node (drops ramps!)
            else
                -- 2) upward clearance: would the entity's body fit standing here?
                local upOrigin = hit.Position + Vector3.new(0, entityRadius + 0.1, 0)
                local blocked = Workspace:Spherecast(upOrigin, entityRadius, up, castParams)
                if blocked then
                    cClear += 1
                else
                    id += 1
                    nodes[id] = { position = hit.Position, normal = hit.Normal, gx = gx, gz = gz, neighbours = {} }
                    local col = gridIndex[gx]
                    if not col then col = {}; gridIndex[gx] = col end
                    col[gz] = id
                end
            end

            processed += 1
            if processed % YIELD_EVERY == 0 then task.wait() end
            z += spacing
            gz += 1
        end
        x += spacing
        gx += 1
    end

    print(("[NavBake] bake spacing=%g maxSlope=%g: %d samples → %d nodes | rejected: miss=%d too-steep=%d no-clearance=%d")
        :format(spacing, maxSlope, processed, id, cMiss, cSteep, cClear))

    return {
        nodes = nodes,
        gridIndex = gridIndex,
        metadata = {
            region = region,
            spacing = spacing,
            params = { maxSlope = maxSlope, entityRadius = entityRadius, entityHeight = entityHeight },
            nodeCount = id,
            bakeTime = os.clock() - t0,
        },
    }
end

-- Step 2 — EDGES. Fill nodes[id].neighbours: connect grid-adjacent nodes an entity can actually walk
-- between (small step, no wall in the way). Bidirectional; each unordered pair tested once.
local OFFS4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local OFFS8 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

function NavBake.connect(navmesh: Navmesh, params: ConnectParams?): Navmesh
    local p = params or {}
    -- default to spacing+1 so RAMP neighbours connect: adjacent cells on a slope differ in Y by up to
    -- ~spacing*tan(slope); a flat `2` rejected ramp edges (the "wedge only links one side" bug).
    local maxStep = p.maxStepHeight or (navmesh.metadata.spacing + 1)
    local offs = if p.neighbourMode == 8 then OFFS8 else OFFS4
    local entityRadius = navmesh.metadata.params.entityRadius

    local castParams = RaycastParams.new()
    castParams.FilterType = Enum.RaycastFilterType.Include
    castParams.FilterDescendantsInstances = collectMapParts()
    castParams.IgnoreWater = true

    local nodes = navmesh.nodes
    local gridIndex = navmesh.gridIndex
    local processed = 0
    -- WHY grid-adjacent nodes don't link: step>maxStep (cliff/ledge) vs wall-blocked (spherecast).
    local cPairs, cStep, cWall, cEdge = 0, 0, 0, 0
    for id, node in nodes do
        for _, o in offs do
            local col = gridIndex[node.gx + o[1]]
            local nid = col and col[node.gz + o[2]]
            if nid and nid > id then -- each unordered pair once → add both directions
                cPairs += 1
                local other = nodes[nid]
                if math.abs(node.position.Y - other.position.Y) > maxStep then
                    cStep += 1 -- adjacent cells too far apart in Y to step between (cliff edge)
                else
                    -- horizontal body-clearance sweep between the two nodes at standing height
                    local from = node.position + Vector3.new(0, entityRadius + 0.1, 0)
                    local to = other.position + Vector3.new(0, entityRadius + 0.1, 0)
                    if Workspace:Spherecast(from, entityRadius, to - from, castParams) then
                        cWall += 1 -- a wall stands between the two nodes
                    else
                        table.insert(node.neighbours, nid)
                        table.insert(other.neighbours, id)
                        cEdge += 1
                    end
                end
            end
        end
        processed += 1
        if processed % YIELD_EVERY == 0 then task.wait() end
    end

    -- BRIDGE PASS — fuse surfaces split by a steep face. The ±1 grid links only WITHIN a contiguous
    -- surface; a too-steep slope between two levels bakes no nodes, leaving an XZ gap WIDER than one
    -- cell, so the two surfaces' edge nodes are never adjacent and each stays its own component (mobs on
    -- one can't path to a player on another — they just beeline). Fix (the spatial-hash idea): for
    -- BOUNDARY nodes (missing a grid neighbour ⇒ on a surface edge) scan a wider radius and link any
    -- node truly BESIDE it (XZ ≤ linkRadius) whose height step is small and with no wall between. Only
    -- edge nodes pay the wider scan, so it stays cheap. linkRadius bounds how big a gap we'll span.
    local linkRadius = p.linkRadius or 8
    local linkR2 = linkRadius * linkRadius
    local bridgeCells = math.max(2, math.ceil(linkRadius / navmesh.metadata.spacing))
    local cBridge = 0
    processed = 0
    for id, node in nodes do
        if #node.neighbours < #offs then -- only surface-edge nodes (not fully-linked interior) bridge
            local px, py, pz = node.position.X, node.position.Y, node.position.Z
            for dx = -bridgeCells, bridgeCells do
                local col = gridIndex[node.gx + dx]
                if col then
                    for dz = -bridgeCells, bridgeCells do
                        -- skip the central 3×3 the grid pass already covered
                        if dx < -1 or dx > 1 or dz < -1 or dz > 1 then
                            local nid = col[node.gz + dz]
                            if nid and nid ~= id then
                                local other = nodes[nid]
                                local op = other.position
                                local ddx, ddz = op.X - px, op.Z - pz
                                if ddx * ddx + ddz * ddz <= linkR2 and math.abs(op.Y - py) <= maxStep then
                                    local linked = false
                                    for _, x in node.neighbours do if x == nid then linked = true; break end end
                                    if not linked then
                                        local from = node.position + Vector3.new(0, entityRadius + 0.1, 0)
                                        local to = op + Vector3.new(0, entityRadius + 0.1, 0)
                                        if not Workspace:Spherecast(from, entityRadius, to - from, castParams) then
                                            table.insert(node.neighbours, nid)
                                            table.insert(other.neighbours, id)
                                            cBridge += 1
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        processed += 1
        if processed % YIELD_EVERY == 0 then task.wait() end
    end

    -- DROP PASS — one-way drops off a ledge EDGE, directional. For each surface-edge node (missing a grid
    -- neighbour) we take the OUTWARD direction (the sum of the grid dirs that have NO node = off the
    -- surface) and step outward, skipping the empty cells over the cliff face, until we reach the first
    -- surface node. If that node is LOWER (a real drop-off) we add a ONE-WAY edge to it — the mob walks
    -- off the edge and lands on whatever is below-and-outward. This fires along the WHOLE edge (not just
    -- corners), only at true edges (interior nodes have every neighbour, so slopes are never blanketed),
    -- and crosses the no-node cliff gap. If the first node outward is at the SAME level it's not a drop-off
    -- (the surface just continues / a bridge handles it); if higher it's a wall — either way, no drop.
    local maxDrop = p.maxDropHeight or 24
    local dropReach = p.dropRadius or (navmesh.metadata.spacing * 1.5)
    local spacing = navmesh.metadata.spacing
    local region = navmesh.metadata.region
    local minX = region.cframe.Position.X - region.size.X * 0.5
    local minZ = region.cframe.Position.Z - region.size.Z * 0.5
    local cDrop = 0
    processed = 0
    for id, node in nodes do
        if #node.neighbours < #offs then -- surface-edge nodes only
            -- outward = sum of the 4 grid dirs with NO node (the open, off-surface sides)
            local oxc, ozc = 0, 0
            for _, o in OFFS4 do
                local col = gridIndex[node.gx + o[1]]
                if not (col and col[node.gz + o[2]]) then
                    oxc += o[1]; ozc += o[2]
                end
            end
            if oxc ~= 0 or ozc ~= 0 then
                local mag = math.sqrt(oxc * oxc + ozc * ozc)
                local odx, odz = oxc / mag, ozc / mag
                local px, py, pz = node.position.X, node.position.Y, node.position.Z
                local dist = spacing
                while dist <= dropReach do
                    local gx = math.floor((px + odx * dist - minX) / spacing + 0.5)
                    local gz = math.floor((pz + odz * dist - minZ) / spacing + 0.5)
                    local col = gridIndex[gx]
                    local nid = col and col[gz]
                    if nid and nid ~= id then
                        local drop = py - nodes[nid].position.Y
                        if drop > maxStep and drop <= maxDrop then
                            local linked = false
                            for _, x in node.neighbours do if x == nid then linked = true; break end end
                            if not linked then
                                table.insert(node.neighbours, nid) -- ONE-WAY: high → low only
                                cDrop += 1
                            end
                        end
                        break -- first surface outward decides: lower ⇒ drop, same/higher ⇒ nothing
                    end
                    dist += spacing
                end
            end
        end
        processed += 1
        if processed % YIELD_EVERY == 0 then task.wait() end
    end

    print(("[NavBake] connect maxStep=%g linkRadius=%g maxDrop=%g dropReach=%g: %d grid + %d bridged + %d drops | grid rejected: step>maxStep=%d, wall=%d")
        :format(maxStep, linkRadius, maxDrop, dropReach, cEdge, cBridge, cDrop, cStep, cWall))

    -- CONNECTIVITY CHECK — the "is the mesh actually connected?" answer we were missing. Flood the
    -- components: 1 component = the whole surface is reachable (a mob anywhere can path to a player
    -- anywhere). Many components / a small largest% = surfaces still split → mobs on the others beeline.
    local seen: { [number]: boolean } = {}
    local comps, largest = 0, 0
    for sid in nodes do
        if not seen[sid] then
            comps += 1
            local stack = { sid }
            seen[sid] = true
            local sz = 0
            while #stack > 0 do
                local x = stack[#stack]; stack[#stack] = nil; sz += 1
                for _, nn in nodes[x].neighbours do
                    if not seen[nn] then seen[nn] = true; stack[#stack + 1] = nn end
                end
            end
            if sz > largest then largest = sz end
        end
    end
    local total = navmesh.metadata.nodeCount
    print(("[NavBake] CONNECTIVITY: %d component(s), largest=%d/%d (%.1f%% reachable as one surface)")
        :format(comps, largest, total, 100 * largest / math.max(1, total)))
    return navmesh
end

-- Axis-aligned bake region covering the collidable Map geometry (padded). Part AABB ignores rotation,
-- giving a generous region — exactly what a top-down ray sweep wants.
function NavBake.regionFromMap(): Region
    local map = Workspace:FindFirstChild("Map")
    local minV = Vector3.new(math.huge, math.huge, math.huge)
    local maxV = -minV
    if map then
        for _, d in map:GetDescendants() do
            if d:IsA("BasePart") and d.CanCollide then
                local lo, hi = d.Position - d.Size * 0.5, d.Position + d.Size * 0.5
                minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
                maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
            end
        end
    end
    if minV.X == math.huge then return { cframe = CFrame.new(), size = Vector3.zero } end
    minV -= Vector3.new(4, 2, 4)
    maxV += Vector3.new(4, 8, 4)
    return { cframe = CFrame.new((minV + maxV) * 0.5), size = maxV - minV }
end

-- Dev DIAGNOSTIC: explain why a named Map part bakes no nodes. Runs the bake's exact reject pipeline
-- (in-set? → downcast → slope → clearance) across the part's top footprint and prints the verdict per
-- stage, so a "this part won't bake" hunt names the real cause instead of guessing. Reusable forever.
-- e.g. NavBake.diagnose("Bugg1"). Defaults match NavBake.bake (maxSlope 45, radius 2, height 5).
function NavBake.diagnose(partName: string)
    local map = Workspace:FindFirstChild("Map")
    local found = map and map:FindFirstChild(partName, true)
    if not found or not found:IsA("BasePart") then
        print(`[NavDiag] {partName}: NOT FOUND under workspace.Map (or not a BasePart)`)
        return
    end
    local p = found :: BasePart
    print(("[NavDiag] %s: class=%s CanCollide=%s CanQuery=%s anchored=%s size=%s"):format(
        partName, p.ClassName, tostring(p.CanCollide), tostring(p.CanQuery), tostring(p.Anchored), tostring(p.Size)))

    -- the two engine-level reasons a part is invisible to the bake — check first, they're conclusive.
    if not p.CanCollide then
        print(`[NavDiag] {partName}: CanCollide=false → the baker treats it as DECORATION and never casts at it. Set CanCollide=true to bake it.`)
        return
    end
    if not p.CanQuery then
        print(`[NavDiag] {partName}: CanQuery=false → raycasts are BLIND to it (engine-level; no RaycastParams override exists). Set CanQuery=true so the bake's casts can hit it.`)
        return
    end

    -- replicate the bake's casts (default params) and sample the part's own XZ footprint
    local maxSlope, entityRadius, entityHeight = 45, 2, 5
    local cosMax = math.cos(math.rad(maxSlope))
    local castParams = RaycastParams.new()
    castParams.FilterType = Enum.RaycastFilterType.Include
    castParams.FilterDescendantsInstances = collectMapParts()
    castParams.IgnoreWater = true

    local half = p.Size * 0.5
    local reach = p.Size.Magnitude + 10
    local topY = p.Position.Y + reach
    local down = Vector3.new(0, -(reach * 2), 0)

    local total, miss, other, steep, blocked, ok = 0, 0, 0, 0, 0, 0
    local otherName, blockerName = "", ""
    local x = p.Position.X - half.X
    while x <= p.Position.X + half.X + 1e-3 do
        local z = p.Position.Z - half.Z
        while z <= p.Position.Z + half.Z + 1e-3 do
            total += 1
            local hit = Workspace:Raycast(Vector3.new(x, topY, z), down, castParams)
            if not hit then
                miss += 1
            elseif hit.Instance ~= p then
                other += 1; otherName = hit.Instance:GetFullName()
            elseif hit.Normal:Dot(UP) < cosMax then
                steep += 1
            else
                local upOrigin = hit.Position + Vector3.new(0, entityRadius + 0.1, 0)
                local b = Workspace:Spherecast(upOrigin, entityRadius, Vector3.new(0, entityHeight, 0), castParams)
                if b then blocked += 1; blockerName = b.Instance:GetFullName() else ok += 1 end
            end
            z += 2
        end
        x += 2
    end
    print(("[NavDiag] %s: %d footprint samples → NODES=%d | missed=%d | hit-other=%d (%s) | too-steep=%d | clearance-blocked=%d (%s)"):format(
        partName, total, ok, miss, other, otherName, steep, blocked, blockerName))
    if ok == 0 then
        print(`[NavDiag] {partName}: produces ZERO nodes — the largest reject column above is the cause.`)
    end
end

-- Export to the EXISTING pathfinding contract (std/PathData[1], [2]): FlowField.new / PathFinder.
-- fromWaypoints take exactly these. Run NavBake.connect first or Neighbours come out empty.
--   Waypoints[id]  = { Vector3 position, label, weight }
--   Neighbours[id] = { [adjacentId] = true }   -- a SET, not an array
-- CRITICAL: FlowField (`for m, ok in neigh do if ok ~= true then continue`) and PathFinder
-- (`for serial, canReach in pairs(Neighbors)`) both read neighbours as a SET keyed by neighbour id
-- with a boolean value, exactly like hand-painted PathData. node.neighbours is an ARRAY of ids, so we
-- MUST convert it — emitting the raw array gives every value as an id (never `true`) and the flow
-- field reads ZERO edges → every mob beelines (the "not actually using the navmesh" bug).
function NavBake.toGraph(navmesh: Navmesh): ({ [number]: { any } }, { [number]: { [number]: boolean } })
    local Waypoints: { [number]: { any } } = {}
    local Neighbours: { [number]: { [number]: boolean } } = {}
    for nodeId, node in navmesh.nodes do
        Waypoints[nodeId] = { node.position, "", 0 }
        local set: { [number]: boolean } = {}
        for _, nid in node.neighbours do set[nid] = true end
        Neighbours[nodeId] = set
    end
    return Waypoints, Neighbours
end

return NavBake
