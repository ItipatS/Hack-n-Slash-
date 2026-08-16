-- ServerScriptService/systems/horde.luau
-- Server-authoritative HORDE batch (replaces mob_brain + mob_move). One tight data-oriented
-- loop, NO per-mob raycasts/LOS:
--   • steer  — flow-field next-hop toward the nearest player; beeline once at the player's node
--   • spread — spatial-hash SEPARATION so the horde fans out instead of stacking. Authoritative,
--     so the server positions ARE the spread blob → bubble hitboxes match what the client sees.
--   • Y      — interpolated ALONG the current graph edge (F→T node heights). This keeps mobs on
--     the walkable surface (they climb ramps / take drops via the path) so they never sink under
--     overhangs, and per-mob edge progress avoids a flat floating plane on slopes. No raycast.
-- Positions are streamed DENSE: i8 slot-ordered deltas (UpdateTransformDelta, no per-mob id) +
-- a periodic absolute f32 snapshot (UpdateTransformFull) to clear drift. See std/config.luau Net.
--!optimize 2
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local blink = require(ServerScriptService.ServerNet)
local std   = ReplicatedStorage.std

local world       = require(std.world)
local cts         = require(std.components)
local scheduler   = require(std.scheduler)
local phases      = require(std.phases)
local SpatialHash = require(std.spatialhash)
local PathFinder  = require(std.PathFinder)
local FlowField   = require(std.FlowField)
local Config      = require(std.config)
local PlayerState = require(std.playerState)
local Obstacles   = require(std.obstacles) -- ice walls: moves that would cross one are cancelled

local Transform = cts.Transform
local Speed     = cts.Speed
local Mob       = cts.Mob
local PathNode  = cts.PathNode
local Character  = cts.Character
local Player     = cts.Player
local Knock      = cts.Knock
local Slot       = cts.Slot
local SpeedMul   = cts.SpeedMul

-- ── Nav source: resolved ONCE at boot by std/Nav (baked BEFORE systems start when USE_NAVMESH is on,
-- else hand-painted PathData). Same { Waypoints, Neighbours } contract either way. Nav.init() ran in
-- main.server before us; the call here is a no-op safety for any other load path.
local Nav = require(std.Nav)
Nav.init()
local Waypoints = Nav.Waypoints
local Neighbours = Nav.Neighbours
-- the corridor clamp below is a NAVMESH-only containment (its CORRIDOR scales with the dense grid
-- spacing). On the sparse hand-painted PathData it snaps mobs to the path → velocity jolts + instant
-- snap-down on one-way drops. So it only runs when USE_NAVMESH; PathData keeps its original free movement.
local USE_NAVMESH = Config.Debug.USE_NAVMESH

-- ── Tunables ──────────────────────────────────────────────────────────────────
local MOVE_TICK     = 1 / 20
local KNOCK_DECAY   = 6       -- knockback impulse decay rate
local SEP_RADIUS    = 3
local SEP_R2        = SEP_RADIUS * SEP_RADIUS
local SEP_GAIN      = 1.4     -- separation weight vs steer (lower → less side-shuffle, more charge)
local HASH_CELL     = 6       -- ≥ SEP_RADIUS
local ADVANCE_DIST2 = 36      -- advance to next node within 6 studs (XZ); wider so the lane offset
                              -- below never strands a mob just shy of a node it can't quite reach
local ADVANCE_FRAC  = 0.85    -- …OR once ≥85% ALONG the current edge (normalized progress). Node spacing-
                              -- independent, so sparse / far-apart nodes still hand off instead of a mob
                              -- orbiting one it can never get within ADVANCE_DIST2 of (the spin stall)
local LANE_GAIN     = 0.12    -- per-mob perpendicular bias (small): a touch of spread without the
                              -- swirl/spin — vampire-survivors mobs CHARGE the player, not orbit
local CORNER_CUT    = 0.3     -- blend the aim toward the node AFTER next → arc through turns
local CONTACT       = 2
local CONTACT2      = CONTACT * CONTACT
local CORRIDOR      = Config.Nav.SPACING * 3 -- max XZ drift from the path edge before we clamp a mob
local CORRIDOR2     = CORRIDOR * CORRIDOR     -- back onto the navmesh (stops off-map floating in a crowd)

-- streaming (dense-slot + i8 deltas — constants shared with the client via std/config.luau Net)
local Net        = Config.Net
local NET_TICK   = Net.NET_TICK
local FULL_EVERY = Net.FULL_EVERY
local CHUNK      = Net.CHUNK
local STEP       = Net.STEP
local INV_STEP   = 1 / Net.STEP
local WARP       = Net.WARP_THRESH

-- ── Nav ─────────────────────────────────────────────────────────────────────────
local pathfinder = PathFinder.fromWaypoints(Waypoints, Neighbours)

-- DOUBLE-BUFFERED flow field. A full flood over the dense navmesh done in one call BLOCKS the whole
-- frame (~100ms on 100k+ nodes). Instead we flood an INACTIVE field across several ticks in bounded
-- chunks and atomically swap it in when complete — mobs always read `field` (the last COMPLETE flood),
-- never a half-built one. FLOOD_BUDGET = heap pops per move tick (caps the per-tick flood cost).
local field         = FlowField.new(Waypoints, Neighbours) -- active (complete) — mobs read this
local buildingField = FlowField.new(Waypoints, Neighbours) -- inactive — the flood progresses into this
local flooding      = false
local FLOOD_BUDGET  = 8000
-- MMO-style flood radius (Config.Nav.FLOOD_RADIUS): 0 = unbounded (flood the whole arena), else only
-- path precisely within this many studs of a player; farther mobs beeline until they enter the disk.
local FLOOD_RADIUS  = if Config.Nav.FLOOD_RADIUS > 0 then Config.Nav.FLOOD_RADIUS else math.huge

-- live flow debug: render ONLY the routes mobs are using (red = stuck/unreachable). See std/NavDebug.
local NavDebug      = if Config.Debug.NAV_DEBUG_FLOW then require(std.NavDebug) else nil
local FLOW_DBG_TICK = 0.7
local flowDbgAcc    = FLOW_DBG_TICK -- render on the first move tick
local flowOccupied: { [number]: boolean } = {}

local zombies    = world:query(Transform, Speed, PathNode):with(Mob):cached()
local characters = world:query(Character, Player):cached()

local hash = SpatialHash.new(HASH_CELL)
local out: { number } = {}
local posCache: { [number]: Vector3 } = {}

local pPos: { Vector3 } = {}
local sources: { number } = {}

local function gatherPlayers()
    table.clear(pPos)
    table.clear(sources)
    for _e, char, plr in characters do
        if not PlayerState.get(plr).playing then continue end -- ignore parked lobby / ghost bodies
        local root = (char :: Model).PrimaryPart
        if not root then continue end
        local node = pathfinder:GetNearestWaypoint(root.Position)
        if node then
            pPos[#pPos + 1] = root.Position
            sources[#sources + 1] = node
        end
    end
end

-- ── Movement ──────────────────────────────────────────────────────────────────
-- Progress the background flood a BOUNDED amount, then swap a fresh field in when complete. Spends a
-- few ms/tick instead of blocking the whole frame on a full flood; mobs read the last complete `field`
-- the whole time (see the double-buffer note above). No throttle — the cost is capped by FLOOD_BUDGET.
local function driveFlood()
    if not flooding then
        buildingField:beginFlood(sources, FLOOD_RADIUS) -- snapshot sources; bound the flood (or not)
        flooding = true
    end
    if buildingField:floodStep(FLOOD_BUDGET) then
        field, buildingField = buildingField, field -- atomic swap: the just-finished flood goes live
        flooding = false
    end
end

local function moveStep(dt: number)
    gatherPlayers()
    if #pPos == 0 then return end
    debug.profilebegin("nav.flood") -- shows in the SERVER microprofiler track — this is the flow flood
    driveFlood()
    debug.profileend()

    Obstacles.sweep(workspace:GetServerTimeNow()) -- expire finished ice walls
    local hasWalls = Obstacles.any()

    -- snapshot positions into the hash + a cache (so separation reads neighbours cheaply)
    hash:beginFrame()
    table.clear(posCache)
    for e, transform in zombies do
        local p = transform.new.Position
        posCache[e] = p
        hash:insert(e, p.X, p.Y, p.Z)
    end

    for e, transform, speed, node in zombies do
        local pos = posCache[e]

        -- status effects fold into a single derived multiplier (std/statuses owns it). Movement just
        -- multiplies — it never knows what a "slow" is. Absent SpeedMul = normal speed.
        local mvSpeed = speed
        local mul = world:get(e, SpeedMul)
        if mul then mvSpeed = speed * mul end

        -- nearest player (XZ)
        local bx, bz, bestD2 = pos.X, pos.Z, math.huge
        for _, pp in pPos do
            local dx, dz = pp.X - pos.X, pp.Z - pos.Z
            local d2 = dx * dx + dz * dz
            if d2 < bestD2 then bestD2 = d2; bx = pp.X; bz = pp.Z end
        end

        local F = Waypoints[node][1] :: Vector3
        local nextHop = field:next(node)
        local T: Vector3? = if nextHop then Waypoints[nextHop][1] :: Vector3 else nil

        -- steer toward the next path node, or beeline to the player on the final approach. The lane
        -- fan-out (below) is applied ONLY mid-path (`fanOut`): once the NEXT node is the player's own
        -- cell (hop2 == nil) we head straight at the player, so the clump closes in instead of the
        -- perpendicular nudge orbiting them around the node (the "stuck, circling" swarm).
        local steerX, steerZ = 0, 0
        local fanOut = false
        if T then
            local hop2 = field:next(nextHop :: number) -- T non-nil ⇒ nextHop non-nil; nil ⇒ next IS the player's cell
            if hop2 then
                -- mid-path: corner-cutting look-ahead toward the node AFTER next, so the crowd arcs
                -- through a turn instead of all pivoting on T. Fan-out is on here.
                local T2 = Waypoints[hop2][1] :: Vector3
                local aimX = T.X + (T2.X - T.X) * CORNER_CUT
                local aimZ = T.Z + (T2.Z - T.Z) * CORNER_CUT
                steerX, steerZ = aimX - pos.X, aimZ - pos.Z
                fanOut = true
            else
                -- final approach (next node IS the player's cell): beeline straight at the player
                local dx, dz = bx - pos.X, bz - pos.Z
                if dx * dx + dz * dz > CONTACT2 then steerX, steerZ = dx, dz end
            end
        else
            local dx, dz = bx - pos.X, bz - pos.Z
            if dx * dx + dz * dz > CONTACT2 then steerX, steerZ = dx, dz end
        end
        local sm = math.sqrt(steerX * steerX + steerZ * steerZ)
        if sm > 1e-4 then steerX, steerZ = steerX / sm, steerZ / sm end

        -- separation (read neighbours from the snapshot)
        local sepX, sepZ = 0, 0
        local cnt = hash:queryInto(pos.X, pos.Y, pos.Z, out)
        for j = 1, cnt do
            local k = out[j]
            if k ~= e then
                local qp = posCache[k]
                if qp then
                    local dx, dz = pos.X - qp.X, pos.Z - qp.Z
                    local d2 = dx * dx + dz * dz
                    if d2 > 1e-4 and d2 < SEP_R2 then
                        local d = math.sqrt(d2)
                        local w = (SEP_RADIUS - d) / SEP_RADIUS
                        sepX += dx / d * w
                        sepZ += dz / d * w
                    end
                end
            end
        end

        -- per-mob lane bias: a stable perpendicular nudge (only while path-following, so the final
        -- beeline to the player stays direct) → the horde fans into a band instead of single-file,
        -- which looks less uniform and eases the chokepoint funneling.
        local laneX, laneZ = 0, 0
        if fanOut then -- mid-path only — never on the final approach (else they orbit the player)
            local lane = ((e % 21) / 10) - 1 -- stable ~[-1, 1] per mob
            laneX = -steerZ * lane * LANE_GAIN
            laneZ =  steerX * lane * LANE_GAIN
        end

        -- combine + integrate XZ
        local vx = steerX + laneX + sepX * SEP_GAIN
        local vz = steerZ + laneZ + sepZ * SEP_GAIN
        local vm = math.sqrt(vx * vx + vz * vz)
        local nx, nz = pos.X, pos.Z
        if vm > 1e-4 then
            nx = pos.X + (vx / vm) * mvSpeed * dt
            nz = pos.Z + (vz / vm) * mvSpeed * dt
        end

        -- knockback (impulse from a hit, decays) — applied on top of steering. Value-update
        -- only (never add/remove mid-query): decays to zero and stays (combat adds it).
        local k = world:get(e, Knock)
        if k and (k.X ~= 0 or k.Z ~= 0) then
            nx += k.X * dt
            nz += k.Z * dt
            local nk = k * math.exp(-KNOCK_DECAY * dt)
            if nk.X * nk.X + nk.Z * nk.Z < 1 then nk = Vector3.zero end
            world:set(e, Knock, nk)
        end

        -- ice walls (penguin Glacier Wall): a move that would CROSS a wall is cancelled — covers
        -- steering AND knockback in one check (both folded into nx/nz above). Mobs pile against
        -- the face; separation spreads them along it. (Flyers live in ufo.luau — walls don't apply.)
        if hasWalls and (nx ~= pos.X or nz ~= pos.Z) and Obstacles.blocked(pos.X, pos.Z, nx, nz) then
            nx, nz = pos.X, pos.Z
        end

        -- CONTAINMENT (navmesh only) — keep the mob within a corridor of its path edge. Steering +
        -- separation move XZ freely but Y is taken from the graph edge below; with a dense crowd (500+),
        -- separation can shove a mob off the walkable surface, where its XZ sails into the void while Y
        -- stays pinned to the edge → "standing in the air outside the map". Clamp XZ to within CORRIDOR of
        -- the F→T segment (or of F on the final approach). Along-path motion is free (projection); only
        -- off-path drift clamps. SKIPPED on sparse PathData (CORRIDOR too tight → snaps/jolts mobs).
        if USE_NAVMESH then
            local ax, az
            if T then
                local ex, ez = T.X - F.X, T.Z - F.Z
                local el2 = ex * ex + ez * ez
                local tt = if el2 > 1e-4 then math.clamp(((nx - F.X) * ex + (nz - F.Z) * ez) / el2, 0, 1) else 0
                ax, az = F.X + ex * tt, F.Z + ez * tt
            else
                ax, az = F.X, F.Z
            end
            local ox, oz = nx - ax, nz - az
            local od2 = ox * ox + oz * oz
            if od2 > CORRIDOR2 then
                local od = math.sqrt(od2)
                nx = ax + ox / od * CORRIDOR
                nz = az + oz / od * CORRIDOR
            end
        end

        -- Y from the graph edge F→T (on the walkable surface; per-mob progress conforms to the
        -- slope without floating). Stays on the path so mobs climb ramps / drop — never under map.
        local ny: number
        if T then
            local ex, ez = T.X - F.X, T.Z - F.Z
            local elen2 = ex * ex + ez * ez
            local p = if elen2 > 1e-4 then math.clamp(((nx - F.X) * ex + (nz - F.Z) * ez) / elen2, 0, 1) else 1
            ny = F.Y + (T.Y - F.Y) * p
            local tdx, tdz = nx - T.X, nz - T.Z
            -- advance when CLOSE to T (XZ) OR far enough ALONG the edge (progress p is normalized 0..1,
            -- so it fires regardless of how far apart the nodes are) → a mob can't orbit a node it never
            -- reaches within ADVANCE_DIST2 of.
            if tdx * tdx + tdz * tdz < ADVANCE_DIST2 or p >= ADVANCE_FRAC then
                world:set(e, PathNode, nextHop) -- advance (safe value-update)
            end
        else
            ny = F.Y
        end

        transform.new = CFrame.new(nx, ny, nz) -- same table ref → combat & streaming see it
    end

    -- live flow debug (throttled): render the subgraph mobs are actually on + print a routing summary
    -- to paste. reached/stuck PROVES whether mobs are pathing over the navmesh or just beelining.
    if NavDebug then
        flowDbgAcc += dt
        if flowDbgAcc >= FLOW_DBG_TICK then
            flowDbgAcc = 0
            table.clear(flowOccupied)
            local total, reached = 0, 0
            for _e, _t, _s, node in zombies do
                flowOccupied[node] = true
                total += 1
                if field:reached(node) then reached += 1 end
            end
            local srcStr = {}
            for i, s in sources do srcStr[i] = ("%d@%.0fY"):format(s, (Waypoints[s][1] :: Vector3).Y) end
            print(("[flow] mobs=%d reached=%d STUCK=%d | players=%d sources=[%s]")
                :format(total, reached, total - reached, #pPos, table.concat(srcStr, ",")))
            -- ShowFlow yields (task.wait) while spawning parts, but moveStep runs in the scheduler's
            -- non-yieldable system thread → must run on a fresh thread. It reads field/flowOccupied
            -- synchronously before its first yield, so there's no race with the next tick clearing them.
            task.spawn(NavDebug.ShowFlow, Waypoints, field, flowOccupied)
        end
    end
end

-- ── Streaming (dense-slot + i8 deltas) ───────────────────────────────────────────
-- The wire carries NO per-mob id: deltas are written in SLOT order (the client maps slot→entity
-- from the Spawn payload). Each axis is an i8 in STEP-sized fixed-point. `lastSent[slot]` is the
-- position the client has integrated from prior deltas — diffing against it accumulates motion
-- AND carries the quantization residual, so summed i8 deltas never drift.
local streamQuery = world:query(Transform, Slot):with(Mob):cached()

local lastSent:   { [number]: Vector3 } = {}
local slotOwner:  { [number]: number } = {} -- slot → entity in it now (to re-base a reused slot)
local scratchPos: { [number]: Vector3 } = {}
local scratchEnt: { [number]: number } = {}
local warpFull:  { { id: number, dp: Vector3 } } = {}
local fullBatch: { { id: number, dp: Vector3 } } = {}

local function sendDeltas()
    table.clear(scratchPos)
    table.clear(scratchEnt)
    table.clear(warpFull)

    local maxSlot = -1
    for e, transform, slot in streamQuery do
        scratchPos[slot] = transform.new.Position
        scratchEnt[slot] = e
        if slot > maxSlot then maxSlot = slot end
    end
    if maxSlot < 0 then return end

    for base = 0, maxSlot, CHUNK do
        local hi = math.min(base + CHUNK - 1, maxSlot)
        local deltas = table.create((hi - base + 1) * 3)
        local di = 0
        for slot = base, hi do
            local pos = scratchPos[slot]
            if pos then
                -- a recycled slot with a new occupant: re-base so we don't emit a bogus jump
                if slotOwner[slot] ~= scratchEnt[slot] then
                    slotOwner[slot] = scratchEnt[slot]
                    lastSent[slot] = pos
                end
                local last = lastSent[slot]
                local dx, dy, dz = pos.X - last.X, pos.Y - last.Y, pos.Z - last.Z
                if dx > WARP or dx < -WARP or dy > WARP or dy < -WARP or dz > WARP or dz < -WARP then
                    -- teleport/edge case i8 can't carry → send an absolute, zero the delta
                    warpFull[#warpFull + 1] = { id = scratchEnt[slot], dp = pos }
                    lastSent[slot] = pos
                    deltas[di + 1] = 0; deltas[di + 2] = 0; deltas[di + 3] = 0
                else
                    local qx = math.clamp(math.round(dx * INV_STEP), -127, 127)
                    local qy = math.clamp(math.round(dy * INV_STEP), -127, 127)
                    local qz = math.clamp(math.round(dz * INV_STEP), -127, 127)
                    deltas[di + 1] = qx; deltas[di + 2] = qy; deltas[di + 3] = qz
                    -- advance by the QUANTIZED amount so the sub-step residual carries forward
                    lastSent[slot] = Vector3.new(last.X + qx * STEP, last.Y + qy * STEP, last.Z + qz * STEP)
                end
            else
                deltas[di + 1] = 0; deltas[di + 2] = 0; deltas[di + 3] = 0 -- transient slot gap
            end
            di += 3
        end
        blink.UpdateTransformDelta.FireAll({ base = base, deltas = deltas })
    end

    if #warpFull > 0 then blink.UpdateTransformFull.FireAll(warpFull); table.clear(warpFull) end
end

-- periodic absolute snapshot (reliable) → clears accumulated drift + any slot-churn mismatch
local function sendFull()
    table.clear(fullBatch)
    for e, transform, slot in streamQuery do
        local pos = transform.new.Position
        lastSent[slot] = pos -- rebase so deltas resume from the corrected position
        slotOwner[slot] = e
        fullBatch[#fullBatch + 1] = { id = e, dp = pos }
        if #fullBatch >= 128 then blink.UpdateTransformFull.FireAll(fullBatch); table.clear(fullBatch) end
    end
    if #fullBatch > 0 then blink.UpdateTransformFull.FireAll(fullBatch); table.clear(fullBatch) end
end

-- ── Ticks ──────────────────────────────────────────────────────────────────────
local moveAcc, netAcc, fullAcc = 0, 0, 0

local function moveWrapper(dt: number)
    moveAcc += dt
    if moveAcc < MOVE_TICK then return end
    local step = moveAcc
    moveAcc = 0
    moveStep(step)
end

local function netWrapper(dt: number)
    netAcc += dt
    fullAcc += dt
    if netAcc < NET_TICK then return end
    netAcc = 0
    sendDeltas()
    if fullAcc >= FULL_EVERY then
        fullAcc = 0
        sendFull()
    end
end

scheduler.SYSTEM(moveWrapper, phases.AIMovement)
scheduler.SYSTEM(netWrapper, phases.NetworkDelta)
return 0
