-- ServerScriptService/systems/profile.luau
-- META profile persistence: the player's Tix balance + lifetime/best stats (bestWave, bestLevel,
-- bestTime, totalKills, runs) + the owned-pet COLLECTION + chosen SQUAD. NOT in-run stats — those
-- are ephemeral (playerState.reset wipes them every run).
--
-- Backed by the imported Framework ProfileStore wrapper (Shared.Framework.Data), NOT raw
-- DataStoreService: it owns the session LOCK (no two-server clobber), reconciles missing keys to the
-- Template, runs migrations, and provides retry-with-backoff saves + a forced leave-save. Load is
-- BLOCKING (StartSessionAsync), so `profiles[plr]` is the authoritative, ready data table the moment
-- load() returns — and because it IS the persisted table, mutating self fields auto-persists.
--
-- Template/Settings live in Shared/Framework/Data (key "BulletHeaven", schema V1). Field names here
-- match the live game state, so callers (M.get(plr).tix / .pets / .squad …) are unchanged.
-- Studio note: real persistence needs "Game Settings → Security → Enable Studio Access to API
-- Services" ON; otherwise the load fails gracefully → in-memory defaults, never saved.
--!strict

local Players              = game:GetService("Players")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local ServerScriptService  = game:GetService("ServerScriptService")

local blink       = require(ServerScriptService.ServerNet)
local PlayerState = require(ReplicatedStorage.std.playerState)
local Registry    = require(ReplicatedStorage.std.petRegistry) -- pet prices for the Tix shop
local Config      = require(ReplicatedStorage.std.config)
local Progress    = require(script.Parent.progression) -- to push the loaded collection to the client
local Data        = require(ReplicatedStorage.Framework.Data) -- ProfileStore wrapper

local AUTOSAVE = 60

type Profile = {
    tix: number, bestWave: number, bestLevel: number,
    bestTime: number, totalKills: number, runs: number,
    pets: { [string]: boolean }, -- owned pet COLLECTION (pet tab); starts with the 3 starters
    squad: { string },           -- the chosen run squad (ordered, slot1 = main), picked at the menu
}
local STARTERS = { "axolotl", "fox", "slime" } -- granted to every profile (covers a wiped/new save)

local function freshDefaults(): Profile
    return { tix = 0, bestWave = 0, bestLevel = 1, bestTime = 0, totalKills = 0, runs = 0,
        pets = { axolotl = true, fox = true, slime = true }, squad = { "axolotl" } }
end

local profiles: { [Player]: Profile } = {}
local canSave:  { [Player]: boolean } = {} -- only true when a ProfileStore session is actually held

local M = {}

function M.get(plr: Player): Profile?
    return profiles[plr]
end

local function sendProfile(plr: Player)
    local p = profiles[plr]
    if not p then return end
    blink.Profile.Fire(plr, {
        tix = math.floor(p.tix), bestWave = p.bestWave, bestLevel = p.bestLevel,
        bestTime = math.floor(p.bestTime), totalKills = p.totalKills, runs = p.runs,
    })
end

-- ── load / save ─────────────────────────────────────────────────────────────────
local function load(plr: Player)
    -- Blocking session load via ProfileStore (lock + reconcile + migrate). pcall-guarded so a
    -- failure (API access off / DataStore down) degrades to in-memory defaults instead of erroring.
    local data: any = nil
    local ok = pcall(function() data = Data.AttemptLoadData(plr) end)
    local held = ok and type(data) == "table"
    if not held then data = freshDefaults() end

    -- nested tables can be absent on a brand-new save before Reconcile fills them — guard + seed
    if type(data.pets) ~= "table" then data.pets = { axolotl = true, fox = true, slime = true } end
    if type(data.squad) ~= "table" or #data.squad == 0 then data.squad = { "axolotl" } end
    for _, id in STARTERS do data.pets[id] = true end -- always own the starters
    if Config.Debug.UNLOCK_ALL then -- Studio: own the whole roster (playtest any pet, no grind)
        for _, id in Registry.order do data.pets[id] = true end
    end

    profiles[plr] = data
    canSave[plr] = held

    -- seed the live state: balance + owned COLLECTION + chosen squad, then push to the client. The
    -- collection ref is SHARED, so drop/shop unlocks write straight into the persisted profile table.
    local s = PlayerState.get(plr)
    s.tix = data.tix
    s.owned = data.pets
    PlayerState.setSquad(plr, data.squad) -- validate (owned/cap) + build the run loadout
    blink.TixCount.Fire(plr, math.floor(data.tix))
    sendProfile(plr)
    Progress.pushLoadout(plr) -- send the collection (Unlocked) + squad (Weapons/Main)
end

-- snapshot the live squad into the persisted table (pets share a ref, so they're already current),
-- then persist via the wrapper's retry-with-backoff. No-op without a held session.
local function save(plr: Player)
    if not canSave[plr] then return end
    local p = profiles[plr]
    if p then p.squad = PlayerState.get(plr).squad end
    Data.SaveProfileWithRetry(plr)
end

-- ── mutations (route all tix + stat changes here) ─────────────────────────────────
function M.addTix(plr: Player, amount: number): number
    local p = profiles[plr]
    local total
    if p then
        p.tix += amount -- mutating the persisted table → auto-saved by ProfileStore
        total = p.tix
    else
        total = PlayerState.addTix(plr, amount) -- profile not loaded yet (rare)
    end
    PlayerState.get(plr).tix = total -- keep the in-run mirror in sync
    blink.TixCount.Fire(plr, math.floor(total))
    return total
end

function M.addKills(plr: Player, n: number)
    local p = profiles[plr]
    if p then p.totalKills += n end
end

-- Tix shop (menu): buy a locked pet. Validates balance, deducts (persisted), unlocks the collection.
blink.BuyPet.On(function(plr, petId)
    if PlayerState.get(plr).playing then return end -- shop is menu-only
    local pet = Registry.pets[petId]
    if not pet then return end
    local s = PlayerState.get(plr)
    if s.owned[petId] then return end -- already owned
    local price = pet.price or 0
    if price <= 0 or s.tix < price then return end -- not for sale / can't afford
    M.addTix(plr, -price) -- deduct (updates profile + mirror + fires TixCount)
    PlayerState.ownPet(plr, petId) -- s.owned shares the persisted p.pets ref
    Progress.pushLoadout(plr) -- resend Unlocked (the pet tab refreshes)
    blink.Toast.Fire(plr, "Unlocked " .. pet.name .. "!")
end)

function M.recordRun(plr: Player, wave: number, level: number, time: number)
    local p = profiles[plr]
    if not p then return end
    p.runs += 1
    p.bestWave = math.max(p.bestWave, wave)
    p.bestLevel = math.max(p.bestLevel, level)
    p.bestTime = math.max(p.bestTime, time)
    sendProfile(plr)
    task.spawn(save, plr) -- persist the run result promptly (own thread; Save yields)
end

-- ── lifecycle ─────────────────────────────────────────────────────────────────────
Players.PlayerAdded:Connect(function(plr) task.spawn(load, plr) end)
for _, plr in Players:GetPlayers() do task.spawn(load, plr) end

Players.PlayerRemoving:Connect(function(plr)
    if canSave[plr] then
        profiles[plr].squad = PlayerState.get(plr).squad -- final squad snapshot
        Data.EndProfileSession(plr) -- forces a final save + releases the lock for instant rejoin
    end
    profiles[plr] = nil
    canSave[plr] = nil
end)

task.spawn(function()
    while true do
        task.wait(AUTOSAVE)
        for _, plr in Players:GetPlayers() do save(plr) end
    end
end)

game:BindToClose(function()
    for _, plr in Players:GetPlayers() do
        if canSave[plr] then task.spawn(Data.EndProfileSession, plr) end
    end
    task.wait(2) -- give the writes a moment to flush
end)

return M
