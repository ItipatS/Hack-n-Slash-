-- ServerScriptService/systems/exp.luau
-- EXP orbs — PER-PLAYER (instanced). Every kill drops a separate orb FOR EACH player in the run;
-- an orb is OWNED by one player, only sent to + collectible by them (with their magnet), and only
-- merges with that player's other orbs. So co-op loot is never a race — everyone gets full XP from
-- every kill. Tiers: 1 green(1) → 2 blue(5) → 3 orange(25) → 4 purple(125). Exposes M.drop().
--!optimize 2
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players             = game:GetService("Players")

local blink = require(ServerScriptService.ServerNet)
local std   = ReplicatedStorage.std

local scheduler   = require(std.scheduler)
local phases      = require(std.phases)
local SpatialHash = require(std.spatialhash)
local Progress    = require(script.Parent.progression)
local PlayerState = require(std.playerState)

-- ── Tunables ──────────────────────────────────────────────────────────────────
local PICKUP_RADIUS = 7
local MERGE_RADIUS  = 4
local MERGE_R2      = MERGE_RADIUS * MERGE_RADIUS
local MERGE_COUNT   = 5
local MAX_TIER      = 4
local HASH_CELL     = 8
local EXP_TICK      = 1 / 10
local TIER_VALUE    = { 1, 5, 25, 125 }
local BIG_TIER      = 5 -- boss orb: special gold visual, never merges (tier > MAX_TIER)

-- ── State ─────────────────────────────────────────────────────────────────────
type Orb = { id: number, owner: Player, x: number, y: number, z: number, tier: number, value: number }
local orbs: { [number]: Orb } = {}
local nextOrbId = 0

local hash = SpatialHash.new(HASH_CELL)
local out: { number } = {}

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace:FindFirstChild("Map") or workspace } -- no Map (pivot prototype place) → raycast everything
groundParams.IgnoreWater = true
local function groundY(x: number, z: number): number?
    local hit = workspace:Raycast(Vector3.new(x, 1024, z), Vector3.new(0, -4096, 0), groundParams)
    return hit and hit.Position.Y or nil
end

-- players actively in the arena — each gets their own copy of every drop. Gate on `playing`
-- (NOT dead/Character): excludes menu/lobby + ghost players, while an alive player who is briefly
-- character-less (respawn frame, streaming) still counts so they never lose a drop.
local function recipients(): { Player }
    local r = {}
    for _, plr in Players:GetPlayers() do
        if PlayerState.get(plr).playing then r[#r + 1] = plr end
    end
    return r
end

-- ── Batched net out (spawns are PER-OWNER; removes broadcast — clients ignore unknown ids) ──
local spawnBatches: { [Player]: { blink.ExpSpawn } } = {}
local removeBatch: { number } = {}
local function emitSpawn(o: Orb)
    local b = spawnBatches[o.owner]
    if not b then b = {}; spawnBatches[o.owner] = b end
    b[#b + 1] = { id = o.id, pos = Vector3.new(o.x, o.y, o.z), tier = o.tier }
end
local function emitRemove(id: number)
    removeBatch[#removeBatch + 1] = id
end
local function flush()
    for owner, b in spawnBatches do
        if #b > 0 and owner.Parent then blink.SpawnExp.Fire(owner, b) end
    end
    table.clear(spawnBatches)
    if #removeBatch > 0 then blink.RemoveExp.FireAll(removeBatch); table.clear(removeBatch) end
end

-- ── Public: drop `count` tier-1 orbs around (x,z) FOR EACH player ────────────────
local M = {}
function M.drop(x: number, z: number, count: number)
    local rs = recipients()
    if #rs == 0 then return end
    for _, plr in rs do
        for _ = 1, count do
            nextOrbId += 1
            local ox = x + (math.random() * 3 - 1.5)
            local oz = z + (math.random() * 3 - 1.5)
            local oy = (groundY(ox, oz) or 0) + 1
            local o: Orb = { id = nextOrbId, owner = plr, x = ox, y = oy, z = oz, tier = 1, value = TIER_VALUE[1] }
            orbs[nextOrbId] = o
            emitSpawn(o)
        end
    end
    flush()
end

-- one BIG orb (boss reward) per player. Gold visual (BIG_TIER), no merge.
function M.dropBig(x: number, z: number, value: number)
    for _, plr in recipients() do
        nextOrbId += 1
        local oy = (groundY(x, z) or 0) + 1.5
        local o: Orb = { id = nextOrbId, owner = plr, x = x, y = oy, z = z, tier = BIG_TIER, value = value }
        orbs[nextOrbId] = o
        emitSpawn(o)
    end
    flush()
end

-- ── Pickup + merge tick ──────────────────────────────────────────────────────────
local function rebuildHash()
    hash:beginFrame()
    for id, o in orbs do
        hash:insert(id, o.x, o.y, o.z)
    end
end

local function pickupStep()
    rebuildHash()
    local xpByPlayer: { [Player]: number } = {}
    for _, plr in Players:GetPlayers() do
        if not PlayerState.get(plr).playing then continue end -- only an in-arena body collects
        local char = plr.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then continue end
        local rp = (root :: BasePart).Position
        local st = PlayerState.get(plr)
        local pr = st.pickupRange * st.itemPickup -- card magnet × item magnet (Milk/Magnet)
        local pickupR2 = (PICKUP_RADIUS * pr) * (PICKUP_RADIUS * pr)
        local cnt = hash:queryInto(rp.X, rp.Y, rp.Z, out)
        for j = 1, cnt do
            local id = out[j]
            local o = orbs[id]
            if o and o.owner == plr then -- only collect MY OWN orbs
                local dx, dz = o.x - rp.X, o.z - rp.Z
                if dx * dx + dz * dz <= pickupR2 then
                    xpByPlayer[plr] = (xpByPlayer[plr] or 0) + (o.value or TIER_VALUE[o.tier] or 1)
                    orbs[id] = nil
                    emitRemove(id)
                end
            end
        end
    end
    for plr, xp in xpByPlayer do
        local mult = PlayerState.get(plr).expMult -- EXP-gain multiplier (Fortune cards)
        Progress.addXp(plr, math.floor(xp * mult + 0.5))
    end
end

local group: { number } = {}
local function mergeStep()
    rebuildHash() -- fresh after pickup removed some
    local consumed: { [number]: boolean } = {}
    type Grp = { ids: { number }, tier: number, owner: Player }
    local groups: { Grp } = {}

    -- PHASE 1: find merge groups (same OWNER + same tier) WITHOUT mutating `orbs`
    for id, o in orbs do
        if consumed[id] or o.tier >= MAX_TIER then continue end
        local cnt = hash:queryInto(o.x, o.y, o.z, out)
        table.clear(group)
        group[1] = id
        for j = 1, cnt do
            if #group >= MERGE_COUNT then break end
            local cid = out[j]
            local c = orbs[cid]
            if c and cid ~= id and not consumed[cid] and c.tier == o.tier and c.owner == o.owner then
                local dx, dz = c.x - o.x, c.z - o.z
                if dx * dx + dz * dz <= MERGE_R2 then
                    group[#group + 1] = cid
                end
            end
        end
        if #group >= MERGE_COUNT then
            local ids = table.clone(group)
            for _, gid in ids do consumed[gid] = true end
            groups[#groups + 1] = { ids = ids, tier = o.tier, owner = o.owner }
        end
    end

    -- PHASE 2: apply
    for _, grp in groups do
        local cx, cy, cz, sumv, n = 0, 0, 0, 0, #grp.ids
        for _, gid in grp.ids do
            local g = orbs[gid]
            if g then
                cx += g.x; cy += g.y; cz += g.z; sumv += g.value
                orbs[gid] = nil
                emitRemove(gid)
            end
        end
        nextOrbId += 1
        local no: Orb = { id = nextOrbId, owner = grp.owner, x = cx / n, y = cy / n, z = cz / n, tier = grp.tier + 1, value = sumv }
        orbs[no.id] = no
        emitSpawn(no)
    end
end

-- wipe all orbs (called on a run restart)
function M.clearAll()
    local ids = {}
    for id in orbs do ids[#ids + 1] = id end
    for _, id in ids do orbs[id] = nil end
    if #ids > 0 then blink.RemoveExp.FireAll(ids) end
end

-- drop a leaving player's orbs (no one else can collect them)
local function clearOwner(plr: Player)
    local ids = {}
    for id, o in orbs do if o.owner == plr then ids[#ids + 1] = id end end
    for _, id in ids do orbs[id] = nil end
    if #ids > 0 then blink.RemoveExp.FireAll(ids) end
end
Players.PlayerRemoving:Connect(clearOwner)

local acc = 0
local function expWrapper(dt: number)
    acc += dt
    if acc < EXP_TICK then return end
    acc = 0
    pickupStep()
    mergeStep()
    flush()
end

-- replay a joining player's OWN orbs (they have none yet, but keeps the contract symmetric)
local function sendOrbsTo(player: Player)
    local batch: { blink.ExpSpawn } = {}
    for _id, o in orbs do
        if o.owner == player then
            batch[#batch + 1] = { id = o.id, pos = Vector3.new(o.x, o.y, o.z), tier = o.tier }
        end
    end
    if #batch > 0 then blink.SpawnExp.Fire(player, batch) end
end

scheduler.SYSTEM(expWrapper, phases.Inventory)
scheduler.SYSTEM(sendOrbsTo, phases.PlayerAdded)
for _, p in Players:GetPlayers() do sendOrbsTo(p) end

return M
