-- std/playerState.luau
-- Per-player progression. Two layers:
--   • GLOBAL player stats (level/xp + damageMult, critChance, critDamage) — what level-up
--     cards mostly grant now.
--   • WEAPONS (up to 3 slots, each with its own stats) — the axolotl is weapon #1; new ones
--     drop from elites/bosses. Weapon-specific upgrade cards modify a single weapon.
-- combat reads this; progression/loot write it.
--!strict

export type Weapon = {
    id: string,    -- "axolotl", "fox", ...
    name: string,
    kind: string,  -- "projectile" | "aura" | "drop" | "melee"
    fireCd: number,
    dmg: number,
    pierce: number,
    radius: number,-- projectile size, or AoE/reach radius for aura/drop/melee
    speed: number,
    life: number,  -- projectile lifetime (range = life*speed)
    shots: number, -- projectiles per fire (also: stones per Mole drop)
    spread: number,-- fan (projectile) or cone half-handled angle (melee), radians
    split: number, -- projectile splits into this many bolts on hit (0 = none)
    knock: number, -- knockback impulse on hit
    color: Color3,
    cd: number,    -- runtime: next-allowed-fire server time
    -- leveling (1..maxLevel): each level applies a FIXED behavioral upgrade (petRegistry trees)
    level: number,
    maxLevel: number,
    -- behavior flags set by the upgrade tree (combat reads these; default off)
    aoeRadius: number,    -- >0 → projectile deals a small AoE on hit
    splitPierce: boolean, -- split bolts also pierce
    skillBubbles: number, -- extra projectiles added to the signature skill
    skillRepeat: number,  -- extra times the signature skill fires
    -- archetype behavior flags (revamp): combat reads these by weapon kind
    boomerang: boolean,   -- projectile reverses at half-life and returns (cat)
    chain: number,        -- projectile ricochets to this many nearby enemies on hit (fox)
    dot: number,          -- hazard damage-per-tick (unicorn puddle)
    slowFactor: number,   -- hazard movement-slow multiplier applied to mobs (0..1; 1 = none)
    -- defensive contributions folded into the player (turtle/bear), summed across the run squad
    armor: number,        -- fraction of incoming damage prevented (0..1)
    reflect: number,      -- fraction of incoming damage reflected to attackers (0..1)
    regenBonus: number,   -- flat HP/sec sustain added while equipped (bear)
}

export type State = {
    level: number,
    xp: number,
    xpNext: number,
    -- survival
    hp: number,
    maxHp: number,
    revivesUsed: number, -- cheat-deaths consumed this run; capacity is DERIVED in combat (item/weapon revives)
    dead: boolean,
    playing: boolean, -- true ONLY while actively in the arena (not at the menu/lobby, not a ghost).
                      -- Every combat/horde/drop system gates on this, so a parked lobby or dead
                      -- ghost body contributes nothing (no weapons, no damage, not targeted).
    runStart: number, -- GetServerTimeNow() at run start (for "time survived")
    -- global
    damageMult: number, -- multiplies every weapon's damage
    critChance: number, -- 0..1
    critDamage: number, -- multiplier on a crit
    hpRegen: number,    -- HP regenerated per second
    pickupRange: number,-- multiplier on EXP/Heart pickup radius (1 = base)
    walkSpeed: number,  -- applied to the character's Humanoid.WalkSpeed
    haste: number,      -- overall firing-speed multiplier (1 = base; weapon fireCd / haste)
    expMult: number,    -- EXP-gain multiplier (1 = base)
    tixDropRate: number,-- Tix-drop multiplier (1 = base)
    tix: number,        -- META currency; survives a run restart (datastore later)
    -- ITEMS: passive buffs (run-only). `items` is the owned id→level; the item* fields below are
    -- DERIVED — recomputed from `items` each change (reset to identity, then apply every item).
    items: { [string]: number },
    itemDmg: number,     -- ×weapon damage
    itemAtkSize: number, -- ×attack size / radius / reach
    itemKnock: number,   -- ×knockback
    itemPickup: number,  -- ×pickup range (stacks atop pickupRange)
    itemHaste: number,   -- ×firing speed (stacks atop haste)
    itemCrit: number,    -- +crit chance
    itemCritDmg: number, -- +crit damage
    itemSkillCd: number, -- ×skill cooldown (>1 = slower)
    itemOnHitSlow: number, -- ×on-hit slow factor (<1 = your hits slow enemies; Frostbite)
    itemRevives: number, -- +cheat-death charges (Second Wind; combat reviveCap reads it)
    itemArmor: number,   -- +flat damage reduction (Aegis; folds into PlayerMods.armor)
    itemReflect: number, -- +contact-damage reflect (Aegis; folds into PlayerMods.reflect)
    itemBerserk: number, -- +fire-rate scaling with MISSING hp (Berserker; resolved each tick)
    itemExplodeR: number,-- bullet burst-on-hit radius (Explosive Rounds; folds into PlayerMods.explodeR)
    itemLifesteal: number,-- hp healed per kill (Leech; read in processDeaths)
    -- DEFENSE — PASSIVE gear sources (turtle/bear; recomputed on squad set / weapon level-up). These are
    -- the inputs the playerBuffs resolver folds (with active timed buffs) into the player entity's
    -- PlayerMods component. TIMED invuln/buffs are NOT here anymore — they live on the entity (std/playerBuffs).
    armor: number,       -- fraction of incoming damage prevented (0..0.8)
    reflect: number,     -- fraction of incoming damage reflected to the attacker (0..1)
    regenBonus: number,  -- flat HP/sec sustain (added on top of hpRegen)
    -- PETS: a persisted COLLECTION (pet tab) + the chosen SQUAD (the run loadout). At the menu you
    -- pick up to SQUAD_MAX owned pets; slot 1 = your MAIN (the only one with a usable skill/ult).
    -- owned/squad are persisted by profile.luau; pets unlock via elite/boss drops + the Tix shop.
    owned: { [string]: boolean }, -- every pet id you own (the collection / pet tab)
    squad: { string },            -- the chosen run loadout (ordered, ≤SQUAD_MAX); [1] = main
    weapons: { Weapon },          -- the RUN loadout INSTANCES, built from `squad` at reset()
    bench: { [string]: Weapon },  -- (unused in the new model; kept for type compat)
    main: number,                 -- run main slot = always 1 (squad[1]); the skill button reads it
}

local MAX_WEAPONS = 10
local SQUAD_MAX = 4 -- how many owned pets you may take into a run (slot 1 = main)

local M = {}
M.MAX_WEAPONS = MAX_WEAPONS
M.SQUAD_MAX = SQUAD_MAX

-- Pet definitions (base stats, kind, skill, perks) live in the shared registry — the single
-- source of truth for both the UI and these real stats.
local Registry = require(script.Parent.petRegistry)
local Items    = require(script.Parent.itemRegistry)
M.ALL_WEAPONS = Registry.order

function M.makeWeapon(id: string): Weapon?
    return Registry.make(id) :: Weapon?
end

local states: { [Player]: State } = {}

local function defaults(): State
    return {
        level = 1,
        xp = 0,
        xpNext = 5,
        hp = 100,
        maxHp = 100,
        revivesUsed = 0,
        dead = false,
        playing = false, -- starts at the menu/lobby; set true when the player presses Play
        runStart = workspace:GetServerTimeNow(),
        damageMult = 1.0,
        critChance = 0.05,
        critDamage = 2.0,
        hpRegen = 0.5, -- base passive regen for everyone (HP/sec); Regeneration cards stack on top
        pickupRange = 1.0,
        walkSpeed = 16,
        haste = 1.0,
        expMult = 1.0,
        tixDropRate = 1.0,
        tix = 0,
        items = {},
        itemDmg = 1.0, itemAtkSize = 1.0, itemKnock = 1.0, itemPickup = 1.0, itemHaste = 1.0,
        itemCrit = 0.0, itemCritDmg = 0.0, itemSkillCd = 1.0, itemOnHitSlow = 1.0, itemRevives = 0,
        itemArmor = 0.0, itemReflect = 0.0, itemBerserk = 0.0, itemExplodeR = 0.0, itemLifesteal = 0.0,
        armor = 0.0, reflect = 0.0, regenBonus = 0.0,
        -- own 3 starter pets; choose a squad (≤SQUAD_MAX) at the menu. New pets unlock via
        -- elite/boss drops + the Tix shop (NOT in-game cards).
        owned = { axolotl = true, fox = true, slime = true },
        squad = { "axolotl" },
        weapons = { M.makeWeapon("axolotl") :: Weapon }, -- rebuilt from `squad` at reset()
        bench = {},
        main = 1,
    }
end

-- Recompute the player's DEFENSE stats from the run squad (turtle armor/reflect, bear regen).
-- Summed across weapons, then clamped. Call after any change to weapons / weapon levels.
function M.recomputeDefense(s: State)
    local armor, reflect, regen = 0, 0, 0
    for _, w in s.weapons do
        armor += (w.armor or 0)
        reflect += (w.reflect or 0)
        regen += (w.regenBonus or 0)
    end
    s.armor = math.clamp(armor, 0, 0.8)
    s.reflect = math.clamp(reflect, 0, 1)
    s.regenBonus = regen
end

-- Level up an equipped weapon by index (applies the next behavioral upgrade from its tree).
function M.levelUpWeapon(plr: Player, idx: number)
    local s = M.get(plr)
    local w = s.weapons[idx]
    if w then
        Registry.applyLevelUp(w)
        M.recomputeDefense(s) -- a level-up may raise turtle armor/bear regen
    end
end

-- (re)build the run weapon INSTANCES from s.squad, then recompute derived defense. Ensures at
-- least one weapon (falls back to the first owned pet, then axolotl).
local function buildWeapons(s: State)
    local ws = {}
    for _, id in s.squad do
        if s.owned[id] then
            local w = M.makeWeapon(id)
            if w then ws[#ws + 1] = w end
        end
    end
    if #ws == 0 then
        local fallback = next(s.owned) or "axolotl"
        s.squad = { fallback }
        local w = M.makeWeapon(fallback)
        if w then ws[1] = w end
    end
    s.weapons = ws
    s.main = 1 -- squad[1] is always the main
    M.recomputeDefense(s)
end

-- Pick the single MAIN pet to begin a run with (menu-only). The run starts as just this pet; extra
-- weapons are gained in-run (unlocked-pet level-up cards + boss/elite pet drops). Must be owned.
function M.setMain(plr: Player, id: string)
    local s = M.get(plr)
    if not s.owned[id] then return end
    s.squad = { id }
    buildWeapons(s)
end

-- (kept for profile load) build the menu loadout from a persisted list; only the first entry is used
-- as the main in the current single-main model.
function M.setSquad(plr: Player, ids: { string })
    local s = M.get(plr)
    for _, id in ids do
        if s.owned[id] then s.squad = { id }; buildWeapons(s); return end
    end
end

-- Append an (already-unlocked) pet to the RUN loadout — in-run growth from cards / boss-elite drops.
-- Does NOT change the persisted squad (the run rebuilds to just the main on reset). Returns false if
-- the loadout is full or the pet is already in it.
function M.addToRun(plr: Player, id: string): boolean
    local s = M.get(plr)
    if #s.weapons >= MAX_WEAPONS then return false end
    for _, w in s.weapons do if w.id == id then return false end end
    local w = M.makeWeapon(id)
    if not w then return false end
    s.weapons[#s.weapons + 1] = w
    M.recomputeDefense(s)
    return true
end

-- Recompute the derived item* multipliers from the owned `items` (identity → apply each item).
function M.recomputeItems(s: State)
    s.itemDmg = 1.0; s.itemAtkSize = 1.0; s.itemKnock = 1.0; s.itemPickup = 1.0; s.itemHaste = 1.0
    s.itemCrit = 0.0; s.itemCritDmg = 0.0; s.itemSkillCd = 1.0; s.itemOnHitSlow = 1.0; s.itemRevives = 0
    s.itemArmor = 0.0; s.itemReflect = 0.0; s.itemBerserk = 0.0; s.itemExplodeR = 0.0; s.itemLifesteal = 0.0
    for id, lvl in s.items do Items.apply(s, id, lvl) end
end

-- Gain / level up a passive item. Returns the NEW level (0 = already maxed → no change).
function M.addItem(plr: Player, id: string): number
    local s = M.get(plr)
    local lvl = (s.items[id] or 0)
    if lvl >= Items.maxLevel(id) then return 0 end
    lvl += 1
    s.items[id] = lvl
    M.recomputeItems(s)
    return lvl
end

-- The owned items as {id, level} in stable registry order (for the wire / item tab / HUD).
function M.itemList(plr: Player): { { id: string, level: number } }
    local s = M.get(plr)
    local out = {}
    for _, id in Items.order do
        local lvl = s.items[id]
        if lvl then out[#out + 1] = { id = id, level = lvl } end
    end
    return out
end

-- Add a pet to the persisted COLLECTION (pet tab). Returns true if it was NEW.
function M.ownPet(plr: Player, id: string): boolean
    local s = M.get(plr)
    if s.owned[id] then return false end
    s.owned[id] = true
    return true
end

function M.get(plr: Player): State
    local s = states[plr]
    if not s then
        s = defaults()
        states[plr] = s
    end
    return s
end

-- Wipe to a fresh run (on Play). Tix + the pet COLLECTION + the chosen SQUAD carry over (persistent);
-- the run weapons are rebuilt fresh (levels/items reset). The squad is the menu-chosen loadout.
function M.reset(plr: Player)
    local old = states[plr]
    local s = defaults()
    if old then
        s.tix = old.tix
        s.owned = old.owned
        s.squad = old.squad
    end
    states[plr] = s
    buildWeapons(s) -- build weapons from squad + recompute defense
end

-- Add to the meta currency balance, returns the new total.
function M.addTix(plr: Player, amount: number): number
    local s = M.get(plr)
    s.tix += amount
    return s.tix
end

-- The HUD stats payload (matches Net StatsMsg).
function M.statsMsg(plr: Player): any
    local s = M.get(plr)
    return {
        level = s.level, xp = s.xp, xpNext = s.xpNext,
        hp = math.max(0, math.floor(s.hp)), maxHp = s.maxHp,
    }
end

-- The full derived-stat sheet for the top-right STATS panel (matches Net StatSheetMsg). Values are
-- EFFECTIVE (card stats × item buffs), so the panel reflects items too.
function M.sheetMsg(plr: Player): any
    local s = M.get(plr)
    return {
        maxHp = s.maxHp, hpRegen = s.hpRegen,
        atk = s.damageMult * s.itemDmg, walkSpeed = s.walkSpeed,
        crit = s.critChance + s.itemCrit, critDmg = s.critDamage + s.itemCritDmg,
        pickup = s.pickupRange * s.itemPickup, haste = s.haste * s.itemHaste,
        expMult = s.expMult, tixRate = s.tixDropRate,
        atkSize = s.itemAtkSize, knock = s.itemKnock, skillCd = s.itemSkillCd,
    }
end

-- The owned COLLECTION (pet tab) — in stable registry order (so a client index maps consistently).
function M.ownedIds(plr: Player): { string }
    local s = M.get(plr)
    local ids = {}
    for _, id in Registry.order do
        if s.owned[id] then ids[#ids + 1] = id end
    end
    return ids
end

-- Unlock a weapon (auto-equip if a slot is free, else bench it). Keeps existing instances.
function M.unlock(plr: Player, id: string): boolean
    local s = M.get(plr)
    if s.bench[id] then return false end
    for _, w in s.weapons do if w.id == id then return false end end
    local w = M.makeWeapon(id)
    if not w then return false end
    if #s.weapons < MAX_WEAPONS then
        s.weapons[#s.weapons + 1] = w
    else
        s.bench[id] = w
    end
    return true
end

function M.remove(plr: Player)
    states[plr] = nil
end

return M
