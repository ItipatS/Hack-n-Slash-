-- std/playerBuffs.luau
-- The ONE explicit place player combat modifiers are resolved. Players are ECS entities (ref(UserId)
-- → the entity that holds Player/Character). Two layers, mirroring the mob status system:
--   • RAW timed buffs (`Buffs`, keyed by kind) — applied here, never world:set directly by gameplay.
--   • DERIVED modifier set (`PlayerMods`) — produced ONLY by tick(): it folds the player's PASSIVE stats
--     (gear defense from recomputeDefense + the offensive card-stats × item buffs) TOGETHER with the
--     active timed buffs into one struct.
-- Combat reads `PlayerMods` everywhere it used to read PlayerState modifiers inline — the damage loop
-- (damagePlayers) AND the firing path (fireStep / spawnBubble / SKILLS). ufo reads the defense fields.
-- Add a buff kind = one row in BUFF_KIND (no new branch).
--!optimize 2
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local std         = ReplicatedStorage.std
local world       = require(std.world)
local cts         = require(std.components)
local ref         = require(std.ref)
local PlayerState = require(std.playerState)

local Player    = cts.Player
local Buffs     = cts.Buffs
local PlayerMods = cts.PlayerMods

local ARMOR_CAP = 0.8
local HASTE_MIN = 0.1

-- Each buff kind names the PlayerMods field it touches + how it combines with the passive base.
-- "set" = boolean on, "add" = += mag, "mul" = *= mag. Add a buff → add a row (apply() accepts any kind).
local BUFF_KIND: { [string]: { field: string, op: string } } = {
    -- defense / movement
    invuln  = { field = "invuln",    op = "set" },
    armor   = { field = "armor",     op = "add" },
    reflect = { field = "reflect",   op = "add" },
    regen   = { field = "regen",     op = "add" },
    speed   = { field = "walkSpeed", op = "mul" },
    -- offense (firing path)
    damage  = { field = "damage",    op = "mul" },
    crit    = { field = "crit",      op = "add" },
    critdmg = { field = "critDmg",   op = "add" },
    atksize = { field = "atkSize",   op = "mul" },
    knock   = { field = "knock",     op = "mul" },
    haste   = { field = "haste",     op = "mul" },
    skillcd = { field = "skillCd",   op = "mul" },
    onhitslow = { field = "onHitSlow", op = "mul" }, -- <1 = your hits slow enemies (Frostbite / timed buffs)
}

local M = {}

-- Apply / refresh a timed buff on a player. Refresh-by-kind: a second buff of the same kind keeps the
-- LONGER expiry and the STRONGER magnitude (re-casting a shield extends it, never stacks unbounded).
-- Called from gameplay (e.g. turtle Shell Nova) instead of poking PlayerState. See BUFF_KIND for kinds.
function M.apply(plr: Player, kind: string, mag: number, untilT: number)
    local e = ref(plr.UserId)
    local buffs = world:get(e, Buffs)
    if not buffs then
        buffs = {}
        world:set(e, Buffs, buffs)
    end
    local existing = buffs[kind]
    if existing then
        existing.untilT = math.max(existing.untilT, untilT)
        existing.mag = math.max(existing.mag, mag)
    else
        buffs[kind] = { mag = mag, untilT = untilT }
    end
end

-- ── Per-tick resolve ──────────────────────────────────────────────────────────
-- Writes PlayerMods for EVERY player entity (passive stats are always present, even with no buffs).
-- jecs: can't add/remove a component on an entity mid-iteration of a query → collect, apply after.
-- Pruning expired entries inside the `Buffs` table is plain table mutation (not a structural change),
-- so it's safe inline; only the world:set(PlayerMods)/world:remove(Buffs) are deferred.
local playerQuery = world:query(Player):cached()
type Mods = {
    invuln: boolean, armor: number, reflect: number, regen: number, walkSpeed: number,
    damage: number, crit: number, critDmg: number, atkSize: number, knock: number, haste: number, skillCd: number,
    onHitSlow: number, explodeR: number,
}
local pendE:    { number } = {}
local pendMods: { Mods } = {}
local pendDrop: { number } = {}

function M.tick(now: number)
    table.clear(pendE)
    table.clear(pendMods)
    table.clear(pendDrop)

    for e, plr in playerQuery do
        local s = PlayerState.get(plr)
        -- PASSIVE base: gear defense (recomputeDefense owns armor/reflect/regenBonus) + the regen stat,
        -- and the offensive card-stats × item buffs (the values fireStep/spawnBubble/SKILLS used inline).
        local mods: Mods = {
            invuln = false,
            armor = s.armor + s.itemArmor,     -- + Aegis item armor
            reflect = s.reflect + s.itemReflect, -- + Aegis item thorns
            regen = s.hpRegen + s.regenBonus,
            walkSpeed = s.walkSpeed,
            damage = s.damageMult * s.itemDmg,
            crit = s.critChance + s.itemCrit,
            critDmg = s.critDamage + s.itemCritDmg,
            atkSize = s.itemAtkSize,
            knock = s.itemKnock,
            haste = s.haste * s.itemHaste,
            skillCd = s.itemSkillCd,
            onHitSlow = s.itemOnHitSlow,
            explodeR = s.itemExplodeR,          -- Explosive Rounds: bullet burst radius
        }
        -- Berserker (item): fire-rate ramps with MISSING hp — resolved here so it tracks live hp
        -- every tick (can't be a static item* mult). At 0 hp: haste × (1 + itemBerserk).
        if s.itemBerserk > 0 and s.maxHp > 0 then
            mods.haste *= 1 + s.itemBerserk * math.clamp(1 - s.hp / s.maxHp, 0, 1)
        end

        local buffs = world:get(e, Buffs)
        if buffs then
            local any = false
            for kind, b in buffs do
                if now >= b.untilT then
                    buffs[kind] = nil -- expired (safe: removing the current key during pairs is allowed)
                else
                    any = true
                    local def = BUFF_KIND[kind]
                    if def then
                        local f = def.field
                        if def.op == "set" then (mods :: any)[f] = true
                        elseif def.op == "add" then (mods :: any)[f] += b.mag
                        else (mods :: any)[f] *= b.mag end
                    end
                end
            end
            if not any then pendDrop[#pendDrop + 1] = e end -- all buffs gone → drop the empty table
        end

        mods.armor = math.clamp(mods.armor, 0, ARMOR_CAP)
        mods.reflect = math.clamp(mods.reflect, 0, 1)
        mods.haste = math.max(HASTE_MIN, mods.haste) -- guard /0 in fireCd / haste

        pendE[#pendE + 1] = e
        pendMods[#pendMods + 1] = mods
    end

    for i = 1, #pendE do world:set(pendE[i], PlayerMods, pendMods[i]) end
    for _, e in pendDrop do world:remove(e, Buffs) end
end

return M
