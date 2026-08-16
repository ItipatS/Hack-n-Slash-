-- std/NavDebug.luau
-- Dev-only navmesh VISUALIZER (step 1b). Renders a baked navmesh as parts in Studio so the bake can
-- be eyeballed before trusting it: a node on every walkable surface, none on decoration or in walls.
-- Standalone — NOT called by the baker; a test script decides whether to call it. Edges are step 2b.
--!strict

local Workspace = game:GetService("Workspace")

local NavBake = require(script.Parent.NavBake) -- for the Navmesh type (no runtime side effects)

local NavDebug = {}

local FOLDER_NAME = "NavmeshDebug"
local YIELD_EVERY = 1000   -- yield while spawning so it never hard-freezes
local PART_BUDGET = 1200   -- coarse overview cap; autoStride() keeps the render under this (10k parts
                           -- was way too heavy — this is a sanity sketch, not the full mesh).

-- Pick a grid stride so the render stays under PART_BUDGET regardless of arena size. stride N renders
-- ~1/N² of the nodes (only cells where gx%N==0 and gz%N==0), each tile N× bigger so coverage still reads.
function NavDebug.autoStride(navmesh: NavBake.Navmesh): number
    local n = navmesh.metadata.nodeCount
    if n <= PART_BUDGET then return 1 end
    return math.max(1, math.ceil(math.sqrt(n / PART_BUDGET)))
end

-- node colour by surface slope: green (flat) → yellow (steep, toward maxSlope).
local FLAT = Color3.fromRGB(70, 220, 90)
local STEEP = Color3.fromRGB(235, 215, 60)
local function slopeColor(normal: Vector3): Color3
    local dot = math.clamp(normal:Dot(Vector3.yAxis), -1, 1)
    local angle = math.deg(math.acos(dot)) -- 0 = flat
    return FLAT:Lerp(STEEP, math.clamp(angle / 45, 0, 1))
end

-- CONNECTIVITY colour — the wall/cliff diagnostic. A node missing neighbours sits against something
-- the bake refused to connect across (wall, cliff, region edge); an isolated node is a bake failure.
--   RED    = 0 neighbours (isolated — unreachable / bad sample)
--   ORANGE = fewer than full (BOUNDARY — wall / cliff / map edge runs here)
--   slope  = fully connected interior (green→yellow)
-- So walls & cliffs show as orange seams; if a seam is MISSING where a wall is, the bake isn't
-- detecting that wall. FULL_NBR matches connect's default 4-neighbour mode.
local FULL_NBR = 4
local ISOLATED = Color3.fromRGB(255, 45, 45)
local BOUNDARY = Color3.fromRGB(255, 160, 40)
local function connColor(node: NavBake.Node): Color3
    local n = #node.neighbours
    if n == 0 then return ISOLATED end
    if n < FULL_NBR then return BOUNDARY end
    return slopeColor(node.normal)
end

-- Render the navmesh as CUBE TILES on a grid (one Block per sampled cell), semi-transparent
-- SmoothPlastic, connectivity-coloured. Each tile is ORIENTED to the node's surface normal, so on
-- ramps/wedges it lies flush on the slope — the render matches the real Map 1:1.
-- COARSE by default: stride is auto-picked to keep the render under PART_BUDGET (a readable sketch,
-- not the full mesh — 10k tiles is too heavy). Pass stride=1 to force full density for a close look.
-- Replaces any prior render. Returns the folder.
function NavDebug.Show(navmesh: NavBake.Navmesh, stride: number?): Folder
    NavDebug.Clear()
    local st = if stride then math.max(1, math.floor(stride)) else NavDebug.autoStride(navmesh)
    local tile = navmesh.metadata.spacing * st

    local template = Instance.new("Part")
    template.Size = Vector3.new(tile, 0.2, tile) -- thin tile; its Y (thin axis) aligns to the surface normal
    template.Material = Enum.Material.SmoothPlastic
    template.Transparency = 0.5
    template.Anchored = true
    template.CanCollide = false
    template.CanQuery = false
    template.CanTouch = false
    template.CastShadow = false

    -- parent the folder up front so a concurrent Show/Clear can find & replace it (no duplicate folders)
    local folder = Instance.new("Folder")
    folder.Name = FOLDER_NAME
    folder.Parent = Workspace

    local i = 0
    for _, node in navmesh.nodes do
        if node.gx % st == 0 and node.gz % st == 0 then
            local part = template:Clone()
            -- align the tile's up-axis to the surface normal so it sits flush on slopes
            local n = node.normal
            local right = n:Cross(Vector3.zAxis)
            if right.Magnitude < 1e-4 then right = n:Cross(Vector3.xAxis) end
            part.CFrame = CFrame.fromMatrix(node.position, right.Unit, n)
            part.Color = connColor(node) -- wall/cliff seams = orange, isolated = red, interior = slope
            part.Parent = folder
            i += 1
            if i % YIELD_EVERY == 0 then task.wait() end
        end
    end
    template:Destroy()

    return folder
end

-- Draw a thin beam-part between each connected pair (step 2b), under the same NavmeshDebug folder so
-- Clear() cleans both. Each unordered edge once. Call after Show() (and after NavBake.connect).
function NavDebug.ShowEdges(navmesh: NavBake.Navmesh): Folder
    local folder = Workspace:FindFirstChild(FOLDER_NAME) :: Folder?
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = FOLDER_NAME
        folder.Parent = Workspace
    end
    local nodes = navmesh.nodes
    local i = 0
    for id, node in nodes do
        for _, nid in node.neighbours do
            if nid > id then -- each undirected edge once
                local a, b = node.position, nodes[nid].position
                local part = Instance.new("Part")
                part.Anchored = true
                part.CanCollide = false
                part.CanQuery = false
                part.CanTouch = false
                part.CastShadow = false
                part.Material = Enum.Material.SmoothPlastic -- plain, not Neon
                part.Color = Color3.fromRGB(80, 160, 255)
                part.Transparency = 0.6
                part.Size = Vector3.new(0.15, 0.15, (b - a).Magnitude)
                part.CFrame = CFrame.lookAt((a + b) * 0.5, b)
                part.Parent = folder
                i += 1
                if i % YIELD_EVERY == 0 then task.wait() end
            end
        end
    end
    return folder :: Folder
end

-- ── LIVE FLOW view ────────────────────────────────────────────────────────────────
-- Render ONLY what the horde is actually flowing over THIS tick — the path each mob is using, not
-- the whole baked mesh. For every occupied node we walk field:next(...) to the player's source,
-- collecting the route nodes + directed edges. The tiny subgraph (hundreds of parts, not 100k+)
-- makes the routing legible AND surfaces the bug: a mob node with NO flow (field:reached == false →
-- unreachable, the beeline/under-map case) is drawn RED so dead routes pop instantly.
--   RED   = mob node with no path to a player (STUCK — beelines, sinks under the map)
--   GREEN = mob node that IS on a connected route
--   BLUE  = downstream route node / edge toward the nearest player
local STUCK = Color3.fromRGB(255, 45, 45)
local ONMOB = Color3.fromRGB(70, 230, 110)
local ROUTE = Color3.fromRGB(70, 140, 255)
local FLOW_BUDGET = 4000 -- hard cap so a pathological fan-out can't spawn a runaway part count

function NavDebug.ShowFlow(Waypoints: { [number]: { any } }, field: any, occupied: { [number]: boolean }): Folder
    NavDebug.Clear()
    local folder = Instance.new("Folder")
    folder.Name = FOLDER_NAME
    folder.Parent = Workspace

    -- classify nodes (2 = stuck mob node, 1 = reachable mob node, 0 = downstream route) + collect edges
    local kind: { [number]: number } = {}
    local edges: { [number]: { [number]: boolean } } = {}
    for node in occupied do
        if not field:reached(node) then
            kind[node] = 2 -- unreachable from any player → the under-map symptom
        else
            if (kind[node] or 0) < 1 then kind[node] = 1 end
            local cur, hops = node, 0
            while hops < 512 do -- cap: a cycle/huge chain can't loop forever
                local nxt = field:next(cur)
                if not nxt then break end
                local s = edges[cur]; if not s then s = {}; edges[cur] = s end
                s[nxt] = true
                if kind[nxt] == nil then kind[nxt] = 0 end
                cur = nxt; hops += 1
            end
        end
    end

    local i = 0
    for node, k in kind do
        local wp = Waypoints[node]
        if wp then
            local part = Instance.new("Part")
            part.Anchored = true; part.CanCollide = false; part.CanQuery = false
            part.CanTouch = false; part.CastShadow = false
            part.Material = Enum.Material.Neon
            part.Shape = Enum.PartType.Ball
            part.Size = Vector3.new(2.2, 2.2, 2.2)
            part.Color = if k == 2 then STUCK elseif k == 1 then ONMOB else ROUTE
            part.Transparency = 0.2
            part.Position = wp[1] :: Vector3
            part.Parent = folder
            i += 1
            if i >= FLOW_BUDGET then return folder end
            if i % YIELD_EVERY == 0 then task.wait() end
        end
    end

    for a, s in edges do
        local pa = Waypoints[a][1] :: Vector3
        for b in s do
            local pb = Waypoints[b][1] :: Vector3
            local part = Instance.new("Part")
            part.Anchored = true; part.CanCollide = false; part.CanQuery = false
            part.CanTouch = false; part.CastShadow = false
            part.Material = Enum.Material.Neon
            part.Color = ROUTE
            part.Transparency = 0.4
            part.Size = Vector3.new(0.18, 0.18, (pb - pa).Magnitude)
            part.CFrame = CFrame.lookAt((pa + pb) * 0.5, pb)
            part.Parent = folder
            i += 1
            if i >= FLOW_BUDGET then return folder end
            if i % YIELD_EVERY == 0 then task.wait() end
        end
    end
    return folder
end

-- ── ONE-WAY edge view ─────────────────────────────────────────────────────────────
-- Render ONLY the ONE-WAY edges (drops + one-way jumps) as arrows — the "did my ledges actually get a
-- drop link?" check. An edge A→B is one-way when A lists B but B does NOT list A. ORANGE = a downward
-- link (drop / leap-down: A is well above B); CYAN = a level one-way. A ball marks the DESTINATION (where
-- the mob lands). Bidirectional grid/bridge edges aren't drawn (far too many). Runs at boot from Nav.init.
local DROP_COL = Color3.fromRGB(255, 150, 40)
local JUMP_COL = Color3.fromRGB(60, 210, 255)
function NavDebug.ShowLinks(navmesh: NavBake.Navmesh): Folder
    NavDebug.Clear()
    local folder = Instance.new("Folder")
    folder.Name = FOLDER_NAME
    folder.Parent = Workspace
    local nodes = navmesh.nodes
    local step = navmesh.metadata.spacing
    local function lists(a: number, b: number): boolean
        for _, x in nodes[a].neighbours do if x == b then return true end end
        return false
    end
    local i, oneway = 0, 0
    for id, node in nodes do
        for _, nid in node.neighbours do
            if not lists(nid, id) then -- one-way id → nid
                oneway += 1
                local a, b = node.position, nodes[nid].position
                local col = if (a.Y - b.Y) > step then DROP_COL else JUMP_COL
                local line = Instance.new("Part")
                line.Anchored = true; line.CanCollide = false; line.CanQuery = false
                line.CanTouch = false; line.CastShadow = false
                line.Material = Enum.Material.Neon; line.Color = col; line.Transparency = 0.2
                line.Size = Vector3.new(0.3, 0.3, (b - a).Magnitude)
                line.CFrame = CFrame.lookAt((a + b) * 0.5, b)
                line.Parent = folder
                local ball = Instance.new("Part")
                ball.Anchored = true; ball.CanCollide = false; ball.CanQuery = false
                ball.CanTouch = false; ball.CastShadow = false
                ball.Shape = Enum.PartType.Ball; ball.Material = Enum.Material.Neon
                ball.Color = col; ball.Transparency = 0.1; ball.Size = Vector3.new(1.6, 1.6, 1.6)
                ball.Position = b
                ball.Parent = folder
                i += 2
                if i % YIELD_EVERY == 0 then task.wait() end
            end
        end
    end
    print(("[NavDebug] ShowLinks: %d one-way edges (orange=drop, cyan=level)"):format(oneway))
    return folder
end

-- ── CONNECTED-COMPONENT view ────────────────────────────────────────────────────
-- The definitive "which planes are actually connected?" view. Colour every node by its connected
-- component: the LARGEST component (the main walkable surface mobs+player share) is GREEN; every other
-- component gets its own bright colour = an ISLAND that can't path to the main surface, so a mob on it
-- detours "over the map" or stalls. Edges are treated as UNDIRECTED (a one-way drop still groups the two
-- ends), so a colour boundary here means there is NO edge at all across that seam — exactly the bug.
function NavDebug.ShowComponents(navmesh: NavBake.Navmesh, stride: number?): Folder
    NavDebug.Clear()
    local nodes = navmesh.nodes

    -- union-find over undirected edges → a component root per node
    local parent: { [number]: number } = {}
    for id in nodes do parent[id] = id end
    local function find(a: number): number
        local r = a
        while parent[r] ~= r do r = parent[r] end
        while parent[a] ~= r do parent[a], a = r, parent[a] end
        return r
    end
    for id, node in nodes do
        for _, nn in node.neighbours do
            local ra, rb = find(id), find(nn)
            if ra ~= rb then parent[ra] = rb end
        end
    end
    local size: { [number]: number } = {}
    for id in nodes do local r = find(id); size[r] = (size[r] or 0) + 1 end
    local mainRoot, best, ncomp = -1, -1, 0
    for r, s in size do
        ncomp += 1
        if s > best then best = s; mainRoot = r end
    end
    local GREEN = Color3.fromRGB(70, 220, 90)

    local st = if stride then math.max(1, math.floor(stride)) else NavDebug.autoStride(navmesh)
    local tile = navmesh.metadata.spacing * st
    local template = Instance.new("Part")
    template.Size = Vector3.new(tile, 0.2, tile)
    template.Material = Enum.Material.SmoothPlastic
    template.Transparency = 0.4
    template.Anchored = true; template.CanCollide = false; template.CanQuery = false
    template.CanTouch = false; template.CastShadow = false

    local folder = Instance.new("Folder")
    folder.Name = FOLDER_NAME
    folder.Parent = Workspace
    local i = 0
    for id, node in nodes do
        if node.gx % st == 0 and node.gz % st == 0 then
            local part = template:Clone()
            local n = node.normal
            local right = n:Cross(Vector3.zAxis)
            if right.Magnitude < 1e-4 then right = n:Cross(Vector3.xAxis) end
            part.CFrame = CFrame.fromMatrix(node.position, right.Unit, n)
            local root = find(id)
            part.Color = if root == mainRoot then GREEN else Color3.fromHSV((root * 0.61803398875) % 1, 0.9, 1)
            part.Parent = folder
            i += 1
            if i % YIELD_EVERY == 0 then task.wait() end
        end
    end
    template:Destroy()
    print(("[NavDebug] ShowComponents: %d component(s), main=%d/%d nodes (GREEN). Any other colour = an ISLAND.")
        :format(ncomp, best, navmesh.metadata.nodeCount))
    return folder
end

-- Destroy EVERY debug folder (there can be more than one if two render paths fired).
function NavDebug.Clear()
    for _, c in Workspace:GetChildren() do
        if c.Name == FOLDER_NAME then c:Destroy() end
    end
end

return NavDebug
