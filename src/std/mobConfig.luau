-- std/mobConfig.luau
-- Mob tunables (server sim + client render) and the client rig's locomotion animation ids. ONE place,
-- read by BOTH systems/mobs (server) and ClientSystems/mobs (client), so they can never disagree.
--
-- First slice = a fixed test pack of chasers on a FLAT arena (Tier 0 in CLAUDE.md terms: no ground
-- casts, constant Y). Real wave spawning + ground/collision shell come later.
--!strict

local M = {}

-- ── Spawn / population ───────────────────────────────────────────────────────────
M.TEST_COUNT   = 20                       -- mobs spawned at boot for testing
M.SPAWN_RADIUS = 60                       -- ring radius they spawn on, around SPAWN_ORIGIN
M.SPAWN_ORIGIN = Vector3.new(0, 5, 0)     -- flat-arena spawn height (no ground cast yet)
M.SPAWN_DELAY  = 1.5                      -- seconds after boot before spawning (lets clients register the rig)
M.HP           = 25                        -- horde mobs die fast: ~2-3 light hits or 1 heavy (light 8, heavy 28)

-- ── Waves (survival loop — the self-running scale demo) ────────────────────────────
-- A wave state machine: ramp a wave in over a few seconds, let the player clear it, short breather, then
-- the next (bigger) wave. Server-driven (systems/mobs), spawned around the player, broadcast to the client
-- HUD (ClientSystems/waveHud) over CombatRemote. Toggled from the dev panel. Reuses the OLD wave DESIGN
-- (_legacy/SpawnMob) against the NEW spawnMob/Blink pipeline.
M.WAVE = {
	BASE          = 30,    -- wave-1 mob count
	GROW          = 22,    -- +mobs each subsequent wave
	MAX           = 1500,  -- per-wave cap (keeps it under the ~2k comfort ceiling)
	RADIUS        = 55,    -- spawn ring radius around the player (they close in from around you)
	SPAWN_EVERY   = 0.22,  -- seconds between spawn batches (the ramp-in, not one instant dump)
	SPAWN_BATCH   = 20,    -- mobs per batch
	BREATHER      = 4,     -- seconds between a cleared wave and the next
	MAX_WAVE_TIME = 90,    -- force-advance if a wave isn't cleared in this long (no soft-lock on a straggler)
	BCAST         = 0.4,   -- how often the wave state is pushed to the HUD (wave/kills/alive/timer)
}

-- ── Movement (DIRECT reactive steering — no navmesh/flow-field, per CLAUDE.md) ────
M.SPEED       = 9                         -- studs/sec chase speed (old ZOMBIE_SPEED)
M.MOVE_TICK   = 1 / 20                    -- sim rate (AI ~20hz, not per-frame)
M.CONTACT     = 3                         -- stop steering within this XZ of the target (melee range)
M.HITBOX_SIZE = Vector3.new(2, 5, 2)      -- server hitbox part size

-- ── Vertical / launches (juggling) ────────────────────────────────────────────────
-- Mobs are kinematic (CLAUDE.md: living mobs never touch the PGS solver), so "gravity" is just float
-- integration on our own vy: vy -= GRAVITY*dt, clamped back onto the mob's ground Y on landing.
-- LOWER = floatier = longer juggles. Roblox's own gravity is 196.2; mobs are deliberately floatier so air
-- combos have hang time. This is THE juggle-feel knob — pair it with combatConfig `lift` per attack.
-- (Launch speed is capped by the net lane's ~95 studs/sec ceiling — see config.luau Net.STEP.)
M.GRAVITY = 90
-- KNOCKBACK travel = combat `knock` (studs/sec) decayed at this rate. Total distance ≈ knock / KNOCK_DECAY,
-- so this is the "how far knockback throws" knob: LOWER = mobs slide further per point of knock. Was 6
-- (which made knock feel like almost nothing — knock 8 only threw ~1.3 studs); 4 ≈ doubles the throw.
M.KNOCK_DECAY = 4
-- ── Air-heavy SLAM grab ─────────────────────────────────────────────────────────
-- The slam CATCHES mobs and drags them down with you, then scatters them on landing.
M.SLAM_DRAG    = 90   -- studs/sec a grabbed mob is dragged straight DOWN (≈ the player's dive speed)
M.SLAM_SCATTER = 60   -- radial knock (studs/sec) flung outward from the slam point on landing (÷KNOCK_DECAY
                      -- = ~15 studs of scatter). This is the "shockwave", so it's punchy.
M.SLAM_GRAB_MAX = 4.5 -- SAFETY: auto-release a grab after this long if the land signal never arrives
                      -- (client disconnect mid-slam) so mobs can't get frozen mid-air forever. Kept a full
                      -- ~2s ABOVE combatConfig.SLAM.MAX_DIVE (2.5) so even a jitter-delayed forced slamland
                      -- still finds the grab live and fires the scatter + crater.
-- (no TURN_RATE: the server streams POSITION only and doesn't compute facing — the client eases its own
--  heading at HEADING_RATE below.)

-- ── Separation (positional relaxation — the anti-pile / anti-spin) ─────────────────
-- Separation is applied as a CLAMPED POSITION PUSH (studs/sec), NOT folded into the steering vector.
-- Two reasons: (1) it reliably keeps mobs spaced at every distance (the "always spacing" you want), and
-- (2) it never drives FACING, so a mob shoved by a neighbour no longer TURNS toward the shove — that
-- turning-to-face-the-jostle was the spin you saw when mobs collide with each other.
M.SEP_RADIUS = 3.2    -- push mobs apart within this XZ distance (≈ hitbox width + a little air)
M.SEP_PUSH   = 5      -- studs/sec per unit of clamped neighbour weight. EFFECTIVE MAX push = SEP_CLAMP ×
                      -- SEP_PUSH. Was 7 with CLAMP 1.5 → max 10.5, STRONGER than chase SPEED (9): mobs got
                      -- shoved apart harder than they walked in → the violent never-settling crowd churn.
                      -- 5 × 1.0 = 5 < 9, so the chase now wins and a pack SETTLES instead of jostling.
M.SEP_CLAMP  = 1.0    -- cap on the accumulated neighbour weight (a mob with many neighbours doesn't get an
                      -- N× push). With SEP_PUSH 5 this caps the real max separation speed at 5 studs/sec.

-- FACING is now CLIENT-DERIVED (from the streamed motion) — the custom net lane streams POSITION only
-- (no yaw), so the server no longer computes mob facing. Each client eases a heading toward the mob's
-- velocity (LOD_* / HEADING_RATE below), which both orients the rig and damps separation jitter.
-- ANTI-ORBIT: within ORBIT_BAND of the player, damp the component of motion PERPENDICULAR to the
-- player direction by ORBIT_DAMP. Stops a packed ring of mobs (mutual separation) from circling the
-- player — the "spinning swarm" — while still letting them press inward. 0 = off, 1 = kill all swirl.
M.ORBIT_BAND  = 16
M.ORBIT_DAMP  = 1.0   -- fully remove the circling component near the player (0.85 still left a slow spin)
-- SETTLE: once basically in melee range, scale a mob's movement WAY down so it plants and (later)
-- attacks instead of shuffling/orbiting. Applied within CONTACT + SETTLE_PAD studs.
M.SETTLE     = 0.15
M.SETTLE_PAD = 2

-- ── Arrival + SURROUND (anti-stack, anti-queue) ────────────────────────────────────
-- Separation alone CAN'T fix a dense stack: it's a sum of neighbour pushes, so a mob buried in a symmetric
-- pile feels ~zero net force (pushes cancel) and never clears. And if separation is weaker than chase SPEED,
-- the inward steer just compresses everyone onto the player's point. So: a mob is BLOCKED once another mob is
-- AHEAD of it (toward the player) AND closer to the player — it has reached the back of the crowd. A blocked
-- mob does NOT just stop (stopping queues them into a wedge trailing the player) — it FLOWS TANGENTIALLY
-- around the player toward the OPEN side (`BLOCK_FLOW`), so mobs spread out and SURROUND instead of lining up.
-- The open direction = the tangential part of the separation vector (perpendicular to the player-radial,
-- pointing at the less-crowded arc); it fades to 0 when the ring is even, so mobs settle rather than spin.
-- Purely spatial (neighbour positions, NOT the mob's own velocity → can't deadlock like the speed-based plant),
-- and the CLOSEST mob is never blocked, so the front always presses and a kill instantly frees the mob behind.
M.BLOCK_RADIUS = 4.2  -- a neighbour within this XZ distance AND ahead counts as blocking (≈ the rank gap)
M.BLOCK_CONE   = 0.5  -- cosine of the "ahead" half-angle: 0.5 = ±60°. Higher = narrower cone = blocks less
                      -- readily (tighter ranks / more press); lower = wider = mobs hold back / flow sooner.
M.BLOCK_FLOW   = 0.6  -- blocked mobs flow tangentially at this × SPEED toward the open arc (the SURROUND).
                      -- Higher = mobs wrap around faster (can look frantic); 0 = they just stop (old queue).

-- ── Rig ──────────────────────────────────────────────────────────────────────────
-- The client rig's CENTRE/root part name — Chrono drives THIS part (sets its CFrame each frame) and
-- anchors it; the rest of the body follows via Motor6D. Your rig has no HumanoidRootPart, so set this
-- to whatever its root part is actually called ("root", "Root", "RootPart", …). If PrimaryPart is
-- already set on the rig, that wins; otherwise this name is tried, then common fallbacks.
M.ROOT_NAME = "root"

-- Ground: mobs are spawned onto the floor by a downward raycast at spawn (flat arena → Y then held).
-- FOOT_OFFSET lifts the mob CENTRE above the floor hit so the rig's FEET sit on the ground — tune it
-- until the rig stands correctly (≈ half the rig's height; the hitbox is HITBOX_SIZE.Y tall).
M.FOOT_OFFSET = 2.5

-- ── Ground / wall collision (raw-map FIRST PASS — the CLAUDE.md keystone, minus the collision shell) ──
-- Mobs cast against the RAW map geometry (a shared RaycastParams that excludes players + rock/voxel
-- debris). This is the "works on a real map" step, NOT the scaling answer: sweeping DETAILED visual
-- geometry is pricier than the eventual simplified invisible collision shell (clean boxes/wedges) that
-- mobs will sweep instead. Set either flag false to fall back to Tier-0 flat arena (spawn-cast Y, no walls).
M.GROUND_CAST     = true  -- live ground-follow: re-cast the floor as a mob moves (false → hold spawn Y)
M.GROUND_RECAST_D = 3     -- re-cast the floor only after a mob moves THIS far in XZ. Idle mob = 0 casts
                          -- (CLAUDE.md: never raycast at sim rate — gate by a movement threshold).
M.STEP_HEIGHT     = 2.5   -- step-up tolerance: a rise ≤ this is a walkable STEP. Sets the wall-probe box
                          -- BASE (a face below this isn't a wall) and the grounded Y-ease target, so a low
                          -- ledge is walked onto but a taller face reads as a wall. ~half the hitbox height.
M.CLIMB_REACH     = 5     -- how high above the FEET the ground down-ray STARTS. Must exceed the surface
                          -- rise a mob covers between re-casts on the steepest walkable ramp
                          -- (GROUND_RECAST_D × tan(acos(WALL_STEEP)) ≈ 3 × 1.52 ≈ 4.6) or the ray starts
                          -- BELOW the slope ahead, misses, and the mob burrows into the ramp. Independent
                          -- of STEP_HEIGHT (which still gates steps via the wall box), so raising this does
                          -- NOT let mobs climb walls — the down-ray only sees what's under their own XZ.
M.GROUND_DOWN     = 200   -- how far BELOW the feet to search for the floor. Generous so any real map drop
                          -- is found (a found floor below → the mob falls to it via gravity); a genuine
                          -- MISS = a void deeper than this → the mob falls and KILL_Y recycles it.
M.GROUND_SNAP     = 14    -- studs/sec the Y eases toward the recast ground when grounded — a SOFT step-up
                          -- so climbing a ledge isn't an instant teleport. High = snappy, low = floaty.
M.KILL_Y          = -300  -- a mob whose Y falls below this has left the playable area (fell in a void with
                          -- no floor within GROUND_DOWN) → silently despawned. Set well below the map floor.

M.WALL_CAST     = true  -- shapecast the footprint along the move + slide along walls (false → pass through)
M.WALL_STEEP    = 0.55  -- a hit is a WALL only if its surface normal.Y < this (steeper than ~57°). Gentler
                        -- slopes are walkable RAMPS — not blocked; the ground recast walks the mob up them
                        -- (CLIMB_REACH must cover the band up to this, else steep-but-walkable ramps burrow).
                        -- NOTE (first-pass limits): one slide iteration (corners can nick), only GROUNDED
                        -- mobs wall-check (a knocked/juggled mob can pass a wall), a mob drops STRAIGHT off
                        -- ledges (no momentum arc yet), and casts hit raw CanCollide geometry — no collision
                        -- shell yet. Fine for a test map; the shell is the scaling + correctness answer.
M.WALL_MIN_MOVE = 0.15  -- SKIP the wall cast when a mob's intended per-tick move is below this (studs).
                        -- The settled melee ring keeps a small nonzero residual (SETTLE scales, never
                        -- zeroes) — without this gate the densest cluster of mobs each shapecasts every
                        -- tick for a move that can't traverse anything. 0.15/tick ≈ 3 studs/sec: a charger
                        -- (SPEED 9 → 0.45/tick) casts, a planted ring mob (~0.075/tick) skips.

-- ── Reactions / death ─────────────────────────────────────────────────────────────
-- Hit reactions reuse the shared base-set clips in std/animConfig (same R15 skeleton): hit1..HIT_COUNT
-- (a random one per hit) and knockdown (the death "send-flying" corpse).
M.HIT_COUNT  = 5
-- The clip a mob plays when it ATTACKS the player. Reuses a real swing from combatConfig (the player's
-- light-1 attack) so it reads as a strike, not a flinch/dash. Swap for a dedicated mob-attack clip when one
-- is authored; 0 = no attack animation. (Kept as a plain id here to avoid a mobConfig↔combatConfig require cycle.)
M.ATTACK_ANIM = 100703610993646
M.DEATH_FLING = 45  -- studs/sec the corpse is launched (scaled by the killing knock direction)
M.DEATH_TTL   = 3   -- seconds before the death corpse despawns
M.DEATH_CAP   = 25  -- max concurrent death corpses (oldest recycled) — CLAUDE.md ragdoll cap

-- ── Replication + render LOD (custom Blink dense-slot lane; wire constants live in std/config.luau Net) ──
-- Mobs stream through our OWN Blink lane (i8 slot-ordered deltas + periodic f32 snapshot), NOT Chrono.
-- The client interpolates + renders at two quality tiers by distance to the LOCAL player.
M.LOD_NEAR      = 45    -- ≤ this XZ distance → FULL animated rig (Animator, walk/run). Beyond → cheap pooled rig
M.LOD_HYST      = 12    -- hysteresis: promote to near under LOD_NEAR, demote to far only past LOD_NEAR+this
M.NEAR_CAP      = 60    -- HARD CAP on concurrent ANIMATED (near) rigs — the client cost is the ENGINE posing
                        -- N Animators/frame, so cap N regardless of how many are inside LOD_NEAR. Mobs past
                        -- the cap use the Animator-free far/procedural rig even when close (slight quality
                        -- hit up close in a huge swarm; the horde still moves right). Set very high to
                        -- disable the cap (old behaviour). DIAGNOSTIC: set LOD_NEAR=0 → ALL far, ZERO
                        -- Animators; if the client frame time collapses, the Animator count was the cost.
M.LERP_RATE     = 16    -- interpolation rate toward the streamed target (smooths the ~15Hz net)
M.HEADING_RATE  = 8     -- how fast a mob's facing eases toward its pursuit dir (damps i8-delta jitter)
M.MOVE_EPS2     = 0.02  -- min planar pursuit-gap² to update facing (a mob at its target keeps its heading)
M.FAR_WALK_FREQ = 9     -- far-tier procedural leg-swing rate (no Animator out there — scales to the horde)
M.FAR_WALK_AMP  = 0.5   -- far-tier leg-swing amplitude (radians)
M.FAR_LEGS      = false -- procedural far-tier leg swing. OFF by default: each mob's swing is TWO Motor6D
                        -- CFrame writes/tick, and every such write is a separate Lua→engine ($newindex)
                        -- LuaBridge crossing — at 1000+ mobs that (not rendering, not Animators) was THE
                        -- client hot-path (2 × N writes/frame). The roots already move in ONE BulkMoveTo;
                        -- a distant mob sliding without leg wiggle is a fine trade. Turn on only if the
                        -- horde is small. (Near-tier mobs still have full Animator legs.)

-- DEBUG_NET: when true, BOTH ends print a once/sec SEAM summary — the fastest way to tell which of the
-- three layers (net stream → interpolation → LOD render) is misbehaving, instead of guessing:
--   server → `[mobs/net] N mobs | delta X B/s | full Y B/s | TOTAL Z KB/s`  — the REAL bandwidth, measured
--            off the actual packed payload. This is what verifies the ~26 KB/s @ 500 target.
--   client → `[mobs/cli] live=N near=A far=B | swaps=C/s` + one-shot "first delta/full applied" markers,
--            so a silent stream (no deltas) vs a stuck renderer (deltas fine, nothing moves) is obvious.
-- Leave OFF in normal play — it's a diagnostic, not telemetry.
M.DEBUG_NET = false

-- ── Client rig locomotion animation (NEAR tier only — the far tier has no Animator) ─────────────────
-- Mobs reuse the shared base-set clips (std/animConfig) on the same R15 skeleton, speed-synced: slow → walk,
-- fast → run, playback scaled to actual speed (no foot-slide). Only FORWARD clips are needed — the client
-- faces each mob along its own motion, so movement is always "forward" relative to its facing. (That's what
-- kills the moonwalk; a strafe/backpedal set would only matter if facing were decoupled from motion.)
-- Set a key to a non-zero rbxassetid for mob-specific loco; 0 = fall back to the animConfig base clip.
M.ANIM = {
	idle  = 0,
	walkF = 0,
	runF  = 0,
}
M.WALK_REF   = 6    -- studs/sec the WALK clip is authored at (playback scales vs this → no foot-slide)
M.RUN_REF    = 10   -- studs/sec the RUN clip is authored at
M.RUN_START  = 4    -- planar speed where walk→run blending begins
M.RUN_FULL   = 6.5  -- planar speed where the blend is 100% RUN. Kept BELOW chase SPEED (~9) on purpose:
                    -- the client measures speed from the interpolated root, which reads a touch low, so a
                    -- charging mob must still land at FULL run weight — otherwise walk dilutes the run pose
                    -- (its forward lean). If a charging mob STILL won't lean, the lean likely lives in the
                    -- clip's ROOT motion, which we override (we drive the root) — see the doc.
M.BLEND_RATE = 12   -- 1/sec — how fast clip weights ease toward targets

return M
