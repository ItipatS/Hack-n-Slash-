-- std/config.luau
-- Central runtime config for the pieces that still read a shared table:
--   • Config.Net   — mob replication tunables (read by systems/mobs + ClientSystems/mobs)
--   • Config.Debug — Logger.debug() passthrough
-- (The old showcase-place, spawn/UFO, navmesh and mobile-control blocks were pruned with the
--  Vampire-Survivors → Hack&Slash pivot; gameplay tunables now live in std/mobConfig + std/combatConfig.)
--!strict

local Config = {}

-- ── Debug ─────────────────────────────────────────────────────────────────────────
Config.Debug = {
    -- Logger.debug() passthrough (off = debug logs suppressed). Always-on for info/warn/error.
    LOG_DEBUG = false,
}

-- ── Mob replication (dense-slot + i8 deltas) — read by systems/mobs + ClientSystems/mobs ─
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

return Config
