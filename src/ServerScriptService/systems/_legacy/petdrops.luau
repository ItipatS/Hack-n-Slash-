-- ServerScriptService/systems/petdrops.luau
-- PET pickups — a way to gain a new pet. PER-PLAYER (instanced, like EXP/Tix): a slain boss drops a
-- pet FOR EACH player (owner-tagged, only theirs to see/collect), each picked from a pet THAT player
-- doesn't own yet (a meaningful unlock) — so co-op is never a race. Walk over it (spatial-hash) → the
-- pet unlocks + joins the run + a Toast. Exposes dropBoss + maybeDropElite + clearAll.
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
local Registry    = require(std.petRegistry)
local PlayerState = require(std.playerState)
local Progress    = require(script.Parent.progression)

-- ── Tunables ──────────────────────────────────────────────────────────────────
local PICKUP_RADIUS = 7
local PICKUP_R2     = PICKUP_RADIUS * PICKUP_RADIUS
local HASH_CELL     = 8
local DROP_TICK     = 1 / 10
local DUP_XP        = 40   -- consolation XP if you already own the dropped pet
local FLOAT_Y       = 3    -- centre height above the floor (client floats it further)

-- ── State ─────────────────────────────────────────────────────────────────────
type Drop = { id: number, owner: Player, x: number, y: number, z: number, pet: string }
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

-- ── Pet choice: prefer one THIS player doesn't own yet (a meaningful unlock) ─────────
local function pickPetFor(plr: Player): string
    local owned: { [string]: boolean } = {}
    for _, id in PlayerState.ownedIds(plr) do owned[id] = true end
    local fresh: { string } = {}
    for _, id in Registry.order do
        if not owned[id] then fresh[#fresh + 1] = id end
    end
    if #fresh > 0 then return fresh[math.random(1, #fresh)] end
    return Registry.order[math.random(1, #Registry.order)] -- they own everything → dup (consolation XP)
end

-- players actively in the arena — each gets their OWN pet drop (co-op is never a race).
local function recipients(): { Player }
    local r = {}
    for _, plr in Players:GetPlayers() do
        if PlayerState.get(plr).playing then r[#r + 1] = plr end
    end
    return r
end

-- ── Net out (PER-OWNER: only the owner sees + can collect their pet) ───────────────
local function emitSpawn(d: Drop)
    if d.owner.Parent then blink.PetDropSpawn.Fire(d.owner, { { id = d.id, pos = Vector3.new(d.x, d.y, d.z), pet = d.pet } }) end
end

-- ── Public ────────────────────────────────────────────────────────────────────────
local ELITE_PET_CHANCE = 0.2 -- an elite UNCOMMONLY drops a pet
local M = {}

-- a boss died at (x,z) → a pet pickup FOR EACH player, each prefers one THAT player doesn't own yet
function M.dropBoss(x: number, z: number)
    local y = groundY(x, z)
    for _, plr in recipients() do
        nextId += 1
        local d: Drop = { id = nextId, owner = plr, x = x, y = y, z = z, pet = pickPetFor(plr) }
        drops[nextId] = d
        emitSpawn(d)
    end
end

-- elite death: an uncommon chance to drop a pet
function M.maybeDropElite(x: number, z: number)
    if math.random() < ELITE_PET_CHANCE then M.dropBoss(x, z) end
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
            if d and d.owner == plr then -- only collect MY OWN pet drop
                local dx, dz = d.x - rp.X, d.z - rp.Z
                if dx * dx + dz * dz <= PICKUP_R2 then
                    drops[id] = nil
                    removeBatch[#removeBatch + 1] = id
                    local pet = Registry.pets[d.pet]
                    local name = (pet and pet.name) or d.pet
                    -- pickup UNLOCKS the pet in the collection (pet tab) AND adds it to the current run
                    local isNew = PlayerState.ownPet(plr, d.pet)
                    local added = PlayerState.addToRun(plr, d.pet)
                    if isNew then
                        blink.Toast.Fire(plr, "New pet: " .. name .. "!  ★ unlocked + joined")
                    elseif added then
                        blink.Toast.Fire(plr, name .. " joined your run!")
                    else
                        Progress.addXp(plr, DUP_XP) -- already in the run → consolation XP
                        blink.Toast.Fire(plr, name .. " — +" .. DUP_XP .. " XP")
                    end
                    if isNew or added then Progress.pushLoadout(plr) end
                end
            end
        end
    end
    if #removeBatch > 0 then blink.PetDropRemove.FireAll(removeBatch); table.clear(removeBatch) end
end

-- wipe all pet drops (called on a run restart)
function M.clearAll()
    local ids = {}
    for id in drops do ids[#ids + 1] = id end
    for _, id in ids do drops[id] = nil end
    if #ids > 0 then blink.PetDropRemove.FireAll(ids) end
end

-- drop a leaving player's pet pickups (no one else can collect them)
local function clearOwner(plr: Player)
    local ids = {}
    for id, d in drops do if d.owner == plr then ids[#ids + 1] = id end end
    for _, id in ids do drops[id] = nil end
    if #ids > 0 then blink.PetDropRemove.FireAll(ids) end
end
Players.PlayerRemoving:Connect(clearOwner)

local acc = 0
local function wrapper(dt: number)
    acc += dt
    if acc < DROP_TICK then return end
    acc = 0
    pickupStep()
end

-- replay a joining player's OWN drops
local function sendTo(player: Player)
    local batch: { blink.PetDrop } = {}
    for _id, d in drops do
        if d.owner == player then batch[#batch + 1] = { id = d.id, pos = Vector3.new(d.x, d.y, d.z), pet = d.pet } end
    end
    if #batch > 0 then blink.PetDropSpawn.Fire(player, batch) end
end

scheduler.SYSTEM(wrapper, phases.Inventory)
scheduler.SYSTEM(sendTo, phases.PlayerAdded)
for _, p in Players:GetPlayers() do sendTo(p) end

return M
