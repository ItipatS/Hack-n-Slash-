-- std/itemRegistry.luau
-- SINGLE SOURCE OF TRUTH for passive ITEMS (vampire-survivors-style). Unlike weapons, items don't
-- fire — they buff the whole loadout. Each item has LEVELS whose effects are ABSOLUTE (level 2 is
-- "now 15%", not "+15% on top"). So PlayerState keeps the item LEVELS and RECOMPUTES the derived
-- `item*` multiplier fields from scratch each change (reset to identity → apply every owned item).
--   apply(s, id, level) → fold this item's level-`level` contribution into s.item* fields
--   desc(id, level)     → the effect text for that level (card + tab)
--   maxLevel(id)        → how many levels the item has
-- Items have NO 3D model (no Assets mesh), so the card/tab show a colored emoji BADGE instead.
--!strict

local R = {}

-- value for a level (clamped so over-cap reads the top tier)
local function tier(t: { number }, lvl: number): number
    return t[math.clamp(lvl, 1, #t)]
end
local function pc(n: number): number return math.floor(n * 100 + 0.5) end -- → percent int

R.items = {
    milk = {
        id = "milk", name = "Milk", icon = "🥛", color = Color3.fromRGB(235, 240, 250),
        blurb = "Bigger, heavier hits + reach",
        atk = { 0.10, 0.15, 0.20 }, pick = { 0.30, 0.40, 0.50 }, maxLevel = 3,
        apply = function(s: any, lvl: number)
            local a = tier(R.items.milk.atk, lvl)
            s.itemAtkSize *= (1 + a)
            s.itemKnock *= (1 + a)
            s.itemPickup *= (1 + tier(R.items.milk.pick, lvl))
        end,
        desc = function(lvl: number): string
            return string.format("Attack size & knockback +%d%%, pickup range +%d%%",
                pc(tier(R.items.milk.atk, lvl)), pc(tier(R.items.milk.pick, lvl)))
        end,
    },
    soda = {
        id = "soda", name = "Soda", icon = "🥤", color = Color3.fromRGB(255, 130, 90),
        blurb = "Crit damage up — at a cost",
        cdmg = { 0.10, 0.20, 0.30, 0.40, 0.50 }, maxLevel = 5,
        apply = function(s: any, lvl: number)
            s.itemCritDmg += tier(R.items.soda.cdmg, lvl)
            s.itemSkillCd *= 1.25 -- flat penalty while owned
        end,
        desc = function(lvl: number): string
            return string.format("+%d%% crit damage, but +25%% skill cooldown", pc(tier(R.items.soda.cdmg, lvl)))
        end,
    },
    spinach = {
        id = "spinach", name = "Spinach", icon = "🥬", color = Color3.fromRGB(120, 220, 130),
        blurb = "Raw weapon power",
        dmg = { 0.15, 0.25, 0.35, 0.50 }, maxLevel = 4,
        apply = function(s: any, lvl: number) s.itemDmg *= (1 + tier(R.items.spinach.dmg, lvl)) end,
        desc = function(lvl: number): string
            return string.format("+%d%% weapon damage", pc(tier(R.items.spinach.dmg, lvl)))
        end,
    },
    coffee = {
        id = "coffee", name = "Coffee", icon = "☕", color = Color3.fromRGB(180, 130, 90),
        blurb = "Everything fires faster",
        haste = { 0.10, 0.20, 0.30, 0.40 }, maxLevel = 4,
        apply = function(s: any, lvl: number) s.itemHaste *= (1 + tier(R.items.coffee.haste, lvl)) end,
        desc = function(lvl: number): string
            return string.format("+%d%% firing speed", pc(tier(R.items.coffee.haste, lvl)))
        end,
    },
    clover = {
        id = "clover", name = "Clover", icon = "🍀", color = Color3.fromRGB(110, 235, 140),
        blurb = "Luckier strikes",
        crit = { 0.05, 0.10, 0.15 }, maxLevel = 3,
        apply = function(s: any, lvl: number) s.itemCrit += tier(R.items.clover.crit, lvl) end,
        desc = function(lvl: number): string
            return string.format("+%d%% crit chance", pc(tier(R.items.clover.crit, lvl)))
        end,
    },
    magnet = {
        id = "magnet", name = "Magnet", icon = "🧲", color = Color3.fromRGB(235, 120, 120),
        blurb = "Hoover up drops",
        pick = { 0.25, 0.50, 0.75 }, maxLevel = 3,
        apply = function(s: any, lvl: number) s.itemPickup *= (1 + tier(R.items.magnet.pick, lvl)) end,
        desc = function(lvl: number): string
            return string.format("+%d%% pickup range", pc(tier(R.items.magnet.pick, lvl)))
        end,
    },
    frostbite = {
        id = "frostbite", name = "Frostbite", icon = "❄️", color = Color3.fromRGB(170, 220, 255),
        blurb = "Your hits chill enemies",
        -- factor <1 multiplies into itemOnHitSlow → PlayerMods.onHitSlow → every projectile/aura hit
        -- applies the mob Slow status for 1.5s (the BUL-47 path). Levels are ABSOLUTE per the recompute.
        slow = { 0.85, 0.75, 0.65 }, maxLevel = 3,
        apply = function(s: any, lvl: number) s.itemOnHitSlow *= tier(R.items.frostbite.slow, lvl) end,
        desc = function(lvl: number): string
            return string.format("Your hits slow enemies %d%% for 1.5s", pc(1 - tier(R.items.frostbite.slow, lvl)))
        end,
    },
    secondwind = {
        id = "secondwind", name = "Second Wind", icon = "💫", color = Color3.fromRGB(255, 225, 130),
        blurb = "Cheat death — once per run",
        -- charges feed combat's reviveCap: a lethal hit is survived (50% HP + brief invuln) instead.
        -- Consumed charges never come back mid-run (revivesUsed is monotonic); capacity is re-derived.
        revives = { 1, 2 }, maxLevel = 2,
        apply = function(s: any, lvl: number) s.itemRevives += tier(R.items.secondwind.revives, lvl) end,
        desc = function(lvl: number): string
            local n = tier(R.items.secondwind.revives, lvl)
            return string.format("Survive a lethal hit %d time%s per run (revive at 50%% HP)", n, if n > 1 then "s" else "")
        end,
    },
    leech = {
        id = "leech", name = "Leech", icon = "🩸", color = Color3.fromRGB(200, 60, 80),
        blurb = "Heal on every kill",
        heal = { 1, 2, 4 }, maxLevel = 3,
        apply = function(s: any, lvl: number) s.itemLifesteal += tier(R.items.leech.heal, lvl) end,
        desc = function(lvl: number): string
            return string.format("Heal %d HP per kill", tier(R.items.leech.heal, lvl))
        end,
    },
    bomb = {
        id = "bomb", name = "Explosive Rounds", icon = "💥", color = Color3.fromRGB(255, 140, 50),
        blurb = "Your shots explode on impact",
        -- itemExplodeR → PlayerMods.explodeR → every bullet gets a burst-on-hit (reuses bubbleBurst,
        -- half-damage AoE + the explosion FX). Adds the bomber identity to ANY projectile pet.
        r = { 3, 4.5, 6 }, maxLevel = 3,
        apply = function(s: any, lvl: number) s.itemExplodeR = math.max(s.itemExplodeR, tier(R.items.bomb.r, lvl)) end,
        desc = function(lvl: number): string
            return string.format("Shots explode (%.0f-stud blast, half damage)", tier(R.items.bomb.r, lvl))
        end,
    },
    aegis = {
        id = "aegis", name = "Aegis Spikes", icon = "🛡️", color = Color3.fromRGB(150, 180, 210),
        blurb = "Armor + reflect contact damage",
        armor = { 0.08, 0.15, 0.22 }, reflect = { 0.15, 0.30, 0.45 }, maxLevel = 3,
        apply = function(s: any, lvl: number)
            s.itemArmor += tier(R.items.aegis.armor, lvl)
            s.itemReflect += tier(R.items.aegis.reflect, lvl)
        end,
        desc = function(lvl: number): string
            return string.format("%d%% armor + reflect %d%% of contact damage",
                pc(tier(R.items.aegis.armor, lvl)), pc(tier(R.items.aegis.reflect, lvl)))
        end,
    },
    berserk = {
        id = "berserk", name = "Berserker", icon = "😡", color = Color3.fromRGB(220, 70, 50),
        blurb = "Fire faster the more hurt you are",
        max = { 0.40, 0.70, 1.0 }, maxLevel = 3, -- bonus fire-rate at 0 HP
        apply = function(s: any, lvl: number) s.itemBerserk += tier(R.items.berserk.max, lvl) end,
        desc = function(lvl: number): string
            return string.format("Up to +%d%% fire rate as HP drops", pc(tier(R.items.berserk.max, lvl)))
        end,
    },
}

R.order = { "milk", "soda", "spinach", "coffee", "clover", "magnet", "frostbite", "secondwind", "leech", "bomb", "aegis", "berserk" }

function R.maxLevel(id: string): number
    local it = R.items[id]
    return (it and it.maxLevel) or 1
end

function R.desc(id: string, level: number): string
    local it = R.items[id]
    return if it then it.desc(level) else ""
end

-- fold item `id`'s level-`level` contribution into the s.item* fields (called from a recompute)
function R.apply(s: any, id: string, level: number)
    local it = R.items[id]
    if it then it.apply(s, level) end
end

return R
