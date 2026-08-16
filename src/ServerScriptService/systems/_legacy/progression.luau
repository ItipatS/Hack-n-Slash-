-- ServerScriptService/systems/progression.luau
-- XP/leveling + the card picker. Cards drive the WEAPON system: level up a weapon in the run
-- loadout (a fixed behavioral upgrade), add a NEW weapon (registry pet not yet in the run), or a
-- rare player-stat sprinkle. exp.luau calls addXp on pickup (a 3-card level-up offer); a picked-up
-- boss/elite CARD PACK (carddrops.luau) calls queueOffer for a 2-4 card choice. Offers queue and
-- present one at a time. Exposes addXp + queueOffer + pushLoadout.
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players             = game:GetService("Players")

local blink       = require(ServerScriptService.ServerNet)
local std         = ReplicatedStorage.std
local PlayerState = require(std.playerState)
local Registry    = require(std.petRegistry)
local ItemReg     = require(std.itemRegistry)
local scheduler   = require(std.scheduler)
local phases      = require(std.phases)

local M = {}

type Card = { kind: number, title: string, desc: string, weapon: string, apply: () -> () }

-- card kind → client category tag (0 player stat, 2 weapon upgrade, 3 new weapon, 4 item). `weapon`
-- carries the registry id (pet id → 3D thumbnail, or item id → badge), "" for player-stat cards.
local KIND_STAT, KIND_WEAPON, KIND_NEW, KIND_ITEM = 0, 2, 3, 4

-- GLOBAL player-stat upgrades — now RARE filler (weapon levels are the main progression)
local GLOBAL = {
    { title = "Power",        desc = "+5% overall damage",  apply = function(s) s.damageMult += 0.05 end },
    { title = "Precision",    desc = "+5% crit chance",     apply = function(s) s.critChance += 0.05 end },
    { title = "Brutality",    desc = "+0.5 crit damage",    apply = function(s) s.critDamage += 0.5 end },
    { title = "Vitality",     desc = "+25 max HP (heals)",  apply = function(s) s.maxHp += 25; s.hp = math.min(s.maxHp, s.hp + 25) end },
    { title = "Regeneration", desc = "+0.25 HP/sec regen",  apply = function(s) s.hpRegen += 0.25 end },
    { title = "Magnetism",    desc = "+25% pickup range",   apply = function(s) s.pickupRange += 0.25 end },
    { title = "Fleet Foot",   desc = "+1 walk speed",       apply = function(s) s.walkSpeed += 1 end },
    { title = "Haste",        desc = "+8% firing speed",    apply = function(s) s.haste += 0.08 end },
    { title = "Fortune",      desc = "+10% EXP gain",       apply = function(s) s.expMult += 0.10 end },
    { title = "Greed",        desc = "+12% Tix drops",      apply = function(s) s.tixDropRate += 0.12 end },
}

local function xpCurve(level: number): number
    return 5 + (level - 1) * 4
end

local pending: { [Player]: { Card } } = {}   -- the cards currently offered (server keeps the apply fns)
local queue:   { [Player]: { { count: number, source: number } } } = {} -- queued offers (count + source)

local function sendStats(plr: Player)    blink.Stats.Fire(plr, PlayerState.statsMsg(plr)) end
local function sendSheet(plr: Player)    blink.StatSheet.Fire(plr, PlayerState.sheetMsg(plr)) end
local function sendItems(plr: Player)    blink.Items.Fire(plr, PlayerState.itemList(plr)) end
local function sendUnlocked(plr: Player) blink.Unlocked.Fire(plr, PlayerState.ownedIds(plr)) end
local function sendMain(plr: Player)     blink.MainWeapon.Fire(plr, PlayerState.get(plr).main) end
local function sendWeapons(plr: Player)
    local list = {}
    for _, w in PlayerState.get(plr).weapons do list[#list + 1] = { id = w.id, level = w.level } end
    blink.Weapons.Fire(plr, list) -- {id, level} — the pet billboard shows "Name Lv.X"
end

local function ownedSet(s: any): { [string]: boolean }
    local set = {}
    for _, w in s.weapons do set[w.id] = true end
    for id in s.bench do set[id] = true end
    return set
end

-- Build up to `count` distinct cards: weapon upgrades + NEW weapons (UNLOCKED pets only) + items,
-- with a rare player-stat sprinkle. Pets unlock via elite/boss drops + the Tix shop; cards only let
-- you bring an OWNED pet into THIS run (slots 2+).
local function rollCards(plr: Player, count: number): { Card }
    local s = PlayerState.get(plr)
    local cand: { Card } = {}

    -- 1) weapon level-ups (in the run loadout, not maxed)
    for i, w in s.weapons do
        if w.level < w.maxLevel then
            local idx, nm, lvl = i, w.name, w.level + 1
            local desc = Registry.nextDesc(w) or "Upgrade"
            cand[#cand + 1] = {
                kind = KIND_WEAPON, weapon = w.id,
                title = string.format("%s  Lv %d", nm, lvl), desc = desc,
                apply = function() PlayerState.levelUpWeapon(plr, idx) end,
            }
        end
    end

    -- 1b) NEW weapons — only pets you've UNLOCKED and don't already have in the run (in-run growth)
    if #s.weapons < PlayerState.MAX_WEAPONS then
        local inRun: { [string]: boolean } = {}
        for _, w in s.weapons do inRun[w.id] = true end
        for _, id in Registry.order do
            if s.owned[id] and not inRun[id] then
                local p = Registry.pets[id]
                local nm = (p and p.name) or id
                cand[#cand + 1] = {
                    kind = KIND_NEW, weapon = id, title = nm, desc = (p and p.blurb) or "A new weapon",
                    apply = function()
                        if PlayerState.addToRun(plr, id) then
                            sendWeapons(plr); sendMain(plr)
                            blink.Toast.Fire(plr, nm .. " joined your run!")
                        end
                    end,
                }
            end
        end
    end

    -- 2) ITEMS — gain a new passive item or level one you have (absolute per-level effects)
    for _, id in ItemReg.order do
        local lvl = s.items[id] or 0
        if lvl < ItemReg.maxLevel(id) then
            local it = ItemReg.items[id]
            local nm = it.name
            local title = if lvl == 0 then nm else string.format("%s  Lv %d", nm, lvl + 1)
            cand[#cand + 1] = {
                kind = KIND_ITEM, weapon = id, title = title, desc = ItemReg.desc(id, lvl + 1),
                apply = function() PlayerState.addItem(plr, id) end,
            }
        end
    end

    local function statCard(g: any): Card
        return { kind = KIND_STAT, weapon = "", title = g.title, desc = g.desc,
            apply = function() g.apply(PlayerState.get(plr)) end }
    end

    -- 4) stats: the FALLBACK when nothing else is left, else a single rare sprinkle
    if #cand == 0 then
        for _, g in GLOBAL do cand[#cand + 1] = statCard(g) end
    else
        cand[#cand + 1] = statCard(GLOBAL[math.random(1, #GLOBAL)])
    end

    -- pick up to `count` distinct
    local picks: { Card } = {}
    for _ = 1, count do
        if #cand == 0 then break end
        local idx = math.random(1, #cand)
        picks[#picks + 1] = cand[idx]
        table.remove(cand, idx)
    end
    return picks
end

-- offer source (matches Net Offer.source): drives the client label + (later) the rollable pool
local SRC_LEVELUP, SRC_PACK = 0, 1

-- enqueue an offer of `count` cards from `source` (0 = level-up, 1 = card pack)
local function enqueue(plr: Player, count: number, source: number)
    local q = queue[plr]
    if not q then q = {}; queue[plr] = q end
    q[#q + 1] = { count = count, source = source }
end

local function offerNext(plr: Player)
    if pending[plr] then return end
    local q = queue[plr]
    if not q or #q == 0 then return end
    local job = table.remove(q, 1) :: { count: number, source: number }
    local picks = rollCards(plr, job.count)
    if #picks == 0 then return end
    pending[plr] = picks
    local cards = {}
    for i, c in picks do
        cards[i] = { id = i, title = c.title, desc = c.desc, kind = c.kind, weapon = c.weapon }
    end
    blink.LevelUp.Fire(plr, { source = job.source, cards = cards })
end

function M.addXp(plr: Player, amount: number)
    local s = PlayerState.get(plr)
    s.xp += amount
    while s.xp >= s.xpNext do
        s.xp -= s.xpNext
        s.level += 1
        s.xpNext = xpCurve(s.level)
        enqueue(plr, 4, SRC_LEVELUP) -- a level-up offers 4 cards
    end
    offerNext(plr)
    sendStats(plr)
end

-- a picked-up boss/elite CARD PACK: offer a choice of `count` cards (3-5)
function M.queueOffer(plr: Player, count: number)
    enqueue(plr, math.clamp(count, 3, 5), SRC_PACK)
    offerNext(plr)
end

-- push the equipped + owned + main lists (e.g. after a boss-dropped pet unlock)
function M.pushLoadout(plr: Player)
    sendWeapons(plr)
    sendUnlocked(plr)
    sendMain(plr)
end

function M.resetPlayer(plr: Player)
    pending[plr] = nil
    queue[plr] = nil
    sendStats(plr)
    sendSheet(plr)
    sendItems(plr)
    sendWeapons(plr)
    sendUnlocked(plr)
    sendMain(plr)
end

blink.ChooseCard.On(function(plr, idx)
    local offered = pending[plr]
    if not offered then return end
    local c = offered[idx]
    if not c then return end
    c.apply()
    pending[plr] = nil
    sendWeapons(plr)
    sendUnlocked(plr)
    sendMain(plr) -- a new weapon may have shifted slots
    offerNext(plr)
    sendStats(plr)
    sendSheet(plr) -- the pick may have changed a derived stat (top-right panel)
    sendItems(plr) -- ...or granted/leveled an item
end)

-- The SQUAD is MENU-ONLY: locked once a run starts. SwitchWeapons sets the whole squad (ordered, ≤4,
-- main first); SetMain reorders an existing squad member to be the main. Both persist via profile save.
blink.SwitchWeapons.On(function(plr, ids)
    if PlayerState.get(plr).playing then return end -- squad locked during a run
    PlayerState.setSquad(plr, ids)
    sendWeapons(plr)
    sendMain(plr)
end)

blink.SetMain.On(function(plr, petId)
    if PlayerState.get(plr).playing then return end -- main locked during a run
    PlayerState.setMain(plr, petId)
    sendWeapons(plr)
    sendMain(plr)
end)
-- NOTE: the Tix shop's BuyPet handler lives in profile.luau (it owns the persisted Tix balance).

Players.PlayerRemoving:Connect(function(plr)
    pending[plr] = nil
    queue[plr] = nil
    PlayerState.remove(plr)
end)

local function onJoin(plr: Player)
    sendStats(plr)
    sendSheet(plr)
    sendItems(plr)
    sendWeapons(plr)
    sendUnlocked(plr)
    sendMain(plr)
end
scheduler.SYSTEM(onJoin, phases.PlayerAdded)
for _, p in Players:GetPlayers() do onJoin(p) end

return M
