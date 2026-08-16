-- ServerScriptService/systems/tixdrops.luau
-- Tix currency pickups (META currency) — PER-PLAYER. A drop is created FOR EACH player in the run
-- (owner-tagged, only sent to + collectible by them). Walking over it banks the amount into that
-- player's persisted profile. The client picks the model from the amount (≤5 Tix, ≤20 PileofTix,
-- else StackofTix). Exposes drop(x,z,amount), maybeDrop(x,z), clearAll.
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
local Profile     = require(script.Parent.profile)

-- ── Tunables ──────────────────────────────────────────────────────────────────
local DROP_CHANCE   = 0.07  -- per normal-mob kill
local PICKUP_RADIUS = 7     -- base; ×player.pickupRange
local HASH_CELL     = 8
local DROP_TICK     = 1 / 10
local FLOAT_Y       = 2

-- ── State ─────────────────────────────────────────────────────────────────────
type Drop = { id: number, owner: Player, x: number, y: number, z: number, amount: number }
local drops: { [number]: Drop } = {}
local nextId = 0

local hash = SpatialHash.new(HASH_CELL)
local out: { number } = {}
local spawnBatches: { [Player]: { blink.TixDrop } } = {}
local removeBatch: { number } = {}

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace:FindFirstChild("Map") or workspace } -- no Map (pivot prototype place) → raycast everything
groundParams.IgnoreWater = true
local function groundY(x: number, z: number): number
    local hit = workspace:Raycast(Vector3.new(x, 1024, z), Vector3.new(0, -4096, 0), groundParams)
    return (hit and hit.Position.Y or 0) + FLOAT_Y
end

-- players actively in the arena — gate on `playing` (NOT dead/Character): excludes menu/lobby +
-- ghost players, while an alive player briefly character-less (respawn frame) still counts.
local function recipients(): { Player }
    local r = {}
    for _, plr in Players:GetPlayers() do
        if PlayerState.get(plr).playing then r[#r + 1] = plr end
    end
    return r
end

local function emitSpawn(d: Drop)
    local b = spawnBatches[d.owner]
    if not b then b = {}; spawnBatches[d.owner] = b end
    b[#b + 1] = { id = d.id, pos = Vector3.new(d.x, d.y, d.z), amount = d.amount }
end

-- ── Public ────────────────────────────────────────────────────────────────────
local M = {}
-- drop `amount` tix at (x,z) FOR EACH player (amount drives value + client model tier)
function M.drop(x: number, z: number, amount: number)
    if amount <= 0 then return end
    local y = groundY(x, z)
    for _, plr in recipients() do
        -- per-player Tix-drop rate (Greed cards) scales each player's own pile
        local amt = math.max(1, math.floor(amount * PlayerState.get(plr).tixDropRate + 0.5))
        nextId += 1
        local d: Drop = { id = nextId, owner = plr, x = x, y = y, z = z, amount = amt }
        drops[nextId] = d
        emitSpawn(d)
    end
end

function M.maybeDrop(x: number, z: number)
    if math.random() < DROP_CHANCE then M.drop(x, z, math.random(1, 5)) end
end

-- ── Pickup tick (only your OWN tix; banks into your profile) ───────────────────────
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
        local r = PICKUP_RADIUS * state.pickupRange * state.itemPickup
        local r2 = r * r
        local gained = 0
        local cnt = hash:queryInto(rp.X, rp.Y, rp.Z, out)
        for j = 1, cnt do
            local id = out[j]
            local d = drops[id]
            if d and d.owner == plr then
                local dx, dz = d.x - rp.X, d.z - rp.Z
                if dx * dx + dz * dz <= r2 then
                    drops[id] = nil
                    removeBatch[#removeBatch + 1] = id
                    gained += d.amount
                end
            end
        end
        if gained > 0 then
            Profile.addTix(plr, gained) -- updates profile + run mirror + fires TixCount
        end
    end
    if #removeBatch > 0 then blink.TixRemove.FireAll(removeBatch); table.clear(removeBatch) end
end

function M.clearAll()
    local ids = {}
    for id in drops do ids[#ids + 1] = id end
    for _, id in ids do drops[id] = nil end
    if #ids > 0 then blink.TixRemove.FireAll(ids) end
end

local function clearOwner(plr: Player)
    local ids = {}
    for id, d in drops do if d.owner == plr then ids[#ids + 1] = id end end
    for _, id in ids do drops[id] = nil end
    if #ids > 0 then blink.TixRemove.FireAll(ids) end
end
Players.PlayerRemoving:Connect(clearOwner)

local acc = 0
local function wrapper(dt: number)
    acc += dt
    if acc < DROP_TICK then return end
    acc = 0
    for owner, b in spawnBatches do
        if #b > 0 and owner.Parent then blink.TixSpawn.Fire(owner, b) end
    end
    table.clear(spawnBatches)
    pickupStep()
end

-- replay a joining player's OWN drops + their balance
local function sendTo(player: Player)
    local batch: { blink.TixDrop } = {}
    for _id, d in drops do
        if d.owner == player then batch[#batch + 1] = { id = d.id, pos = Vector3.new(d.x, d.y, d.z), amount = d.amount } end
    end
    if #batch > 0 then blink.TixSpawn.Fire(player, batch) end
    blink.TixCount.Fire(player, PlayerState.get(player).tix)
end

scheduler.SYSTEM(wrapper, phases.Inventory)
scheduler.SYSTEM(sendTo, phases.PlayerAdded)
for _, p in Players:GetPlayers() do sendTo(p) end

return M
