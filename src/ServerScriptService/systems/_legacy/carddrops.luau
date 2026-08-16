-- ServerScriptService/systems/carddrops.luau
-- CARD PACK pickups — dropped by slain BOSSES and ELITES. PER-PLAYER (instanced, like EXP/Tix): a
-- separate pack is created FOR EACH player in the run (owner-tagged, only sent to + collectible by
-- them), so co-op loot is never a race — everyone gets to choose. A pack is a floating world model
-- (Assets.Card); walk over it (spatial-hash proximity) → an upgrade offer of 3-5 cards. drop + clearAll.
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
local PlayerState = require(std.playerState)
local Progress    = require(script.Parent.progression)

-- ── Tunables ──────────────────────────────────────────────────────────────────
local PICKUP_RADIUS = 7
local PICKUP_R2     = PICKUP_RADIUS * PICKUP_RADIUS
local HASH_CELL     = 8
local DROP_TICK     = 1 / 10
local FLOAT_Y       = 3    -- centre height above the floor (client floats it further)
local PACK_MIN      = 3    -- a pack offers 3-5 cards
local PACK_MAX      = 5

-- ── State ─────────────────────────────────────────────────────────────────────
type Drop = { id: number, owner: Player, x: number, y: number, z: number }
local drops: { [number]: Drop } = {}
local nextId = 0

local hash = SpatialHash.new(HASH_CELL)
local out: { number } = {}

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace:FindFirstChild("Map") or workspace } -- no Map (pivot prototype place) → raycast everything
groundParams.IgnoreWater = true
local function groundY(x: number, z: number): number
    local hit = workspace:Raycast(Vector3.new(x, 1024, z), Vector3.new(0, -4096, 0), groundParams)
    return (hit and hit.Position.Y or 0) + FLOAT_Y
end

-- players actively in the arena — each gets their OWN copy of every drop (gate on `playing`, so
-- menu/lobby + ghost players are excluded; a briefly character-less alive player still counts).
local function recipients(): { Player }
    local r = {}
    for _, plr in Players:GetPlayers() do
        if PlayerState.get(plr).playing then r[#r + 1] = plr end
    end
    return r
end

-- ── Net out (PER-OWNER: only the owner sees + can collect their pack) ──────────────
local function emitSpawn(d: Drop)
    if d.owner.Parent then blink.CardDropSpawn.Fire(d.owner, { { id = d.id, pos = Vector3.new(d.x, d.y, d.z) } }) end
end

-- ── Public: a boss/elite died at (x,z) → drop a card pack FOR EACH player ───────────
local M = {}
function M.drop(x: number, z: number)
    local y = groundY(x, z)
    for _, plr in recipients() do
        nextId += 1
        local d: Drop = { id = nextId, owner = plr, x = x, y = y, z = z }
        drops[nextId] = d
        emitSpawn(d)
    end
end

-- ── Pickup tick (proximity) ───────────────────────────────────────────────────────
local removeBatch: { number } = {}
local function pickupStep()
    if next(drops) == nil then return end
    hash:beginFrame()
    for id, d in drops do hash:insert(id, d.x, d.y, d.z) end

    for _, plr in Players:GetPlayers() do
        local state = PlayerState.get(plr)
        if not state.playing then continue end
        local char = plr.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then continue end
        local rp = (root :: BasePart).Position
        local cnt = hash:queryInto(rp.X, rp.Y, rp.Z, out)
        for j = 1, cnt do
            local id = out[j]
            local d = drops[id]
            if d and d.owner == plr then -- only collect MY OWN pack
                local dx, dz = d.x - rp.X, d.z - rp.Z
                if dx * dx + dz * dz <= PICKUP_R2 then
                    drops[id] = nil
                    removeBatch[#removeBatch + 1] = id
                    blink.Toast.Fire(plr, "Card pack — choose an upgrade!")
                    Progress.queueOffer(plr, math.random(PACK_MIN, PACK_MAX))
                end
            end
        end
    end
    if #removeBatch > 0 then blink.CardDropRemove.FireAll(removeBatch); table.clear(removeBatch) end
end

-- wipe all card packs (called on a run restart / round end)
function M.clearAll()
    local ids = {}
    for id in drops do ids[#ids + 1] = id end
    for _, id in ids do drops[id] = nil end
    if #ids > 0 then blink.CardDropRemove.FireAll(ids) end
end

-- drop a leaving player's packs (no one else can collect them)
local function clearOwner(plr: Player)
    local ids = {}
    for id, d in drops do if d.owner == plr then ids[#ids + 1] = id end end
    for _, id in ids do drops[id] = nil end
    if #ids > 0 then blink.CardDropRemove.FireAll(ids) end
end
Players.PlayerRemoving:Connect(clearOwner)

local acc = 0
local function wrapper(dt: number)
    acc += dt
    if acc < DROP_TICK then return end
    acc = 0
    pickupStep()
end

-- replay a joining player's OWN packs
local function sendTo(player: Player)
    local batch: { blink.CardDrop } = {}
    for _id, d in drops do
        if d.owner == player then batch[#batch + 1] = { id = d.id, pos = Vector3.new(d.x, d.y, d.z) } end
    end
    if #batch > 0 then blink.CardDropSpawn.Fire(player, batch) end
end

scheduler.SYSTEM(wrapper, phases.Inventory)
scheduler.SYSTEM(sendTo, phases.PlayerAdded)
for _, p in Players:GetPlayers() do sendTo(p) end

return M
