-- std/config.luau
-- Central gameplay config. ONE place to tweak the knobs — debug toggles, the wave/spawn
-- tunables, and the mobile control scheme. Lives in ReplicatedStorage.std so the SERVER
-- (SpawnMob/combat/ufo) and the CLIENT (aimstick/syncPet) read the exact same values.
--
-- TWO PLACES, ONE codebase. The SHOWCASE place auto-enables the demo flags (instant ~1000 mobs +
-- invincible + FPS overlay = "1000 mobs, no lag"); the REAL-GAME place runs them OFF (ramped, losable,
-- clean). Detected from game.PlaceId, so the same Rojo sync goes to both places and each behaves
-- correctly with NO hand-flipping. The mainmenu "switch" button teleports between the two.
--!strict

local RunService = game:GetService("RunService")

local Config = {}

-- ── Places (showcase ⇄ real game) ───────────────────────────────────────────────
local SHOWCASE_PLACE = 101281382095901
local REAL_PLACE     =  79858913774130
-- Studio override: leave nil to auto-detect by PlaceId; set true/false to force a mode while testing.
local FORCE_SHOWCASE: boolean? = nil
local IS_SHOWCASE = if FORCE_SHOWCASE ~= nil then FORCE_SHOWCASE else game.PlaceId == SHOWCASE_PLACE
Config.Places = { SHOWCASE = SHOWCASE_PLACE, REAL = REAL_PLACE, IS_SHOWCASE = IS_SHOWCASE }

-- ── Debug / showcase toggles ────────────────────────────────────────────────────
-- Place-driven (above): ON in the SHOWCASE place, OFF in the REAL-GAME place. These change gameplay.
Config.Debug = {
    -- Spawn STRESS_COUNT mobs on the very first wave (fast fill) instead of ramping — showcase only.
    STRESS_TEST  = IS_SHOWCASE,
    STRESS_COUNT = 1000,

    -- Local player takes NO damage (contact + UFO bolts/beam) so a viewer can stand in the horde —
    -- showcase only; the real game is losable. Server-authoritative, so it must live here.
    INVINCIBLE   = IS_SHOWCASE,

    -- On-screen FPS / frame-time / ping overlay — the "no lag" proof. Showcase only; the real game
    -- stays clean. (Mobile has no built-in FPS display, so this is how you read perf on a phone.)
    SHOW_FPS     = IS_SHOWCASE,

    -- STUDIO ONLY: own the entire pet roster on join (playtest any pet without grinding drops/Tix).
    -- Never true in a published place — gated on IsStudio, not the showcase place.
    UNLOCK_ALL   = RunService:IsStudio(),

    -- Logger.debug() passthrough (off = debug logs suppressed). Always-on for info/warn/error.
    LOG_DEBUG    = false,
}

-- ── Wave / spawn tunables (read by SpawnMob.luau) ───────────────────────────────
Config.Spawn = {
    ZOMBIE_TYPE  = "Zombie",
    ZOMBIE_SPEED = 9,
    ZOMBIE_HP    = 30,
    NORMAL_SIZE  = 1,
    ELITE_SIZE   = 2.6,
    ELITE_SPEED  = 7,
    ELITE_HP_MUL = 12,
    BOSS_SIZE    = 5,
    BOSS_SPEED   = 5,
    BOSS_HP_MUL  = 20,      -- boss HP = wave HP × this (a real wall)

    MAX_ZOMBIES  = 1000,    -- perf cap + design sweet spot (density vs map; load is projectiles now)
    BASE_WAVE    = 25,
    WAVE_GROW    = 18,      -- +mobs per wave
    HP_GROWTH    = 0.35,    -- +HP per wave
    ELITE_FROM   = 2,       -- first wave with elites
    -- a boss (→ drops a PET) every Nth wave. Place-gated: SHOWCASE = every wave (spectacle / fast pet
    -- unlocks while you're invincible); REAL game = every 5th (proper pacing — bosses are a real wall).
    BOSS_EVERY   = if IS_SHOWCASE then 1 else 5,
    BREATHER     = 3.0,     -- seconds between waves
    MAX_WAVE_TIME = 90,     -- force the next wave if a few stragglers never die
    SPAWN_EVERY  = 0.08,
    SPAWN_BATCH  = 25,      -- ramp the wave in (no 1-frame dump)
    STRESS_BATCH = 200,     -- fast fill used while Debug.STRESS_TEST fills the first wave

    -- UFO flying enemy (a random sprinkle, not a replacement)
    UFO_TYPE        = "UFO",
    UFO_FROM        = 1,     -- first wave UFOs appear
    UFO_CHANCE      = 0.06,  -- chance a NORMAL spawn is a UFO instead of a zombie
    UFO_HOVER       = 14,    -- spawn/hover height above the ground node
    UFO_SPEED       = 10,
    UFO_N_SCALE     = 0.5,   -- normal (model default-ish)
    UFO_E_SCALE     = 1.0,   -- elite  (scaled back up to 1)
    UFO_B_SCALE     = 2.0,   -- boss
    UFO_N_HP        = 0.6,   -- ×waveHP (squishy flyer — "shouldn't be hard")
    UFO_E_HP        = 0.5,   -- ×eliteHP
    UFO_B_HP        = 0.5,   -- ×bossHP
    UFO_ELITE_CHANCE = 0.35, -- chance an elite is a UFO elite
    UFO_BOSS_CHANCE  = 0.40, -- chance a boss is a UFO boss
}

-- ── Mob replication (dense-slot + i8 deltas) — read by horde.luau + syncMobs.luau ─
-- Positions stream WITHOUT a per-mob id: deltas are written in SLOT order (the client maps
-- slot→entity from the Spawn payload). Each axis is an i8 in STEP-sized fixed-point steps.
Config.Net = {
    -- STEP sets the VELOCITY CEILING of the whole lane: ±127*STEP studs per tick, ÷NET_TICK = studs/sec.
    -- At 0.05 → ±6.35/tick → ~95 studs/sec, which has to clear the fastest thing a mob ever does — that's
    -- LAUNCH speed now, not walk speed (see combatConfig `lift`; a high launcher is ~60). Raised from 0.02
    -- (~38 studs/sec) which capped below launch velocity. Cost is precision: 0.05 studs (~5cm), invisible.
    STEP        = 0.05,
    CHUNK       = 256,    -- slots per unreliable packet (256*3 = 768 B, under the ~900 B cap)
    -- MUST stay ≤ 127*STEP (the real i8 capacity), or this escape hatch silently never fires and fast
    -- motion gets math.clamp'd to the ceiling instead — a launched mob rises in SLOW MOTION and then pops
    -- when the next FULL snapshot lands. (It was 25 — ten times the i8 range — which is exactly that bug.)
    WARP_THRESH = 6.3,    -- a per-axis jump bigger than this can't fit i8 → send an absolute instead
    NET_TICK    = 1 / 15, -- delta send rate
    FULL_EVERY  = 2.5,    -- seconds between absolute f32 snapshots (clears drift + slot churn)
}

-- ── Controls (read by the client: aimstick.luau + syncPet.luau) ─────────────────
Config.Controls = {
    -- When to show the on-screen AIM thumbstick (separate from the movement stick).
    --   "auto"   → only on touch devices (no physical mouse)
    --   "always" → always show it (handy to test in Studio on PC)
    --   "never"  → never; aim follows the mouse/camera
    AIM_STICK = "auto",

    AIM_STICK_RADIUS  = 64,   -- px, outer ring radius
    AIM_STICK_KNOB    = 28,   -- px, inner knob radius
    AIM_STICK_MARGIN  = 90,   -- px, distance from the bottom-right corner to the ring centre
    AIM_STICK_DEADZONE = 0.15, -- fraction of the radius ignored as slop
}

return Config
