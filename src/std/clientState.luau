-- std/clientState.luau
-- The client's SINGLE mirror of this player's server-pushed state. It is the ONE place that listens to
-- each player-data Blink event; HUD widgets subscribe to it instead of each calling blink.X.On.
--
-- Why: previously every HUD system independently did blink.Stats.On / blink.Weapons.On / … and kept its
-- own copy of hp/maxHp/main/etc. That forced every shared event to be ManySync (and forgetting it =
-- "updates one HUD in Studio, the other live" — the SingleSync drop bug, hit 3×). With one listener per
-- event here, no player-data event has >1 client listener, so that footgun is STRUCTURALLY impossible,
-- and each value lives in exactly one place. Same shape as the clientPlay / panels mini-stores.
--
-- API: `clientState.on<Event>(fn)` registers fn and fires it IMMEDIATELY with the cached value (if one
-- has arrived) so a late subscriber is never stale. fn receives the SAME message the Blink event carried.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local std   = ReplicatedStorage.std
local blink = require(std:WaitForChild("ClientNet"))

local M = {}

local subs: { [string]: { (any) -> () } } = {}
local last: { [string]: any } = {}

-- make an `on<X>` subscriber for a channel: register + fire now with the cached value (if any)
local function channel(name: string): (fn: (any) -> ()) -> ()
    return function(fn)
        local arr = subs[name]
        if not arr then arr = {}; subs[name] = arr end
        arr[#arr + 1] = fn
        local cached = last[name]
        if cached ~= nil then fn(cached) end
    end
end

-- one Blink listener per event feeds its channel: cache + fan out to every subscriber
local function feed(name: string, value: any)
    last[name] = value
    local arr = subs[name]
    if arr then for _, fn in arr do fn(value) end end
end

-- subscribe API (fn gets the same payload the matching Blink event carried)
M.onStats   = channel("stats")   -- StatsMsg     { level, xp, xpNext, hp, maxHp } (~6 Hz)
M.onSheet   = channel("sheet")   -- StatSheetMsg { maxHp, hpRegen, atk, walkSpeed, crit, … } (on change)
M.onItems   = channel("items")   -- { { id, level } }
M.onWeapons = channel("weapons") -- { string } run weapon ids (derived from the full payload below)
M.onWeaponsFull = channel("weaponsFull") -- { { id, level } } run weapons WITH levels (pet labels)
M.onMain    = channel("main")    -- u8 main slot
M.onProfile = channel("profile") -- ProfileMsg   { tix, bestWave, bestLevel, bestTime, totalKills, runs }
M.onTix     = channel("tix")     -- u32 current Tix balance
M.onOwned   = channel("owned")   -- { string } owned pet collection (Unlocked)

-- current cached value of a channel (nil if none yet) — for the rare synchronous read
function M.get(name: string): any
    return last[name]
end

-- THE listeners (one each). Every HUD reads downstream of these.
blink.Stats.On(function(s) feed("stats", s) end)
blink.StatSheet.On(function(s) feed("sheet", s) end)
blink.Items.On(function(l) feed("items", l) end)
blink.Weapons.On(function(list) -- wire carries {id, level}; most HUDs only want ids → derive both channels
    local ids = {}
    for i, w in list do ids[i] = w.id end
    feed("weapons", ids)
    feed("weaponsFull", list)
end)
blink.MainWeapon.On(function(slot) feed("main", slot) end)
blink.Profile.On(function(p) feed("profile", p) end)
blink.TixCount.On(function(n) feed("tix", n) end)
blink.Unlocked.On(function(ids) feed("owned", ids) end)

return M
