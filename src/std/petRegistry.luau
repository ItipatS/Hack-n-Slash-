-- std/petRegistry.luau
-- SINGLE SOURCE OF TRUTH for every pet/weapon, used by BOTH the UI (panel, cards) and the
-- real combat stats. Per pet: base stats, kind, a signature skill, and a LEVEL TREE.
--   make(id)            -> a fresh weapon INSTANCE (level 1, base stats + behavior flags off)
--   applyLevelUp(w)     -> bump w.level and apply that level's FIXED behavioral upgrade
--   nextDesc(w)         -> the description of w's next level (for the level-up card), or nil if maxed
-- Trees mutate the instance, never the registry — a fresh run / new instance is clean.
--!strict

local R = {}

-- tree entry: [targetLevel] = { desc, apply(w) }. Level 1 is the base; reaching level L applies
-- tree[L]. Each step changes WHAT THE WEAPON DOES (a fixed upgrade), not a stat roll.
local MAX_LEVEL = 10

R.pets = {
    axolotl = {
        id = "axolotl", name = "Axolotl", kind = "projectile", blurb = "Piercing bubbles",
        price = 0, -- starter
        base = { fireCd = 0.6, dmg = 10, pierce = 3, radius = 2.4, speed = 60, life = 1.5, shots = 1, spread = 0, split = 0, knock = 6, color = Color3.fromRGB(120, 200, 255) },
        skill = { name = "Nova", desc = "Fire a full ring of bubbles", cooldown = 8 },
        tree = {
            [2]  = { desc = "Bubbles split on hit",          apply = function(w) w.split += 1 end },
            [3]  = { desc = "+2 pierce",                      apply = function(w) w.pierce += 2 end },
            [4]  = { desc = "Nova: +8 bubbles",               apply = function(w) w.skillBubbles += 8 end },
            [5]  = { desc = "Bubbles burst (small AoE) on hit", apply = function(w) w.aoeRadius = 4 end },
            [6]  = { desc = "Twin stream (+1 shot)",          apply = function(w) w.shots += 1 end },
            [7]  = { desc = "Split bolts also pierce",        apply = function(w) w.splitPierce = true end },
            [8]  = { desc = "Nova fires twice",               apply = function(w) w.skillRepeat += 1 end },
            [9]  = { desc = "Bigger burst radius",            apply = function(w) w.aoeRadius += 2 end },
            [10] = { desc = "Capstone: +1 shot, +12 dmg",     apply = function(w) w.shots += 1; w.dmg += 12 end },
        },
    },
    fox = {
        id = "fox", name = "Fox", kind = "projectile", blurb = "Darts that ricochet between foes",
        price = 0, -- starter
        base = { fireCd = 0.4, dmg = 7, pierce = 1, radius = 2.2, speed = 82, life = 0.8, shots = 1, spread = math.rad(10), split = 0, knock = 2, color = Color3.fromRGB(255, 150, 60), chain = 2 },
        skill = { name = "Barrage", desc = "Wide burst of fast shots where you aim", cooldown = 6 },
        tree = {
            [2]  = { desc = "+1 ricochet",               apply = function(w) w.chain += 1 end },
            [3]  = { desc = "+4 damage",                 apply = function(w) w.dmg += 4 end },
            [4]  = { desc = "Barrage: +6 shots",         apply = function(w) w.skillBubbles += 6 end },
            [5]  = { desc = "+1 ricochet",               apply = function(w) w.chain += 1 end },
            [6]  = { desc = "Twin dart (+1 shot)",       apply = function(w) w.shots += 1 end },
            [7]  = { desc = "+15% fire rate",            apply = function(w) w.fireCd = math.max(0.08, w.fireCd * 0.85) end },
            [8]  = { desc = "Bounces burst (AoE)",       apply = function(w) w.aoeRadius = 3 end },
            [9]  = { desc = "+2 ricochet",               apply = function(w) w.chain += 2 end },
            [10] = { desc = "Capstone: +1 shot, +8 dmg", apply = function(w) w.shots += 1; w.dmg += 8 end },
        },
    },
    slime = {
        id = "slime", name = "Slime", kind = "aura", blurb = "Damages everything around you",
        price = 0, -- starter
        base = { fireCd = 0.4, dmg = 5, pierce = 0, radius = 11, speed = 0, life = 0, shots = 1, spread = 0, split = 0, knock = 3, color = Color3.fromRGB(120, 255, 150) },
        skill = { name = "Quake", desc = "A big damaging pulse around you", cooldown = 7 },
        tree = {
            [2]  = { desc = "+2 radius",                  apply = function(w) w.radius += 2 end },
            [3]  = { desc = "+4 damage",                  apply = function(w) w.dmg += 4 end },
            [4]  = { desc = "Faster ticks (+rate)",       apply = function(w) w.fireCd = math.max(0.08, w.fireCd * 0.85) end },
            [5]  = { desc = "+2 radius",                  apply = function(w) w.radius += 2 end },
            [6]  = { desc = "+5 damage",                  apply = function(w) w.dmg += 5 end },
            [7]  = { desc = "Pushes enemies out",         apply = function(w) w.knock += 4 end },
            [8]  = { desc = "Faster ticks (+rate)",       apply = function(w) w.fireCd = math.max(0.08, w.fireCd * 0.85) end },
            [9]  = { desc = "+3 radius",                  apply = function(w) w.radius += 3 end },
            [10] = { desc = "Capstone: +8 dmg, +3 radius", apply = function(w) w.dmg += 8; w.radius += 3 end },
        },
    },
    mole = {
        id = "mole", name = "Mole", kind = "drop", blurb = "Drops stones on the densest crowd",
        price = 400,
        base = { fireCd = 2.5, dmg = 30, pierce = 0, radius = 9, speed = 0, life = 0, shots = 1, spread = 0, split = 0, knock = 24, color = Color3.fromRGB(180, 140, 90) },
        skill = { name = "Avalanche", desc = "Several stones crash on the crowd", cooldown = 10 },
        tree = {
            [2]  = { desc = "+12 damage",                  apply = function(w) w.dmg += 12 end },
            [3]  = { desc = "+2 radius",                   apply = function(w) w.radius += 2 end },
            [4]  = { desc = "Drops 2 stones",              apply = function(w) w.shots += 1 end },
            [5]  = { desc = "Digs faster (+rate)",         apply = function(w) w.fireCd = math.max(0.2, w.fireCd * 0.85) end },
            [6]  = { desc = "+15 damage",                  apply = function(w) w.dmg += 15 end },
            [7]  = { desc = "Drops 3 stones",              apply = function(w) w.shots += 1 end },
            [8]  = { desc = "+2 radius",                   apply = function(w) w.radius += 2 end },
            [9]  = { desc = "+knockback",                  apply = function(w) w.knock += 12 end },
            [10] = { desc = "Capstone: +2 stones, +20 dmg", apply = function(w) w.shots += 2; w.dmg += 20 end },
        },
    },
    bear = {
        id = "bear", name = "Bear", kind = "melee", blurb = "Bruiser: heavy cone + HP sustain",
        price = 500,
        base = { fireCd = 1.1, dmg = 22, pierce = 0, radius = 15, speed = 0, life = 0, shots = 1, spread = math.rad(100), split = 0, knock = 20, color = Color3.fromRGB(255, 120, 120), regenBonus = 1.0 },
        skill = { name = "Roar", desc = "Shockwave: knockback + heal burst", cooldown = 8 },
        tree = {
            [2]  = { desc = "+8 damage",                    apply = function(w) w.dmg += 8 end },
            [3]  = { desc = "+1 HP/sec sustain",            apply = function(w) w.regenBonus += 1 end },
            [4]  = { desc = "Wider cone",                   apply = function(w) w.spread += math.rad(20) end },
            [5]  = { desc = "+knockback",                   apply = function(w) w.knock += 10 end },
            [6]  = { desc = "+12 damage",                   apply = function(w) w.dmg += 12 end },
            [7]  = { desc = "+1 HP/sec sustain",            apply = function(w) w.regenBonus += 1 end },
            [8]  = { desc = "Swings faster (+rate)",        apply = function(w) w.fireCd = math.max(0.2, w.fireCd * 0.85) end },
            [9]  = { desc = "+3 reach",                     apply = function(w) w.radius += 3 end },
            [10] = { desc = "Capstone: 360° maul, +16 dmg", apply = function(w) w.spread = math.pi * 2; w.dmg += 16 end },
        },
    },

    -- ── New weapons (in-run finds; not starters) ───────────────────────────────────
    unicorn = {
        id = "unicorn", name = "Unicorn", kind = "puddle", blurb = "Rainbow puddles: damage-over-time + slow",
        price = 900,
        base = { fireCd = 2.2, dmg = 0, pierce = 0, radius = 11, speed = 0, life = 4.0, shots = 1, spread = 0, split = 0, knock = 0, color = Color3.fromRGB(220, 150, 255), dot = 6, slowFactor = 0.6 },
        skill = { name = "Taste the Rainbow", desc = "A slow rainbow beam that sweeps where you aim", cooldown = 12 },
        tree = {
            [2] = { desc = "+2 DoT per tick",               apply = function(w) w.dot += 2 end },
            [3] = { desc = "+2 puddle radius",              apply = function(w) w.radius += 2 end },
            [4] = { desc = "Stronger slow",                 apply = function(w) w.slowFactor = math.max(0.3, w.slowFactor - 0.1) end },
            [5] = { desc = "+1.5s puddle",                  apply = function(w) w.life += 1.5 end },
            [6] = { desc = "+3 DoT per tick",               apply = function(w) w.dot += 3 end },
            [7] = { desc = "Faster cast (+rate)",           apply = function(w) w.fireCd = math.max(0.8, w.fireCd * 0.85) end },
            [8] = { desc = "+3 puddle radius",              apply = function(w) w.radius += 3 end },
            [9] = { desc = "Beam lasts longer",             apply = function(w) w.skillBubbles += 1 end }, -- combat reads skillBubbles to extend the beam
            [10] = { desc = "Capstone: +5 DoT, +2 radius",  apply = function(w) w.dot += 5; w.radius += 2 end },
        },
    },
    cat = {
        id = "cat", name = "Cat", kind = "projectile", blurb = "Clawed boomerang — hits out and back",
        price = 600,
        -- shape 2 = spinning boomerang disc (visual lane) — reads as a thrown blade, not a bubble
        base = { fireCd = 0.7, dmg = 9, pierce = 3, radius = 2.4, speed = 70, life = 1.2, shots = 1, spread = 0, split = 0, knock = 4, color = Color3.fromRGB(255, 180, 120), boomerang = true, shape = 2 },
        skill = { name = "Nine Lives", desc = "A storm of boomerangs around you", cooldown = 8 },
        tree = {
            [2] = { desc = "+1 pierce",                     apply = function(w) w.pierce += 1 end },
            [3] = { desc = "+4 damage",                     apply = function(w) w.dmg += 4 end },
            [4] = { desc = "Twin boomerang (+1 shot)",      apply = function(w) w.shots += 1 end },
            [5] = { desc = "Longer flight",                 apply = function(w) w.life += 0.4 end },
            [6] = { desc = "+2 pierce",                     apply = function(w) w.pierce += 2 end },
            [7] = { desc = "Faster throw (+rate)",          apply = function(w) w.fireCd = math.max(0.25, w.fireCd * 0.85) end },
            [8] = { desc = "Boomerangs burst (AoE)",        apply = function(w) w.aoeRadius = 3 end },
            [9] = { desc = "+6 damage",                     apply = function(w) w.dmg += 6 end },
            [10] = { desc = "Capstone: +1 shot, +8 dmg",    apply = function(w) w.shots += 1; w.dmg += 8 end },
        },
    },
    panda = {
        id = "panda", name = "Panda", kind = "bamboo", blurb = "Summons lasting bamboo from the ground (knockback)",
        price = 700,
        -- slow placement, but each bamboo patch LINGERS (life) — a zone-control playstyle
        base = { fireCd = 2.2, dmg = 8, pierce = 0, radius = 3, speed = 0, life = 3.5, shots = 3, spread = 0, split = 0, knock = 10, color = Color3.fromRGB(230, 230, 235) },
        skill = { name = "Giant Bamboo", desc = "One huge bamboo erupts — big knockback + damage", cooldown = 9 },
        tree = {
            [2] = { desc = "+4 bamboo damage",              apply = function(w) w.dmg += 4 end },
            [3] = { desc = "+1 bamboo",                     apply = function(w) w.shots += 1 end },
            [4] = { desc = "+knockback",                    apply = function(w) w.knock += 6 end },
            [5] = { desc = "Faster summon (+rate)",         apply = function(w) w.fireCd = math.max(0.4, w.fireCd * 0.85) end },
            [6] = { desc = "+1 bamboo",                     apply = function(w) w.shots += 1 end },
            [7] = { desc = "+1 radius",                     apply = function(w) w.radius += 1 end },
            [8] = { desc = "+6 bamboo damage",              apply = function(w) w.dmg += 6 end },
            [9] = { desc = "+2 bamboo",                     apply = function(w) w.shots += 2 end },
            [10] = { desc = "Capstone: +2 bamboo, +8 dmg",  apply = function(w) w.shots += 2; w.dmg += 8 end },
        },
    },
    turtle = {
        id = "turtle", name = "Turtle", kind = "orbit", blurb = "Orbiting shells + armor + thorns",
        price = 1000,
        base = { fireCd = 0.15, dmg = 5, pierce = 0, radius = 3, speed = 0, life = 0, shots = 3, spread = 0, split = 0, knock = 8, color = Color3.fromRGB(120, 200, 140), armor = 0.15, reflect = 0.2 },
        skill = { name = "Shell Nova", desc = "Briefly invulnerable + a huge radial shove", cooldown = 12 },
        tree = {
            [2] = { desc = "+1 shell",                      apply = function(w) w.shots += 1 end },
            [3] = { desc = "+5% armor",                     apply = function(w) w.armor += 0.05 end },
            [4] = { desc = "+3 shell damage",               apply = function(w) w.dmg += 3 end },
            [5] = { desc = "+10% thorns",                   apply = function(w) w.reflect += 0.1 end },
            [6] = { desc = "+1 shell",                      apply = function(w) w.shots += 1 end },
            [7] = { desc = "+5% armor",                     apply = function(w) w.armor += 0.05 end },
            [8] = { desc = "+knockback",                    apply = function(w) w.knock += 6 end },
            [9] = { desc = "+1 radius",                     apply = function(w) w.radius += 1 end },
            [10] = { desc = "Capstone: +1 shell, +10% thorns", apply = function(w) w.shots += 1; w.reflect += 0.1 end },
        },
    },
    cow = {
        id = "cow", name = "Cow", kind = "projectile", blurb = "Lobbed milk bottles splash into sticky slow puddles",
        price = 500,
        -- KIT REVAMP (was a slime-aura copy): short-flight bottles that SPLASH on retire — the
        -- onLand hook (BUL-48). Hazard kind 6 = white milk puddle (mild DoT + sticky slow).
        base = { fireCd = 1.4, dmg = 6, pierce = 1, radius = 2.6, speed = 42, life = 0.8, shots = 1, spread = math.rad(8), split = 0, knock = 4, color = Color3.fromRGB(245, 240, 220),
                 onLand = { kind = 6, r = 5, dmg = 2, slowFactor = 0.6, tickEvery = 0.4, life = 2.5 } },
        skill = { name = "Stampede", desc = "A spectral herd charges along your aim, trampling the horde", cooldown = 9 },
        tree = {
            [2]  = { desc = "Bigger splash",                apply = function(w) w.onLand.r += 1 end },
            [3]  = { desc = "+4 damage",                    apply = function(w) w.dmg += 4 end },
            [4]  = { desc = "Faster lob (+rate)",           apply = function(w) w.fireCd = math.max(0.4, w.fireCd * 0.85) end },
            [5]  = { desc = "Stickier milk",                apply = function(w) w.onLand.slowFactor = math.max(0.3, w.onLand.slowFactor - 0.1) end },
            [6]  = { desc = "+2 splash DoT",                apply = function(w) w.onLand.dmg += 2 end },
            [7]  = { desc = "+5 damage",                    apply = function(w) w.dmg += 5 end },
            [8]  = { desc = "Stampede: longer charge",      apply = function(w) w.skillBubbles += 1 end },
            [9]  = { desc = "Twin bottle (+1 shot)",        apply = function(w) w.shots += 1 end },
            [10] = { desc = "Capstone: +8 dmg, bigger splash", apply = function(w) w.dmg += 8; w.onLand.r += 2 end },
        },
    },
    elephant = {
        id = "elephant", name = "Elephant", kind = "projectile", blurb = "Trunk cannon: a slow HUGE shot that blasts on impact",
        price = 800,
        -- KIT REVAMP (was a mole-drop copy): heavy aimed artillery — one massive cannonball with
        -- big knockback that BURSTS on impact (aoeRadius → bubbleBurst + explosion FX). You AIM it;
        -- mole keeps the auto-target-densest-crowd identity.
        base = { fireCd = 2.2, dmg = 40, pierce = 1, radius = 3.5, speed = 55, life = 1.0, shots = 1, spread = math.rad(10), split = 0, knock = 30, color = Color3.fromRGB(150, 160, 175), aoeRadius = 6 },
        skill = { name = "Earthshaker", desc = "One MASSIVE stomp: quake rings + a staggering shockwave", cooldown = 12 },
        tree = {
            [2]  = { desc = "+14 damage",                   apply = function(w) w.dmg += 14 end },
            [3]  = { desc = "Bigger blast",                 apply = function(w) w.aoeRadius += 2 end },
            [4]  = { desc = "Faster reload (+rate)",        apply = function(w) w.fireCd = math.max(0.6, w.fireCd * 0.85) end },
            [5]  = { desc = "+18 damage",                   apply = function(w) w.dmg += 18 end },
            [6]  = { desc = "+knockback",                   apply = function(w) w.knock += 10 end },
            [7]  = { desc = "Bigger blast",                 apply = function(w) w.aoeRadius += 2 end },
            [8]  = { desc = "Earthshaker: +1 quake ring",   apply = function(w) w.skillBubbles += 1 end },
            [9]  = { desc = "+knockback",                   apply = function(w) w.knock += 14 end },
            [10] = { desc = "Capstone: twin cannon, +24 dmg", apply = function(w) w.shots += 1; w.dmg += 24 end },
        },
    },
    bee = {
        id = "bee", name = "Bee", kind = "projectile", blurb = "Bomber bees that explode on impact",
        price = 700,
        -- low pierce → pops on contact; modest direct hit, the BLAST is the payload. aoeRadius>0 makes each
        -- bee burst on hit (combat reads it as the bubble's `aoe` → bubbleBurst). Synergy: any future +AoE
        -- item (Explosive Rounds) stacks straight onto these bombers.
        base = { fireCd = 0.55, dmg = 8, pierce = 1, radius = 2.2, speed = 72, life = 1.2, shots = 1, spread = math.rad(6), split = 0, knock = 4, color = Color3.fromRGB(255, 205, 70), aoeRadius = 4 },
        skill = { name = "Hive", desc = "Deploy hive turret(s) that lob bomber bees at the nearest foe", cooldown = 10 },
        tree = {
            [2]  = { desc = "Bigger blast radius",               apply = function(w) w.aoeRadius += 1.5 end },
            [3]  = { desc = "+4 damage",                         apply = function(w) w.dmg += 4 end },
            [4]  = { desc = "Hive: +1 turret",                   apply = function(w) w.skillRepeat += 1 end },
            [5]  = { desc = "Twin bomber (+1 shot)",             apply = function(w) w.shots += 1 end },
            [6]  = { desc = "Bigger blast radius",               apply = function(w) w.aoeRadius += 1.5 end },
            [7]  = { desc = "+15% fire rate",                    apply = function(w) w.fireCd = math.max(0.12, w.fireCd * 0.85) end },
            [8]  = { desc = "Hive lasts longer",                 apply = function(w) w.skillBubbles += 1 end },
            [9]  = { desc = "+6 damage",                         apply = function(w) w.dmg += 6 end },
            [10] = { desc = "Capstone: +1 shot, massive blasts", apply = function(w) w.shots += 1; w.aoeRadius += 3 end },
        },
    },
    wolf = {
        id = "wolf", name = "Wolf", kind = "melee", blurb = "Fast bleeding bites + a rallying pack",
        price = 800,
        -- faster/lighter than Bear's heavy cone; `dot` makes every bite BLEED (combat ticks it on the
        -- bitten mob for a couple seconds). Sustain comes from regenBonus, same channel as Bear.
        base = { fireCd = 0.55, dmg = 10, pierce = 0, radius = 12, speed = 0, life = 0, shots = 1, spread = math.rad(70), split = 0, knock = 6, color = Color3.fromRGB(170, 175, 195), dot = 3 },
        skill = { name = "Pack Howl", desc = "Spirit wolves dash through the crowd + the pack rallies (damage & speed)", cooldown = 11 },
        tree = {
            [2]  = { desc = "+6 damage",                    apply = function(w) w.dmg += 6 end },
            [3]  = { desc = "+2 bleed DoT",                 apply = function(w) w.dot += 2 end },
            [4]  = { desc = "Pack Howl: +1 wolf",           apply = function(w) w.skillRepeat += 1 end },
            [5]  = { desc = "Wider bite",                   apply = function(w) w.spread += math.rad(20) end },
            [6]  = { desc = "+1 HP/sec sustain",            apply = function(w) w.regenBonus += 1 end },
            [7]  = { desc = "+8 damage",                    apply = function(w) w.dmg += 8 end },
            [8]  = { desc = "Faster bites (+rate)",         apply = function(w) w.fireCd = math.max(0.2, w.fireCd * 0.85) end },
            [9]  = { desc = "+3 bleed DoT",                 apply = function(w) w.dot += 3 end },
            [10] = { desc = "Capstone: +1 wolf, +12 dmg",   apply = function(w) w.skillRepeat += 1; w.dmg += 12 end },
        },
    },
    penguin = {
        id = "penguin", name = "Penguin", kind = "projectile", blurb = "Ice cubes that chill on hit and leave a freezing trail",
        price = 600,
        -- slowFactor < 1 on a PROJECTILE = every hit chills (BUL-47); `trail` = the cube drops short
        -- freeze patches along its flight path (combat reads it per tick → spawnHazard), so each shot
        -- carves a chilled lane through the horde.
        base = { fireCd = 0.5, dmg = 7, pierce = 2, radius = 2.2, speed = 70, life = 1.2, shots = 1, spread = 0, split = 0, knock = 3, color = Color3.fromRGB(160, 220, 255), slowFactor = 0.65,
                 shape = 1, -- visual lane: ice CUBE bullets (BubbleFire.shape)
                 trail = { every = 0.3, r = 3, slowFactor = 0.7, life = 1.2 } },
        skill = { name = "Glacier Wall", desc = "A real ice wall erupts across your aim — mobs can't pass", cooldown = 9 },
        tree = {
            [2]  = { desc = "+1 pierce",                    apply = function(w) w.pierce += 1 end },
            [3]  = { desc = "+3 frost damage",              apply = function(w) w.dmg += 3 end },
            [4]  = { desc = "Glacier Wall: +2 slabs (wider)", apply = function(w) w.skillBubbles += 2 end },
            [5]  = { desc = "Colder: stronger slow",        apply = function(w) w.slowFactor = math.max(0.2, w.slowFactor - 0.1); w.trail.slowFactor = math.max(0.3, w.trail.slowFactor - 0.1) end },
            [6]  = { desc = "Twin cube (+1 shot)",          apply = function(w) w.shots += 1 end },
            [7]  = { desc = "+15% fire rate",               apply = function(w) w.fireCd = math.max(0.1, w.fireCd * 0.85) end },
            [8]  = { desc = "Frostier trail",               apply = function(w) w.trail.r += 1; w.trail.life += 0.5 end },
            [9]  = { desc = "+4 frost damage",              apply = function(w) w.dmg += 4 end },
            [10] = { desc = "Capstone: +1 shot, +8 dmg",    apply = function(w) w.shots += 1; w.dmg += 8 end },
        },
    },
    frog = {
        id = "frog", name = "Frog", kind = "tongue", blurb = "Long tongue lash — yanks foes in, sometimes eats them whole",
        price = 750,
        -- NOT a bullet: `radius` is the tongue's REACH along aim; `knock` PULLS the bite toward you;
        -- eatChance = odds a small (non-elite/boss) mob is swallowed outright → eatHeal hp back.
        -- Eaten mobs still die through the normal pipeline (drops/EXP pay out).
        base = { fireCd = 0.7, dmg = 12, pierce = 0, radius = 28, speed = 0, life = 0, shots = 1, spread = 0, split = 0, knock = 8, color = Color3.fromRGB(120, 230, 120), eatChance = 0.10, eatHeal = 5 },
        skill = { name = "Feeding Frenzy", desc = "Rapid lashes at everything nearby — double the eat odds", cooldown = 10 },
        tree = {
            [2]  = { desc = "+4 damage",                    apply = function(w) w.dmg += 4 end },
            [3]  = { desc = "+5% eat chance",               apply = function(w) w.eatChance += 0.05 end },
            [4]  = { desc = "Frenzy: +3 lashes",            apply = function(w) w.skillBubbles += 3 end },
            [5]  = { desc = "Longer tongue (+5 reach)",     apply = function(w) w.radius += 5 end },
            [6]  = { desc = "+6 damage",                    apply = function(w) w.dmg += 6 end },
            [7]  = { desc = "Faster lash (+rate)",          apply = function(w) w.fireCd = math.max(0.25, w.fireCd * 0.85) end },
            [8]  = { desc = "Bigger meals (+3 heal)",       apply = function(w) w.eatHeal += 3 end },
            [9]  = { desc = "+5% eat chance",               apply = function(w) w.eatChance += 0.05 end },
            [10] = { desc = "Capstone: +8 dmg, +5% eat",    apply = function(w) w.dmg += 8; w.eatChance += 0.05 end },
        },
    },
    phoenix = {
        id = "phoenix", name = "Phoenix", kind = "orbit", blurb = "Orbiting embers, burning regen — and one cheat death per run",
        price = 1200,
        -- `revives` feeds the cheat-death hook (combat reviveCap): a lethal hit is survived instead,
        -- once per run. skillBubbles → bigger Rebirth burst; skillRepeat → longer Rebirth invuln.
        base = { fireCd = 0.18, dmg = 6, pierce = 0, radius = 3, speed = 0, life = 0, shots = 2, spread = 0, split = 0, knock = 4, color = Color3.fromRGB(255, 140, 60), regenBonus = 1.0, revives = 1 },
        skill = { name = "Rebirth", desc = "Erupt in flame: big burst + heal + brief invulnerability", cooldown = 14 },
        tree = {
            [2]  = { desc = "+1 ember",                     apply = function(w) w.shots += 1 end },
            [3]  = { desc = "+1 HP/sec regen",              apply = function(w) w.regenBonus += 1 end },
            [4]  = { desc = "Rebirth: bigger burst",        apply = function(w) w.skillBubbles += 1 end },
            [5]  = { desc = "+3 ember damage",              apply = function(w) w.dmg += 3 end },
            [6]  = { desc = "+1 ember",                     apply = function(w) w.shots += 1 end },
            [7]  = { desc = "Longer Rebirth invuln",        apply = function(w) w.skillRepeat += 1 end },
            [8]  = { desc = "+2 HP/sec regen",              apply = function(w) w.regenBonus += 2 end },
            [9]  = { desc = "+1 orbit radius",              apply = function(w) w.radius += 1 end },
            [10] = { desc = "Capstone: +6 dmg, +1 cheat death", apply = function(w) w.dmg += 6; w.revives += 1 end },
        },
    },
    hedgehog = {
        id = "hedgehog", name = "Hedgehog", kind = "orbit", blurb = "Orbiting spikes + armor & thorns",
        price = 900,
        base = { fireCd = 0.16, dmg = 4, pierce = 0, radius = 3, speed = 0, life = 0, shots = 3, spread = 0, split = 0, knock = 5, color = Color3.fromRGB(200, 160, 110), armor = 0.10, reflect = 0.15 },
        skill = { name = "Bramble Ring", desc = "A ring of thorns erupts around you + a thorn-skin surge", cooldown = 10 },
        tree = {
            [2]  = { desc = "+1 spike",                     apply = function(w) w.shots += 1 end },
            [3]  = { desc = "+5% armor",                    apply = function(w) w.armor += 0.05 end },
            [4]  = { desc = "Bramble Ring: +2 thorns",      apply = function(w) w.skillBubbles += 2 end },
            [5]  = { desc = "+10% thorns",                  apply = function(w) w.reflect += 0.1 end },
            [6]  = { desc = "+3 spike damage",              apply = function(w) w.dmg += 3 end },
            [7]  = { desc = "+1 spike",                     apply = function(w) w.shots += 1 end },
            [8]  = { desc = "+5% armor",                    apply = function(w) w.armor += 0.05 end },
            [9]  = { desc = "+1 orbit radius",              apply = function(w) w.radius += 1 end },
            [10] = { desc = "Capstone: +1 spike, +10% thorns", apply = function(w) w.shots += 1; w.reflect += 0.1 end },
        },
    },
    dragon = {
        id = "dragon", name = "Dragon", kind = "melee", blurb = "Fire-breath cone that BURNS — and a sustained inferno beam",
        price = 1000,
        -- `dot` rides the melee BLEED mechanic as a BURN: every cone hit keeps ticking fire
        base = { fireCd = 0.9, dmg = 16, pierce = 0, radius = 14, speed = 0, life = 0, shots = 1, spread = math.rad(90), split = 0, knock = 10, color = Color3.fromRGB(255, 90, 60), dot = 2 },
        skill = { name = "Inferno Breath", desc = "A sustained aim-tracked flame beam (pure damage)", cooldown = 13 },
        tree = {
            [2]  = { desc = "+6 damage",                    apply = function(w) w.dmg += 6 end },
            [3]  = { desc = "Wider cone",                   apply = function(w) w.spread += math.rad(20) end },
            [4]  = { desc = "Inferno: longer breath",       apply = function(w) w.skillBubbles += 1 end },
            [5]  = { desc = "+2 burn DoT",                  apply = function(w) w.dot += 2 end },
            [6]  = { desc = "+8 damage",                    apply = function(w) w.dmg += 8 end },
            [7]  = { desc = "+15% fire rate",               apply = function(w) w.fireCd = math.max(0.2, w.fireCd * 0.85) end },
            [8]  = { desc = "+2 reach",                     apply = function(w) w.radius += 2 end },
            [9]  = { desc = "+3 burn DoT",                  apply = function(w) w.dot += 3 end },
            [10] = { desc = "Capstone: wider cone, +12 dmg", apply = function(w) w.spread += math.rad(40); w.dmg += 12 end },
        },
    },
    owl = {
        id = "owl", name = "Owl", kind = "projectile", blurb = "Slow, piercing sniper bolts — rewards aim",
        price = 850,
        base = { fireCd = 1.3, dmg = 28, pierce = 4, radius = 2.4, speed = 110, life = 1.4, shots = 1, spread = 0, split = 0, knock = 8, color = Color3.fromRGB(230, 210, 170) },
        skill = { name = "Death Mark", desc = "Mark the toughest foes — guaranteed-crit bolts hunt them down", cooldown = 12 },
        tree = {
            [2]  = { desc = "+2 pierce",                    apply = function(w) w.pierce += 2 end },
            [3]  = { desc = "+6 damage",                    apply = function(w) w.dmg += 6 end },
            [4]  = { desc = "Death Mark: +1 target",        apply = function(w) w.skillBubbles += 1 end },
            [5]  = { desc = "+8 damage",                    apply = function(w) w.dmg += 8 end },
            [6]  = { desc = "Faster nock (+rate)",          apply = function(w) w.fireCd = math.max(0.2, w.fireCd * 0.85) end },
            [7]  = { desc = "+2 pierce",                    apply = function(w) w.pierce += 2 end },
            [8]  = { desc = "Mark: +1 volley wave",         apply = function(w) w.skillRepeat += 1 end },
            [9]  = { desc = "+10 damage",                   apply = function(w) w.dmg += 10 end },
            [10] = { desc = "Capstone: +12 dmg, +2 pierce", apply = function(w) w.dmg += 12; w.pierce += 2 end },
        },
    },
    crab = {
        id = "crab", name = "Crab", kind = "aura", blurb = "Shoving shockwave pulses + a hard shell",
        price = 800,
        base = { fireCd = 0.5, dmg = 7, pierce = 0, radius = 11, speed = 0, life = 0, shots = 1, spread = 0, split = 0, knock = 8, color = Color3.fromRGB(240, 110, 90), armor = 0.12 },
        skill = { name = "Riptide", desc = "Expanding knockback rings surge outward — shed the swarm", cooldown = 11 },
        tree = {
            [2]  = { desc = "+2 radius",                    apply = function(w) w.radius += 2 end },
            [3]  = { desc = "+4 damage",                    apply = function(w) w.dmg += 4 end },
            [4]  = { desc = "Riptide: +1 ring",             apply = function(w) w.skillBubbles += 1 end },
            [5]  = { desc = "+5% armor",                    apply = function(w) w.armor += 0.05 end },
            [6]  = { desc = "+knockback",                   apply = function(w) w.knock += 5 end },
            [7]  = { desc = "Faster pulse (+rate)",         apply = function(w) w.fireCd = math.max(0.1, w.fireCd * 0.85) end },
            [8]  = { desc = "+3 radius",                    apply = function(w) w.radius += 3 end },
            [9]  = { desc = "+6 damage",                    apply = function(w) w.dmg += 6 end },
            [10] = { desc = "Capstone: +1 ring, +8 dmg",    apply = function(w) w.skillBubbles += 1; w.dmg += 8 end },
        },
    },
}

R.order = { "axolotl", "fox", "slime", "mole", "bear", "unicorn", "cat", "panda", "cow", "elephant", "turtle", "bee", "wolf", "penguin", "frog", "phoenix", "hedgehog", "dragon", "owl", "crab" }

-- a pet's max level = the highest level defined in its tree (sparse trees don't create no-op cards)
function R.maxLevel(id: string): number
    local p = R.pets[id]
    if not p then return 1 end
    local m = 1
    for lvl in p.tree do if lvl > m then m = lvl end end
    return m
end

-- the Animals MeshPart name for a pet id (ids are the lowercase asset name → just capitalize)
function R.meshName(id: string): string
    return id:sub(1, 1):upper() .. id:sub(2)
end

-- a fresh weapon instance (base stats copied + identity + runtime cd + level/behavior defaults)
function R.make(id: string)
    local p = R.pets[id]
    if not p then return nil end
    local w = table.clone(p.base)
    w.id = id
    w.name = p.name
    w.kind = p.kind
    w.cd = 0
    w.level = 1
    w.maxLevel = R.maxLevel(id)
    w.aoeRadius = p.base.aoeRadius or 0 -- bee bombers carry a base blast; tree pets still set theirs via the tree
    w.splitPierce = false
    w.skillBubbles = 0
    w.skillRepeat = 0
    -- archetype flags (revamp) — base may override below via the pet's `base`; trees scale them
    w.boomerang = p.base.boomerang or false
    w.chain = p.base.chain or 0
    w.dot = p.base.dot or 0
    w.slowFactor = p.base.slowFactor or 1
    w.armor = p.base.armor or 0
    w.reflect = p.base.reflect or 0
    w.regenBonus = p.base.regenBonus or 0
    -- on-land splash params: OWN copy — table.clone(p.base) is shallow, so without this a tree
    -- upgrade mutating w.onLand would write into the REGISTRY and corrupt every future instance
    w.onLand = if p.base.onLand then table.clone(p.base.onLand) else nil
    w.trail = if p.base.trail then table.clone(p.base.trail) else nil -- penguin ice trail (same aliasing rule)
    w.eatChance = p.base.eatChance or 0 -- frog: odds a small mob is swallowed whole
    w.eatHeal = p.base.eatHeal or 0     -- frog: hp restored per swallowed mob
    return w
end

-- bump a weapon to its next level and apply that level's fixed upgrade (no-op if maxed)
function R.applyLevelUp(w: any)
    local p = R.pets[w.id]
    if not p then return end
    local next = w.level + 1
    local up = p.tree[next]
    if not up then return end -- maxed
    w.level = next
    up.apply(w)
end

-- description of a weapon's NEXT level (for the level-up card), or nil if maxed
function R.nextDesc(w: any): string?
    local p = R.pets[w.id]
    if not p then return nil end
    local up = p.tree[w.level + 1]
    return up and up.desc or nil
end

return R
