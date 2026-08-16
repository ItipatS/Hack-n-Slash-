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

    -- STUDIO ONLY dev tool: navbake_test.server.luau bakes the navmesh from workspace.Map and
    -- visualizes it. OFF by default so normal playtests aren't slowed by the bake. Flip true to run.
    NAV_BAKE_TEST = false,

    -- Horde NAV SOURCE: false = hand-painted PathData (default, unchanged). true = bake the navmesh
    -- from workspace.Map at boot and drive the horde off it instead (A/B the generated nav live).
    -- Works in a real game too, not just Studio — but the boot bake costs a few seconds.
    -- TEMP: back on PathData while the navmesh's multi-plane connection is finished later. Flip true
    -- (+ a debug flag below) to resume navmesh work — all of it is still wired through std/Nav.
    USE_NAVMESH   = false,

    -- When USE_NAVMESH is on, render the WHOLE baked graph at boot (workspace.NavmeshDebug). Very heavy
    -- (the full mesh is 100k+ tiles on this map) — off; prefer NAV_DEBUG_FLOW below for diagnosis.
    NAV_DEBUG_SHOW = true,

    -- LIVE FLOW view (horde-driven): render ONLY the nodes/edges mobs are actually flowing over, updated
    -- a few times a second. RED = mob stuck with no path to a player (beelines / sinks under the map),
    -- GREEN = mob on a connected route, BLUE = route toward the player. The "where are mobs routed" tool.
    NAV_DEBUG_FLOW = false,

    -- Render the navmesh's ONE-WAY edges (drops + one-way jumps) as arrows at boot — ORANGE = drop/down,
    -- CYAN = level. The "did my ledges actually get drop links?" check. Studio diagnosis only.
    NAV_DEBUG_LINKS = false,

    -- Colour every node by CONNECTED COMPONENT: largest surface = GREEN, every other colour = an ISLAND
    -- not linked to it (a plane that won't path to the player → mobs detour "over the map"). The
    -- definitive "which planes are actually connected" view. Studio diagnosis only.
    NAV_DEBUG_COMPONENTS = false,
}

-- ── Navmesh bake tuning (read by std/Nav.luau) ──────────────────────────────────
-- SPACING = stud gap between sampled nodes, the MASTER perf knob. The flow-field flood cost (and bake
-- time + memory) scale with NODE COUNT ≈ area / SPACING². This map is ~750×750, so spacing 2 ≈ 137k
-- nodes (flood ~100ms — too heavy); spacing 4 ≈ 34k (~4× cheaper); spacing 6 ≈ 15k. Pathfinding is
-- mob-count-INDEPENDENT (one shared flood; each mob is an O(1) lookup), so this alone decides whether
-- 1000 mobs are affordable. Coarser = cheaper but can miss narrow ledges → watch the
-- "[NavBake] CONNECTIVITY" log: it should stay 1 component. Drop to 3 if a thin path gets skipped.
Config.Nav = {
    SPACING = 4,

    -- MAX_STEP = tallest step (studs) a mob walks UP/DOWN as a normal TWO-WAY link (grid + bridge). The
    -- bake default (spacing+1 ≈ 5) was too small for this map's ramp/ledge seams (a wedge slab sitting on
    -- a plane makes a ~6-12 stud lip), so those junctions never linked and the wedge became its own
    -- island. 12 lets mobs step those seams both ways; taller falls still go through the one-way DROP
    -- pass. (A spherecast still blocks stepping through an actual wall.)
    MAX_STEP = 12,

    -- FLOOD_RADIUS = how far (studs) the flow flood expands from a player before it stops. This is the
    -- MMO trick: mobs only path PRECISELY within this disk; farther mobs head loosely toward the player
    -- until they enter it. Because Dijkstra pops in distance order, the flood early-outs the instant it
    -- passes the radius → cost depends on the ACTIVE region, NOT the whole map, so you could even run a
    -- DENSE (spacing 2) navmesh affordably. 0 = unbounded (flood the whole reachable graph — the current
    -- single-arena behaviour). Set e.g. 350 to bound it once mobs spawn close enough to the player.
    FLOOD_RADIUS = 0,

    -- ONE-WAY DROP edges: a mob this many studs ABOVE a nearby node can fall to it (no fall damage here,
    -- so be generous). The bake default of 24 was too small to link this map's level gaps (tens of studs
    -- between bands), so mobs couldn't drop off tall ledges — they'd path around or stall. 80 covers them.
    MAX_DROP = 80,

    -- DROP_RADIUS = how far HORIZONTALLY a drop reaches to find the lower node it lands on. The bake
    -- default (spacing*1.5 ≈ 6) was too tight to span a cliff junction — e.g. Bugg2's lowest ledge node
    -- (~Y123) to the Y~94 plane below sit a touch more than 6 studs apart across the face, so no drop
    -- edge formed and the surfaces stayed disconnected. 10 spans it. (Down only — climbing 30 studs back
    -- up needs an actual ramp in the map; a one-way drop just lets mobs follow a player DOWN off Bugg2.)
    -- This is how far OUTWARD the drop search walks from a ledge edge to find the surface below, so it
    -- must clear the cliff face's horizontal run — 16 spans wider faces (was firing only at corners).
    DROP_RADIUS = 16,
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
