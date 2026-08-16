# Hack&Slash — Implementation Status

**What this documents:** the CURRENT built state of the pivot (as of 2026-08-16, through iter 13 — ground/wall
detection, client crowd perf, arrival/hold-back, and a full gameplay layer: waves, damage numbers, mob health
bars, mob→player attacks, XP + level-up cards, real upgrade effects, a real pause). `CLAUDE.md` describes the *target* design and
is partly aspirational; THIS file describes what actually exists in code. When they disagree, this file wins
for "what's implemented," CLAUDE.md wins for "what we're aiming at."

> **CLAUDE.md is now WRONG / stale on several load-bearing points — it needs a rewrite:**
> 1. *"Do NOT implement server-authoritative player movement…"* — obsolete: Roblox shipped **Server
>    Authority** (full release, Jul 2026) which does exactly that natively, for free. See "Replication".
> 2. **Mob hitboxes live in `ServerStorage`, NOT "in Workspace under a Camera."** CLAUDE.md's Camera-trick
>    is not used. Why it's fine: living mobs are kinematic (Anchored, we set CFrame — the solver never
>    touches them, by design), and a raycast against `workspace` works from *anywhere* — the ServerStorage
>    hitbox is just a CFrame holder + a query origin; the map is in Workspace where our own casts reach it.
>    ServerStorage suppresses replication for free, so the Camera trick is unneeded and the "does the solver
>    step a Camera-parented part?" open question is moot.
> 3. **Consequence to remember:** because we do collision via our OWN casts, **collision only exists where
>    we cast.** The engine isn't colliding mobs. So mobs phase through anything we don't check (aloft/knocked
>    mobs skip the wall cast; no ceiling cast; `CanCollide=false` map parts are ignored). "It phases through"
>    = a coverage gap, not an engine failure.
> 4. **Client is the real scaling ceiling, not the server.** ~500-mob wall was CLIENT LuaBridge property
>    writes (see CLIENT CROWD PERF), independent of the PGS-vs-kinematic choice. Given the client can't draw
>    thousands anyway, "hundreds of great-looking mobs" is the honest target — at which scale using real PGS
>    for the near/collision-critical mobs is viable (open design call, not yet taken).

The repo is the old vampire-survivors horde game being rebuilt into a **Devil-May-Cry-like hack & slash**.
Roughly half the old systems remain usable (ECS/jecs, scheduler/phases, Blink, drops/meta); the horde
streaming machinery is parked in `_legacy/` folders (NOT loaded — the `start()` loader skips them).

---

## Boot flow

- **Server** `ServerScriptService/main.server.luau` — staged boot, each stage prints `[boot +Ns]`:
  1. wait for `Packages`
  2. `std.Nav.init()` (navmesh parked; `USE_NAVMESH=false` → hand-painted PathData)
  3. Framework data layer (ProfileStore)
  4. *(was Chrono — REMOVED, see Replication)*
  5. `start(systems)` — requires every `systems/*.luau`, which creates the Blink remotes + `CombatRemote`
  6. sets `ReplicatedStorage.ServerReady` → clients may init
- **Client** `StarterPlayer/StarterPlayerScripts/main.client.luau` — polls for `ServerReady`, then
  `start(ClientSystems)`.
- `std/start.luau` requires each ModuleScript in the folder, then `scheduler.COLLECT()` + `scheduler.BEGIN()`.
- Systems register via `scheduler.SYSTEM(fn, phase)`; phases live in `std/phases.luau`
  (PreSimulation / PreAnimation / PreRender / Heartbeat + a game-phase chain).

---

## Replication — CHRONO IS GONE. Players = Roblox's own; mobs = our Blink dense-slot lane

**Chrono was deleted entirely (iter 7).** It lost both of its jobs, in order:
1. **Mobs left (iter 6)** — its general-purpose format cost 16 bytes/mob at a flat 20 Hz with no LOD
   (~160 KB/s per player at 500 mobs). Doesn't scale to the horde target.
2. **Players left (iter 7)** — Roblox shipped **Server Authority** (full release, Jul 2026), which gives
   `NextGenerationReplication` **plus client prediction + rollback** natively. Chrono existed to fix
   *replication unpredictability* (mushy default 20 Hz + fixed mobile interp delay); the engine now does
   that, better, for free. It was also actively **harmful**: `NATIVE_WITH_LOCK` welds the character under a
   Camera to suppress Roblox replication, which fights a server-authoritative character (**symptom: the
   character can't move**). `std/chronoConfig.luau` is now a tombstone; nothing requires it.

**Server Authority** is opt-in via `Workspace.AuthorityMode = "Server"`, which force-enables
`NextGenerationReplication`, `PlayerScriptsUseInputActionSystem`, `SignalBehavior=Deferred`,
`StreamingEnabled` and `UseFixedSimulation`. Tested to work without a migration. **If we ever do lean on it
harder, these bite us** (all verified from the docs, none of it done):
- Custom ability logic must run in `RunService:BindToSimulation()` **identically on client AND server** —
  the client is NOT demoted to visuals; it runs the same sim to predict.
- **Cached `AnimationTrack` handles are invalidated by rollback** — we cache tracks in `playerAnim`,
  `combat` and `mobs`; the sanctioned pattern is `Animator:GetTrackByAnimationId()`.
- Input must go through the **InputAction system** (we use `UserInputService` + `ContextActionService`), and
  camera moves to `Player:GetCameraState()`.

**Mobs → our own Blink dense-slot lane** (schema in `Net.blink`, constants in `std/config.luau` `Net`),
streaming **~3 bytes/mob**:
- `Spawn` (reliable): id (u32 netId) + dense `slot` + pos/size/type/tier → client acquires a rig.
- `UpdateTransformDelta` (unreliable): **i8 fixed-point position deltas in SLOT order, NO per-mob id** — the
  bulk of the bandwidth (`CHUNK`=256 slots/packet, `NET_TICK`=1/15).
- `UpdateTransformFull` (reliable): absolute f32 snapshot every `FULL_EVERY`=2.5 s (clears drift + slot
  churn) + the fallback for a per-tick jump past `WARP_THRESH`.
- `Death` (reliable, silent clears) / `CombatRemote "mobdeath"` (normal death: release rig + flung corpse).
- **~500 mobs ≈ 26 KB/s** vs Chrono's 160. Positions only — no yaw on the wire (client derives facing).

### ⚠️ `STEP` is the lane's VELOCITY CEILING — not just precision
`±127 × STEP` studs per tick ÷ `NET_TICK` = the fastest a mob can *possibly* stream. At `STEP=0.05` →
**~95 studs/sec**. This must clear the fastest thing a mob does, which since iter 8 is **launch speed, not
walk speed** (a high launcher is 60). It was 0.02 (**38 studs/s**) — below launch velocity.
**`WARP_THRESH` MUST stay ≤ `127 × STEP`** (the real i8 capacity) or the "too fast → send an absolute"
escape hatch never fires and the code silently `math.clamp`s instead — a launched mob rises in **slow
motion** then pops at the next FULL snapshot. It was 25 (10× the i8 range) — exactly that latent bug.

---

## Mobs

Per-mob = an ECS entity + a bare anchored **hitbox part under `ServerStorage`** (never replicates → clients
build their own rigs; still a real CFrame for the sim + combat OBB). Position streams over the Blink lane;
the client renders it at one of two LOD tiers.

- **Server** `ServerScriptService/systems/mobs.luau`
  - Hitbox part is Anchored + `CanCollide/CanQuery=false`, parented under `ServerStorage/MobHitboxes`.
  - **Slot allocator** (reuse freed slots → dense range) + a monotonic **u32 netId** (the Spawn/Death/
    mobhit key; the slot is only the position-stream index). `MobRegistry.register(netId, part, e)`.
  - Spawns `TEST_COUNT` at boot; also spawns/clears from the dev panel (now up to 2000). Each spawn
    **ground-snaps** via a downward raycast (`groundY`) + `FOOT_OFFSET`; the sim then re-casts as it moves
    (see GROUND/WALL below).
  - Sim (`PreSimulation`, ~20 hz): chase nearest player + **positional-relaxation separation** (clamped
    `SEP_PUSH`/`SEP_CLAMP` push) + **arrival/hold-back** + **anti-orbit** + **settle** + knockback +
    **vertical** + death pass. **Position only — the server no longer computes facing** (yaw isn't streamed;
    the client derives it).
  - **ARRIVAL / hold-back (iter 11 — the anti-stack) — `BLOCK_RADIUS`/`BLOCK_CONE`.** Separation ALONE can't
    stop 500 mobs stacking on the player: it's a *sum* of neighbour pushes, so a mob buried in a symmetric
    pile feels ~0 net force (they cancel) and never clears; and if `SEP_PUSH` < chase `SPEED` the inward steer
    just compresses everyone onto the player's point. So while summing separation, each mob also checks *is a
    neighbour AHEAD of me (toward the player) AND closer to the player?* — if so it has reached the back of
    the crowd and **cuts its inward steer to 0** (holds rank; separation still spaces it laterally). Mobs
    queue into **concentric ranks growing outward** instead of piling. Purely spatial (neighbour positions,
    NOT the mob's own velocity — a velocity-based version deadlocked: planting drops the velocity that would
    un-plant it), and the CLOSEST mob is never blocked, so the front always presses and a kill instantly
    frees the mob behind. Tune `BLOCK_RADIUS` (rank gap) / `BLOCK_CONE` (how eagerly they yield). PENDING a
    Studio playtest. **NOTE:** `SEP_PUSH`/`SEP_CLAMP` were dropped to 5/1.0 chasing this via tuning first —
    that just traded churn for stacking (the lesson above); the real fix is arrival, and the sep values now
    only govern lateral rank spacing.
  - **VERTICAL / launches (iter 8).** Mobs are no longer flat-Y. `Velocity.Y` is real vertical velocity
    (the component was previously written-but-never-read, so repurposing it broke nothing), integrated
    kinematically — `vy -= GRAVITY*step` — and clamped back onto `groundYOf[e]`, the mob's ground Y.
    - **`aloft` = HITSTUN.** A launched mob **stops steering, separating, anti-orbiting and settling** until
      it lands — otherwise it helicopters at you mid-juggle instead of arcing. Only gravity + its decaying
      horizontal knock apply, which *is* the launch arc.
    - Combat launches by writing `Velocity.Y = atk.lift`. **Negative `lift` = SLAM** (the air heavy spikes
      mobs into the floor) — same path, both directions.
    - `mobConfig.GRAVITY` (90) is THE juggle-feel knob — deliberately floatier than Roblox's 196.2 so air
      combos have hang time. `apex = lift²/(2*GRAVITY)`, `hang = 2*lift/GRAVITY`.
  - **GROUND / WALL detection (iter 10 — raw-map first pass).** `groundYOf[e]` is no longer spawn-fixed;
    the sim follows terrain + stops at walls, still honouring "never cast at sim rate." Toggle either half
    with `mobConfig.GROUND_CAST` / `WALL_CAST` (both off = the old Tier-0 flat arena).
    - **Gated ground re-cast.** A mob re-casts the floor (down-ray from `feet + CLIMB_REACH`) only after it
      travels `GROUND_RECAST_D` (3 studs) from its last cast — **idle mobs cast 0 rays.** `CLIMB_REACH` (5)
      is decoupled from `STEP_HEIGHT` so it exceeds the surface rise per re-cast on the steepest *walkable*
      ramp (`GROUND_RECAST_D·tan(acos(WALL_STEEP))≈4.6`); if it didn't, ramps in the ~40–56° band would be
      neither climbed nor blocked and the mob would **burrow** into them (the review's MEDIUM bug).
    - Grounded Y **eases** toward the re-cast ground at `GROUND_SNAP` (soft step-up onto ledges, no
      teleport). A floor found *below* just lowers `gy` → `aloft` flips true → the mob falls via the gravity
      path (normal ledge-drop). No floor within `GROUND_DOWN` (200) → `gy = -inf` sentinel → the mob falls
      and `KILL_Y` (-300) silently recycles it (fixes mobs air-walking over deep voids).
    - **Wall shapecast + slide.** One `Blockcast` of a torso-band footprint box (`WALL_BOX`, based above
      `STEP_HEIGHT` so low steps aren't walls) along the intended move; a hit with `normal.Y < WALL_STEEP`
      (~57°) slides by removing the into-wall component (walkable ramps pass through). **Gated by
      `WALL_MIN_MOVE`** so the settled melee ring — which keeps a small nonzero residual (`SETTLE` scales,
      never zeroes) — skips it; without that gate the densest cluster shapecast every tick (the review's
      **HIGH** perf bug).
    - **One shared `RaycastParams`** (`worldParams`, `RespectCanCollide=true` so only solid geometry counts)
      excludes players + rock/voxel debris folders; rebuilt on the player set + a 1 s cadence.
    - Per-mob writes are now **movement-gated** (`part.CFrame` / `Velocity` skipped when `nx/ny/nz` didn't
      change) → a field of idle mobs does 0 allocs/writes, matching the idle=0-casts design.
    - **First-pass limits (documented in `mobConfig`):** casts hit *raw* CanCollide geometry (pricier than
      the eventual simplified collision shell — the scaling answer), single slide iteration (corners nick),
      only grounded mobs wall-check (a knocked/juggled mob can pass a wall), and a mob drops **straight** off
      ledges (no momentum arc yet — deferred LOW).
  - Net sender (`NetworkDelta`): `sendDeltas` (i8 slot-ordered chunks) every `NET_TICK`, `sendFull`
    (absolute snapshot) every `FULL_EVERY`; `lastSent[slot]` accumulates the quantized position so summed
    i8 deltas never drift. Late-joiners get a `Spawn.Fire(player, …)` replay on `PlayerAdded`.
  - Death → `despawnMob`: normal = `CombatRemote "mobdeath"(netId, cf, fling)`; silent clear = `Death({netId})`.
  - `std/mobRegistry.luau` maps netId / hitbox part ↔ ECS entity (`chronoIdOf` now returns the netId —
    stale name, unchanged API so combat needs no edit).
- **Client** `ClientSystems/mobs.luau` — Blink receiver (`Spawn`/`UpdateTransformDelta`/`UpdateTransformFull`/
  `Death`) → `mobs[netId]` records + a `slotToNet[slot]` map; integrates deltas, interpolates `renderPos`
  toward `target` (`LERP_RATE`), and **derives facing** from the motion (eased `heading`, `MOVE_EPS2`
  damps jitter — no yaw on the wire).
  - **Render-LOD, now NEAREST-N (iter 11)** — the animated (NEAR) tier is the **`NEAR_CAP` mobs CLOSEST to
    the local player**, not "whoever crossed `LOD_NEAR` first." Each anim tick a pre-pass sorts all mob
    distances → `nearIn2` (the `NEAR_CAP`-th nearest d², capped at `LOD_NEAR²`) / `nearOut2` (a looser rank →
    rank hysteresis so the boundary doesn't thrash tiers). Swaps go through the pooled rigs.
    - **NEAR** — a **pooled animated rig** (Humanoid/Animator kept, Animate disabled; `nearFree` pool keeps
      the loaded tracks alive across swaps). Forward-only gait (idle/walkF/runF — facing == motion, so no
      moonwalk), speed→gait + speed→playback. Root CFrame set directly to `lookAt(renderPos, +heading)`.
    - **FAR** — a **cheap `MobRenderPool` rig** (stripped: no Humanoid/scripts/mesh) moved in bulk via
      `BulkMoveTo`. Procedural leg-swing exists (`FAR_WALK_FREQ/AMP`) but is **`FAR_LEGS`-gated and OFF by
      default** — see the perf note. No Animator.
  - **CLIENT CROWD PERF (iter 11) — the ceiling was LuaBridge property-WRITE count, nothing else.** Profiled
    on an R5 5600X/RX 5700XT: ~500 mobs = ~32 ms "nonstop." Microprofiler pinned it to **`$newindex`, Group
    LuaBridge, Call Count ≈ mob count, labels CFrame/Part** — i.e. the raw number of individual Instance
    property writes crossing Lua→C++ each frame. NOT rendering (triangles trivial), NOT Animator eval, NOT
    server physics. Proven by elimination (dropping the gait `Adjust*` calls to 20 Hz did nothing; all-far,
    zero-Animator, was still 32 ms). **Culprit + fix:** the far leg-swing wrote 2 `Motor6D.Transform` per mob
    per tick (~975 × 2 = 1949 writes/frame); the roots were already batched by one `BulkMoveTo`, the legs were
    not → **`FAR_LEGS = false`** = "much better." **The rule:** move many parts with ONE `BulkMoveTo`, NEVER a
    per-mob loop of `.CFrame`/`.Transform` writes. Two smaller levers also in: (1) **rate-split** — motion
    (lerp/CFrame) every frame, animation CONFIG (gait `AdjustWeight`/`AdjustSpeed`, LOD, far legs) at
    `ANIM_TICK` ~20 Hz + **skip-unchanged** (`W_EPS`/`S_EPS`, `sentW`/`sentSpeed`) so a steady mob makes ~0
    Animator calls; (2) **`NEAR_CAP`** bounds the Animator count. `BulkMoveTo` has no "None" mode —
    `FireCFrameChanged` is the lighter of the two and ~free with no listeners; the mode was never the cost.
  - Hit reaction (NEAR only): `CombatRemote "mobhit"` (netIds) → random `animConfig.SETS.base.hit1..N`.
  - Death: `Death` (silent) or `"mobdeath"(netId, cf, fling)` (normal) → release the rig; normal also spawns
    a transient flung `knockdown` corpse (Debris `DEATH_TTL`, capped `DEATH_CAP`). Rigid-body fling, not ragdoll.

---

## Player + Combat

- **Locomotion** `ClientSystems/playerAnim.luau` (pre-existing, working): 9-track weight-blended
  directional loco (idle + walk/run × F/B/L/R), camera-locked facing, jump→fall→land, roll.
  - **`M.setBusy(bool)`**: combat sets it during a swing → locomotion fades out so the attack clip owns the
    body. It also **stops the jump/fall/roll Action poses** (iter 9) — those aren't in the loco set, so if
    left playing they blend against the (also-Action) attack clip = the "air anim overlapping movement" bug.
    setBusy also gates air-jump/dash and (via the `not busy` guard in `onSprint`) keeps combat the sole
    owner of WalkSpeed during a swing.
- **Combat client** `ClientSystems/combat.luau`
  - LMB = 5-hit light chain, RMB = heavy. Inputs buffered.
  - **Committed-recovery combo model** (iter 5, the "feels great" tuning): a swing (windup → active →
    recovery) is committed — **your own inputs never cancel it**. Walking doesn't cancel and mashing does
    nothing (both would let you `walk+punch` spam past the pacing). The ONLY early-out is the **paced combo
    chain**: a press *during* the hit queues the next one, which cancels in once `RECOVERY_CANCEL` of the
    recovery has elapsed → cadence = `act.e + recovery×RECOVERY_CANCEL` per hit (~2s for the 5-chain, one
    knob). Finisher (light-5) + heavy are committed with no chain. *(External interrupts — enemy/other-player
    specials — will break a swing through a SEPARATE path, deliberately not tied to your own inputs. TODO.)*
  - On a swing: movement is **fully LOCKED** (`ATTACK_MOVE_FACTOR = 0`, iter 9 — you commit until it's done)
    + `PlayerAnim.setBusy(true)`; sends `"attack N"` to server. Restored to `PlayerAnim.baseWalkSpeed()` at
    combo end (live sprint state, not a captured value). The lock is only real because `onSprint` also
    honours `busy` — a Shift tap must not stomp it.
  - **All attack clips are PRELOADED on character load** (`preloadAttacks`: eager `LoadAnimation` +
    `ContentProvider:PreloadAsync`) — without it the FIRST swing was silent (asset not downloaded yet).
  - `DEBUG_COMBO` prints each hit + seconds since the previous hit (verify real cadence — a sync-vs-logic check).
  - **VFX/SFX** via `std/fx.luau` (resolves BY NAME recursively; warns-once + no-ops if missing, so combat
    never breaks on un-authored art). Swing: a random `Whoosh` variant at the player + `Light` (hits 1-4) /
    `Heavy` (finisher + RMB heavy) at the hitbox. `Cfg.isHeavy(n)` = the finisher (last light) or the heavy.
  - **Impacts are CLIENT-PREDICTED — purely visual, no server confirmation.** `ClientSystems/combat` calls
    `Mobs.playImpacts(cf, hx, hy, hz, heavy)` the instant you swing; it runs the SAME box test as the
    server, but against the client's own interpolated mob positions, and pops `Hit1` (light) / `Hit2`
    (heavy-class) on **every** mob inside — catching 100 mobs should feel like 100 hits, not "a bit of
    hitstun". `IMPACT_CAP` (default 100) is purely a perf escape hatch. ONE `Hit` cue per swing (not per
    mob — copies just phase). The server's `mobhit` still owns damage + the hitstun reaction, so a rare
    interpolation disagreement costs only a cosmetic spark with no stun behind it.
    **The client box geometry MUST stay in sync with the server's OBB in `systems/combat`.**
  - **VFX sizing:** each kit in `Cfg.FX` is `{ name, scale }` and `std/fx` wraps it in a **Model** at spawn
    so `scale` goes through **`Model:ScaleTo`**. That's deliberate: ScaleTo resizes the effect *coherently*
    (particle sizes AND attachment offsets AND light ranges). Scaling emitter `Size` alone — the obvious
    approach, and what this did first — leaves attachment offsets at their authored distance, so particles
    grow while their spawn points don't and the effect visually drifts apart as you scale off 1. The Model
    wrap happens in CODE, so the artist never has to re-group the assets.
  - **How this place authors FX** (verified in Studio — `fx.luau` is written to it):
    - `Assets.VFX.*` = a **Part** anchoring Attachment(s) of ParticleEmitters (`Light.Punch`,
      `Heavy.HeavyPunch`+`Punch`, `Hit1.MIDDLE`, `Hit2.MIDDLE`). The anchor Part ships **visible**
      (1x1x1 ForceField) — `fx.luau` forces it invisible/non-query; it's a mount, not the effect.
    - Emitters ship **`Enabled = true` with a Rate** (not burst-authored), so `fx.luau` lets them run at
      their authored rate for `EMIT_WINDOW` then cuts them off = a burst that respects the artist's tuning.
      An `EmitCount` attribute ON an emitter instead opts into an explicit one-shot `:Emit`.
    - `SoundService.Whoosh` / `.Hit` are **Folders of variants** (`melee1-4`/`weapon1-4`,
      `punch1-4`/`sword1-2`) — a random one plays per swing; `SWING_PICK`/`HIT_PICK` filter by name prefix
      so the boxing stance pulls `melee*`/`punch*` and a future weapon stance pulls `weapon*`/`sword*`.
  - **Always-on debug hitbox** (red neon box) drawn during active frames. Box spans from ~0.5 behind the
    player out to `reach` ahead (so point-blank mobs are hit); width/height from `box.X/box.Y`,
    depth from `reach` (**`box.Z` is now unused**).
  - **Block = a COMMITTED STANCE** (iter 8). Holding `block.key` (F) gates *everything* — release to act:
    attack input is **dropped, not buffered** (a buffered swing would fire the instant you let go, reading
    as the guard "storing" attacks); roll + sprint gated in `playerAnim`; movement drops to a turtle
    shuffle (`block.MOVE_FACTOR` 0.25, not a dead stop); loco fades so the block pose owns the body. The
    mirror rule also holds: **you can't raise guard mid-swing** (same principle as no walk-cancel).

### AIR COMBO (iter 8) — the DMC layer
Airborne, the chain switches tables. **One number on the wire encodes air-ness** (`AIR_BASE = 10` → air is
11/12/16), so the server needs no extra arg and still reads every damage/knock/lift from *our* config.
Both ends resolve through the **shared `Cfg.resolve()`** — they can never drift on what "attack 12" means.

| | mob `lift` | `knock` | player |
|---|---|---|---|
| ground light 1/2/4 | 0 | 8–12 | — |
| **ground light 3** | **+35** medium (≈6.8 studs, 0.78 s hang) | 10 | — |
| **ground light 5** | **+60** HIGH — the launcher you combo into the air off | 22 | — |
| **air 1** | **+45** re-launch (keeps the juggle alive) | 6 | `float = 2` |
| **air 2** | 0 | **40** — the ejector that ends it | `float = 0` |
| **air heavy** (slam, `80862020147663`) | GRAB → drag down → radial scatter | `SLAM_SCATTER` 60 | `selfSlam = 90` (dives) |

- Air actives are much shorter (0.10–0.18 vs 0.22–0.33): you're falling, so they must come out fast.
- **Landing cancels an air LIGHT** (hitting the floor *is* its end). Jumping mid-ground-combo starts the air
  chain fresh at 1 rather than carrying the index over.

### AIR-HEAVY SLAM = a continuous GRAB (iter 9)
Not a one-shot. The slam is a **catch → drag → scatter** with real destruction:
- **Client** (`combat.startAttack`): dives (`selfSlam`), sends the trigger ONCE at the top, `didHit=true`
  (suppresses the normal `fireHit`), holds the anim's **last frame** while diving (robust to the non-looped
  clip auto-stopping under frame drops), throttled predicted impact sparks down the path. A diving slam
  **never ends mid-air** (a special hold in the debounce) so it always lands → `slamland` fires.
- **Server** (`systems/combat`): the trigger marks `slamming[player]` (rate-gate **exempt**); a Heartbeat
  **`slamStep` sweeps the tall box (10×16×10) down the dive path**, grabbing + damaging every NEW mob it
  passes (a `Grabbed` component). `systems/mobs` drags a grabbed mob straight down (`SLAM_DRAG`), no steering.
- **On land** (`onSlamLand`, idempotent — consumes `slamming`): every grabbed mob is flung **radially
  outward** (`SLAM_SCATTER`), then `RockModule.Crater` + `Explosion` spawn a rock crater (and optional
  `VoxManager:voxelizePosition` carve — `SLAM.VOXELIZE`, off by default). Safety: a `SLAM_GRAB_MAX` (4.5 s)
  timeout + `PlayerRemoving` release stranded grabs. Modules are `require`d from Workspace, guarded.
- **Re-slam cooldown** (iter 10): the client gates a repeat air-heavy on `SLAM.COOLDOWN` (2 s, `nextSlamAt`
  in `startNext`) — jump→slam→jump→slam was chainable with no gap. **Rock cleanup** (iter 10): RockModule's
  crater rocks linger ~30 s; `onSlamLand` now schedules `RockModule.ClearDebris(true)` after `SLAM.DEBRIS_TTL`
  (4 s). Caveat: `ClearDebris` fades the *whole* Debris folder, so overlapping slams clear each other's rocks
  early — fine for co-op / a few concurrent slams.
- **You can't jump/dash out of a committed swing** (`doAirJump`/air-dash gate on `busy`) — that also stops a
  slam being stretched past the grab window.

- **Air-light anim ids are PLACEHOLDERS** (ground light 1/2) — see TODO.

### Player air feel (iter 8) — the self-limiter
`playerAnim` is the **single owner of the player's airborne Y**; combat *asks* via `PlayerAnim.airFloat()`
rather than writing velocity, so nothing tugs-of-war across the PreRender/PreSimulation boundary. (One
honest exception: the slam's `selfSlam` is a one-shot impulse written from combat — not per-frame contention.)
- **Progressive gravity** — `AIR_GRAV_RAMP` (60 studs/s² *per second airborne*), capped `AIR_GRAV_MAX` 180.
  Early air floaty, late air drops like a rock.
- **Float fade** — an attack's hang decays over `AIR_FLOAT_FADE` (1.2 s) of air time. Implemented as
  `target = v.Y + (floatVy - v.Y) * scale` — it scales the **benefit**, not the value, which is why it still
  works for air-2's `float = 0` (a naive `floatVy * scale` would hang forever).
- **`airT0` (air time) reset rules** (iter 9): an air **attack or dash** `resetAirTime()`s → the gravity ramp
  restarts, so an ACTIVE juggle keeps its hang while idle floating still falls faster over time. A **double
  jump does NOT reset it** — it buys height, never refreshes air time. (Resetting on attack also refreshes the
  float-fade; verified this does NOT cause infinite float — base gravity still nets a descent between hits.)
- **Double jump** (`MAX_JUMPS` 2, `AIR_JUMP_POWER` 50): plays the **roll clip** (reads as a flip),
  **redirects** horizontal to `AIR_JUMP_MOMENTUM` (18) along your input; no input → keeps existing. The
  ground jump stays **Roblox's own** (we bind Space/ButtonA with `Pass` and only act when already airborne).
  Walking off a ledge **spends** the ground jump → one air jump, not two.
- **Air dash** — roll while airborne: `AIR_DASH_SPEED` 40 for `AIR_DASH_TIME` 0.28 s with **Y pinned to 0**
  (flat dash, not a dive). **Once per airborne period** (`airDashUsed`, refunded on landing) AND **gated by
  the ground roll's shared `nextRoll` cooldown** (`ROLL_CD`, iter 10 fix). The refund alone let you *hold
  Space + spam dash* — bunny-hop, land (refund), re-dash instantly; the shared cooldown (checked at the top
  of `doRoll` for both ground roll and air dash) closes that.
- **Movement SFX** — `FX.sound` resolves names **recursively** under SoundService, so `animConfig.SFX`
  `JUMP`/`ROLL` find `SoundService.Movement.Jump`/`.Roll`. A folder of variants works (random pick); a wrong
  name is one warn, never an error.
- **Combat server** `ServerScriptService/systems/combat.luau`
  - Server-authoritative: on `"attack N"`, a **manual OBB overlap** (same geometry) against mob hitboxes via
    `MobRegistry.forEach` applies damage + knock + `lift` (launcher), fires `"mobhit"` ids to clients.
  - **The air-heavy slam is special** (iter 9): rate-gate exempt, marks `slamming[player]`; a Heartbeat
    **`slamStep`** sweeps the box down the dive grabbing new mobs; `onSlamLand` (idempotent) scatters +
    fires `RockModule.Crater/Explosion` (+ optional `VoxManager` carve). Modules `require`d from Workspace.
  - Block state received but not yet consumed (no mob→player attacks yet).
- **Transport:** a shared bidirectional **`CombatRemote`** (plain RemoteEvent, find-or-create by whichever
  of combat/mobs loads first). client→server: attack/block/spawnmobs/clearmobs. server→client:
  mobhit/mobdeath. *Prototype only — migrate to a Blink lane later.*

### Blocking design (partly built)
Block = **mitigation, not negation**: reduce incoming damage by `REDUCTION` (50%), drain a `BLOCK_HP`
meter (guard drain = mob attack damage × `GUARD_DRAIN` — NO per-attack "block damage"; player attacks hit
mobs, which don't block). At 0 block HP you can't block until it recharges. A heavy doesn't break block
instantly, it just drains faster. **Currently feel + meter only** — the damage side needs mob attacks.

---

## Dev panel

`ClientSystems/devPanel.luau` — **Studio-only** GUI (left of screen): count box + Spawn / Clear + one-click
**100/500/1k/2k stress presets**. Spawn drops that many mobs in a ring around you (ground-snapped, server
clamps 2000); Clear wipes them silently (no corpses).

`ClientSystems/perfHud.luau` — **live SCALE overlay** (top-right, **F3 toggles**, on by default). Shows FPS
(colour-coded), frame ms, live mob count, the **`N anim / M far` LOD split**, net ↓ KB/s (`Stats.DataReceiveKbps`),
and memory. Reads counts via `mobs.getStats()`. This is the demo's *proof surface* — the project is framed
as a **scale-engineering showcase** (see the `project-showcase-direction` memory), and this readout makes the
scale legible on screen. Trimmed (iter 12) to **FPS + mob count + LOD split** only — the values we compute
exactly; engine internals (net/mem/CPU) aren't reliably Lua-readable and Roblox's own overlay covers them.

---

## Gameplay / front-end layer (iter 12 — the showcase feel)

Built to prove gameplay + UI (the axis the target role leans on), riding the existing scale. All client feel
except the wave director (server).

- **Damage numbers** — `ClientSystems/damageText.luau`. Pooled, **screen-projected** floating text (no
  per-number world Instances — `WorldToViewportPoint` each frame on pooled `TextLabel`s), so a 100-mob AoE
  swing pops 100 numbers and stays bounded (`CAP=90`). Rise + fade + pop-scale; orange/bigger for heavy.
  Spawned inside `Mobs.playImpacts` (the client-predicted hit sweep), which now takes `damage` and RETURNS
  the hit count.
- **DMC Style meter** — `ClientSystems/styleMeter.luau` + `combatConfig.STYLE`. Rank **D→C→B→A→S→SS→SSS**
  (names + colors), top-right under the perf HUD. Builds on hits with a **variety** multiplier (mashing one
  move earns less) + an **AoE bonus** (many mobs at once); **decays over time, faster once idle**; letter
  **pops on rank-up**, ghosts at idle D. `M.onPlayerHit()` is the rank-drop hook for when mob attacks exist.
  Fed from `combat.fireHit`: `Style.addHit(attackNum, heavy, hitCount)`.
- **Wave loop** — server director in `systems/mobs.luau` (`mobConfig.WAVE`) + `ClientSystems/waveHud.luau`.
  `spawning → fighting → breather → next (bigger) wave`, spawned scattered around a player via `spawnMob`,
  reusing the OLD `_legacy/SpawnMob` DESIGN against the NEW Blink pipeline. `liveCount`/`killCount` counters
  (spawn/despawn) drive the HUD; state pushed over CombatRemote `"wave"` at `WAVE.BCAST`. Toggled by the dev
  panel **▶ Start Waves** button (`"waves"` event); the panel also gained one-click 100/500/1k/2k presets.
- **Hit path summary:** `combat.fireHit` → `Mobs.playImpacts(cf,…,heavy,damage)` (impact FX + damage numbers,
  returns count) → `Style.addHit`. The slam's throttled predicted sparks pass no `damage` (no number spam).
- **Status: PENDING a Studio playtest.** Built + compile-clean + traced; the visuals (number alignment,
  meter juice, HUD layout) need eyes. One known risk: damage numbers use `WorldToViewportPoint` +
  `IgnoreGuiInset=true` (the standard pairing) — if they sit ~36 px low, flip `IgnoreGuiInset`.
- **CONTENT GAP (not engineering):** combat currently has only the **sword move-set animations**; there are
  no varied skill/ability animations or models yet. That's an ART/content need (a programmer would receive
  assets), so it doesn't block the systems — but the *demo* looks one-note until more move-sets/VFX land.
- **VFX now POOLED (iter 13)** — `std/fx.luau` `M.burst` no longer clones+ScaleTo+Destroys per hit. It pools
  prepared instances **per `(name, scale)`**: the first burst of a size builds one (clone+wrap+ScaleTo+cache
  emitters, once); later bursts reuse a parked instance (PivotTo + re-Emit, park via parent→nil after ttl,
  never Destroy). Bounded by `MAX_PER_KEY` (60). Caller API unchanged. This kills the Instance churn that
  made the AoE case (a burst per hit mob) spike. **Q&A that drove it:** scaling a Model is *not* the only way
  to size VFX (also `ParticleEmitter.Size`, pre-authored tiers) — but ScaleTo is what keeps particle sizes +
  attachment offsets coherent; the real cost was the per-hit clone/Destroy, fixed by pooling.
- **Upgrade EFFECTS now WIRED (iter 13)** — `std/upgradeStats.luau` is the single source (defaults + `apply(stats,key)`);
  both sides fold picks into a stat set. On pick, `xp` applies to the shared client `std/runStats` AND fires
  `"upgrade"(key)` to the server. **Server** (`systems/combat`, per-player `playerStats`): `onAttack` reads it
  → damage ×`dmgMul`(×`airDmgMul` on air), box ×`rangeMul`, knock ×`knockMul`, plus **Chain Lightning** (arcs
  to un-hit mobs within `CHAIN_RANGE`); `onSlamLand` ×`slamMul`. **Client** (`playerAnim` reads `runStats`):
  `speedMul`→WalkSpeed, `jumpMul`→air-jump power, `bonusJumps`→MAX_JUMPS. Devil Trigger = a bundle of muls.
  REAL: damage/airdmg/range/knock/chain/slam/devil/speed/jump/airjump. STILL INERT (need an underlying
  mechanic): `atkspeed` (no combat-cadence hook), `lifesteal` (no player HP), `slowmo`/`meteor` (flags set,
  nothing reads them).
- **NOT started:** a boss (Tier-3 real physics); the 4 inert upgrades above; a beam VFX for chain lightning.

### Gameplay layer, part 2 (iter 13)
- **Style meter REMOVED** (styleMeter.luau deleted, combatConfig.STYLE gone). Mob **HP 100→25**. **Air
  attacks pop no damage numbers** (fireHit passes nil damage for `attackNum > AIR_BASE`).
- **Mob health bars** — `ClientSystems/healthBar.luau`: pooled BillboardGui **adorned to the near rig**
  (follows natively, no per-frame Lua writes), fill updated on hit only, auto-hide after 2.5 s, full-HP mobs
  show none. HP fraction rides the `mobhit` event (server `onAttack` now sends a parallel `hitFracs`).
- **Mob → player attacks** — `systems/combat.luau` `mobAttackStep` (Heartbeat, ~10 Hz, skipped while paused).
  ONE scan per player gathers up to `LUNGE_CAP` (8) in-range mobs (each on a `LUNGE_CD` lunge cooldown) → they
  broadcast `"mobattack"` (a LIST of netIds) → the client plays a LUNGE on each, so **MANY mobs strike at once**.
  KNOCKBACK is separate + still gated (`PLAYER_HIT_GAP`, every 3rd = FINISHER) from the NEAREST mob, so the
  swarm menaces but can't knock-spam you; applied server-side (`AssemblyLinearVelocity` on the server-auth
  character — **the main playtest risk**), light (`KNOCK_SMALL/MED/UP = 9/18/2`). Lunge clip =
  `mobConfig.ATTACK_ANIM` (a real swing from combatConfig — light-1; no dedicated mob-attack clip yet). Client
  `playerHit.luau`: a `hit1..N` FLINCH (NOT `knockdown` — that read as a stun) at **Movement** priority so your
  attacks/rolls (Action) OVERRIDE it, + camera shake + the player's own melee hit SOUND (`FXC.HIT_SOUND`
  +`HIT_PICK` → punch, not sword). No player HP/damage yet.
- **XP gems + level-up cards** — `ClientSystems/xp.luau` (pooled magnet gems on mob death → XP bar → level),
  `ClientSystems/levelUpCards.luau`, `std/upgrades.luau` (5 rarities + ~14 upgrades). On level-up the world
  **really pauses** (see below), the screen blurs + animates IN (title fade, card row slide-up, cards pop-in),
  3 slot-machine cards spin & lock onto rarity-rolled **text cards** (RARITY → NAME → DESCRIPTION, no icon
  slot), you pick. Effects are WIRED (see the Upgrade EFFECTS bullet above). XP/gems are client-side (PvE = fine).
- **REAL pause — `std/serverPause.luau`** — a shared server flag set from combat's `"picking"` count. `systems/
  mobs` `simStep` + `waveStep` and combat `mobAttackStep` all early-return while paused → the horde freezes,
  waves halt, nothing hits you; it lifts when you pick. `simStep` doesn't accumulate dt while paused (no
  catch-up lurch on resume). Solo/co-op-demo scope: pauses for everyone. **Gotcha it hit:** `setPicking` was
  declared BELOW the `OnServerEvent` that calls it → the handler bound a nil global → the `"picking"` handler
  CRASHED and `paused` never set (the pause "not working" was this, not the design). Keep such handler
  callees declared ABOVE the connect.
- **Mob surround (queue fix)** — the arrival/tangential-flow (iter 11) couldn't break a SINGLE-FILE line: a mob
  directly behind another has ~0 lateral separation → 0 tangential push → it just stopped (queued "in front").
  Fix: a blocked mob with no lateral crowd now **peels to a fixed side** (`e % 2` for stable handedness, tangent
  to the player-radial) so lines break into arcs and wrap AROUND the player.

---

## Config knobs (where to tune)

- **`std/mobConfig.luau`** — spawn (`TEST_COUNT`, `SPAWN_RADIUS/ORIGIN/DELAY`), `HP`, movement
  (`SPEED`, `MOVE_TICK`, `CONTACT`), **`GRAVITY`** (juggle hang), **separation** (`SEP_RADIUS`, `SEP_PUSH`,
  `SEP_CLAMP` — note effective max push = `SEP_CLAMP × SEP_PUSH`), **arrival/hold-back** (`BLOCK_RADIUS`,
  `BLOCK_CONE` — the anti-stack), `ORBIT_BAND/DAMP`, `SETTLE/SETTLE_PAD`, **waves** (`WAVE.{BASE,GROW,MAX,
  RADIUS,SPAWN_EVERY,SPAWN_BATCH,BREATHER,MAX_WAVE_TIME,BCAST}`), **`ATTACK_ANIM`** (mob attack/lunge clip),
  **ground/wall collision**
  (`GROUND_CAST`, `GROUND_RECAST_D`, `STEP_HEIGHT`, `CLIMB_REACH`, `GROUND_DOWN`, `GROUND_SNAP`, `KILL_Y`,
  `WALL_CAST`, `WALL_STEEP`, `WALL_MIN_MOVE`), **replication + render-LOD** (`LOD_NEAR`, `LOD_HYST`,
  **`NEAR_CAP`** = max animated rigs / nearest-N budget, `LERP_RATE`, `HEADING_RATE`, `MOVE_EPS2`,
  `FAR_WALK_FREQ/AMP`, **`FAR_LEGS`** = far leg-swing on/off (OFF — the LuaBridge-write win), `DEBUG_NET`),
  rig (`ROOT_NAME`, `FOOT_OFFSET`), reactions/death (`HIT_COUNT`, `DEATH_FLING/TTL/CAP`), loco tuning
  (`WALK_REF`, `RUN_REF`, `RUN_START`, `RUN_FULL`).
- **`std/animConfig.luau`** (air/jump additions) — `MAX_JUMPS`, `AIR_JUMP_POWER`, `AIR_JUMP_MOMENTUM`,
  `AIR_GRAV_RAMP`, `AIR_GRAV_MAX`, `AIR_FLOAT_FADE`, `AIR_DASH_SPEED`, `AIR_DASH_TIME`, `SFX.JUMP/ROLL`.
- **`std/config.luau` → `Config.Net`** — the mob wire quantization (SHARED server+client): `STEP` (stud/i8
  unit), `CHUNK` (slots/packet), `NET_TICK` (delta rate), `FULL_EVERY` (snapshot period), `WARP_THRESH`.
- **`std/combatConfig.luau`** — `DEBUG_SHAPECAST`, `DEBUG_COMBO`, `BUFFER`, `FRAME_RATE`,
  **`RECOVERY_CANCEL`** (combo cadence — fraction of recovery before the next hit cancels in),
  **`ATTACK_MOVE_FACTOR`** (movement kept while swinging), `INPUT`, `stances.base.light[1..5]`/`heavy`
  (per attack: `anim`, `active{s,e}`, `recovery`, `damage`, `knock`, `box`, `reach`), `block` (`key`, `HP`,
  `REDUCTION`, `GUARD_DRAIN`, `RECHARGE`, `RECHARGE_DELAY`), **`FX`** (asset names + `IMPACT_HEAVY_SCALE`,
  `IMPACT_CAP`, `TTL`, `EMIT`) and `isHeavy(n)`.
- **`std/fx.luau`** — the client one-shot VFX/SFX helper (name-resolved, warn-once, Debris-cleaned).
- **`std/animConfig.luau`** — player anim sets + shared reaction clips (idle, walk/run F/B/L/R, jump,
  fall, land, roll, hit1..5, knockdown, knockdownloop). Also player feel/camera/input tunables.
- **`std/chronoConfig.luau`** — PLAYER / MOB entity types.

### Tuning notes
- Rig floating → `mobConfig.FOOT_OFFSET` (and confirm the `[mobs] rig root part = '...'` print names the
  right part; else fix `ROOT_NAME`).
- **Player run foot-slides / anim too slow** → lower `animConfig.RUN_REF` (playback = speed/RUN_REF; set to
  20→14 in iter 5). Walk uses `WALK_REF` the same way.
- **Mob won't lean when charging** → it's the run pose diluted by walk; `mobConfig.RUN_FULL` is kept BELOW
  chase `SPEED` so a charging mob lands at full run weight (measured speed reads a touch low through
  interpolation). If it STILL won't lean, the lean lives in the clip's ROOT motion, which we override (the
  client drives the rig root's CFrame directly) — that'd need a cosmetic client-side forward-tilt to restore.
- Mob run looks slow-mo → run plays at `speed / RUN_REF`; lower `mobConfig.RUN_REF` or raise `SPEED`.
- **Mob rotation speed wrong / stuttering** → `mobConfig.HEADING_RATE` (ease rate) and `MOVE_EPS2` (the
  deadband). The facing is derived from the PURSUIT GAP (`target - renderPos`), NOT the per-frame lerp step
  — deriving it from the step put `MOVE_EPS2` right at the per-frame motion (~0.15 studs at chase speed) and
  froze the heading. Near rigs also force `Humanoid.AutoRotate = false` (we own the CFrame).
- **Combo cadence** → `combatConfig.RECOVERY_CANCEL` (one knob: lower = snappier, higher = weightier).
  `DEBUG_COMBO` prints the real per-hit gap. Movement-during-swing → `ATTACK_MOVE_FACTOR`. Reach → `reach`.
- **Juggle feel** → `mobConfig.GRAVITY` first (↓ floatier, ↑ snappier); launcher heights are per-attack
  `lift` (`apex = lift²/(2*GRAVITY)`). **Air combos last too long** → `AIR_GRAV_RAMP` ↑ or `AIR_FLOAT_FADE` ↓
  (those two ARE the self-limiter). **Can't reach a juggled mob** → `AIR_JUMP_MOMENTUM` / `AIR_DASH_SPEED` ↑.
- **A launcher rises in SLOW MOTION then pops** → `lift` exceeded the lane's velocity ceiling. Raise
  `config.luau Net.STEP` and keep `WARP_THRESH ≤ 127×STEP` — see the Replication warning.
- **Blocking too restrictive / too loose** → `combatConfig.block.MOVE_FACTOR` (0 = rooted, 0.25 = shuffle).
- Mobs still spinning/shuffling → lower `SETTLE`; stopping too far out → lower `SETTLE_PAD`.
- **Crowd STACKS on the player / doesn't spread** → this is NOT a separation-tuning problem. Separation is a
  *sum* of neighbour pushes → it cancels inside a symmetric pile, and if `SEP_PUSH×SEP_CLAMP` < `SPEED` the
  inward chase just compresses everyone to the point. The fix is **arrival/hold-back** (`BLOCK_RADIUS`,
  `BLOCK_CONE`): mobs stop steering in once someone's ahead of them, forming concentric ranks. Ranks too
  tight → raise `BLOCK_RADIUS`; mobs hold back too far/early → raise `BLOCK_CONE` (narrower cone). Do NOT try
  to fix stacking by cranking `SEP_PUSH` (that only brings back the churn). *(A velocity-based hold-back was
  tried and reverted — it deadlocked; the plant zeroes the velocity that would un-plant it. Use the spatial
  neighbour check, never the mob's own speed.)*
- **Client FPS tanks with a big crowd (LuaBridge / `$newindex` high in the microprofiler)** → it's the COUNT
  of per-frame Instance property writes, not rendering/Animators. Never write `.CFrame`/`Motor6D.Transform`
  per mob per frame — batch through `MobRenderPool` + one `BulkMoveTo`. `FAR_LEGS` must stay OFF (its 2
  Motor6D writes/mob were the whole 32 ms). Too many Animators → lower `NEAR_CAP`. Gait-call churn →
  `ANIM_TICK` / the `W_EPS`/`S_EPS` skip-unchanged. See "CLIENT CROWD PERF" in the Mobs section.
- **Mobs clip through walls** → confirm `WALL_CAST` on and the wall is `CanCollide=true` (we set
  `RespectCanCollide`); fast movers slipping thin geometry → the box is `HITBOX_SIZE`-wide, thin props
  need real width. **Mobs stall on a ramp / burrow into it** → the ramp is steeper than `CLIMB_REACH`
  allows to climb but shallower than `WALL_STEEP` blocks; raise `CLIMB_REACH` (and it auto-extends the
  down-ray) or raise `WALL_STEEP` so it's treated as a wall instead. **Mobs float over slopes / lag the
  terrain** → lower `GROUND_RECAST_D` (re-cast more often) or raise `GROUND_SNAP` (ease up faster).
  **Mobs vanish near a pit edge** → they fell past `KILL_Y`; if the map floor is genuinely that low, lower
  `KILL_Y`. **FPS drops with 500 mobs pressing a wall** → expected (raw-geometry shapecasts); the collision
  shell is the fix — meanwhile raise `WALL_MIN_MOVE` to skip more near-stationary casts.

---

## Testing

- **2-player local server** (Studio → Test → 2 players). Watch Output:
  - `[boot +Ns]` stages, `[chrono] server/client ...` (player replication), `[mobs] rig root part = ...`,
    `[mobs] spawned N ...`.
- **Dev panel** (Studio) to spawn/clear packs on demand.
- **`mobConfig.DEBUG_NET = true`** → once/sec seam prints on BOTH ends. This is the first thing to flip when
  mobs misbehave — it isolates which of the three layers is at fault without guessing:
  - `[mobs/net] N mobs | delta X B/s | full Y B/s | TOTAL Z KB/s per client (xP players = … up)` — the REAL
    measured lane cost (payload bytes packed; excludes Roblox/Blink framing). **Verifies the ~26 KB/s @ 500.**
  - `[mobs/cli] FIRST delta applied …` / `FIRST full snapshot applied …` — one-shot: proves the stream
    arrived at all. Silent = the lane is dead; present but nothing moves = the renderer is stuck.
  - `[mobs/cli] live=N near=A far=B | swaps=C/s` — `live` should track the server's mob count (mismatch =
    spawn/death leak); high `swaps/s` = mobs dithering across the LOD boundary → raise `LOD_HYST`.
- **Verify server behavior with `print`, not the Studio MCP explorer** (the ECS world isn't reachable
  from other Luau contexts; print is fastest).

---

## TODO / next steps

- **Client crowd perf — DONE (iter 11), PENDING final playtest.** The ~500-mob/32 ms wall was **LuaBridge
  property-write count** (`$newindex` on CFrame), fixed by `FAR_LEGS=false` + batch-only `BulkMoveTo` + the
  rate-split + nearest-N `NEAR_CAP`. See "CLIENT CROWD PERF" in Mobs. Crowd STACK on the player fixed by
  **arrival/hold-back** (`BLOCK_*`) — a velocity-based version deadlocked and was reverted. **Playtest the
  arrival ranks + confirm FPS holds at 1–2 k.** Open perf levers if needed: bulk-move only dirty roots;
  skinned-MeshPart rig (1 object vs ~15 parts).
- **Custom mob Blink lane — DONE (iter 6).** Mobs now stream on our dense-slot i8-delta lane (~26 KB/s at
  500) with render-LOD; players stay on Chrono. Remaining hardening on it:
  - **Verify bandwidth empirically** (Studio F9 network / `Stats`) at 500 mobs; confirm the ~26 KB/s target.
  - **netId is a monotonic u32** (fine for a prototype; wraps after 4 B spawns). Slot is u16 (≤65535 live).
  - **Late-join / cross-channel:** `Spawn`/`Death` are reliable-ordered, but `mobdeath` (CombatRemote) vs a
    slot-reusing `Spawn` (Blink) race — handled by a guarded `slotToNet` clear; watch for edge cases.
  - **Far-tier leg-swing axis** is a best-guess (`CFrame.Angles(s,0,0)`, R15); flip if legs splay sideways.
- FX assets all EXIST and are wired (see the Combat section). Spare kits are already in `Assets.VFX` for
  later: `BlockedHit`, `BlockBreak`, `PerfectBlockHit`, `Parry` (block/parry work), `NormalHit`, `SlashHit`,
  `FlameHit`, `WaterHit`, `blackflashimpact`, `Drop`, `RootFX.Finisher`, `elec`, `Wind vfx`.
- **Mobs should ALWAYS face the player (future)** — needed for special skills / telegraphed attacks. Facing
  is currently client-derived from the pursuit direction (`heading`, eased at `HEADING_RATE`). A face-the-
  local-player toggle is a ~3-line change in `ClientSystems/mobs.luau`'s render (swap the heading target);
  a per-mob "face your actual target" would need the target streamed (it isn't — position only on the wire).
- **Remote-player swing FX** — swing VFX/SFX are client-local (your own attacks only); other players don't
  see/hear each other's swings. Needs the server to broadcast attacks (impact FX already broadcast).
- **AIR-LIGHT ANIM IDS ARE PLACEHOLDERS** — `stances.base.air.light[1..2].anim` currently point at the
  ground light 1/2 clips. The design note says "use the knock animation"; drop that id in. (The slam
  correctly uses `80862020147663`.)
- **CLAUDE.md needs rewriting** — its "no server-authoritative player movement / no prediction" rule is
  obsolete (Roblox Server Authority does it natively), and its "living mobs are flat-Y Tier 0" framing no
  longer matches: mobs now have kinematic vertical physics for launches.
- Paste mob-specific loco ids if desired (else animConfig base is reused); tune `FOOT_OFFSET` / `SPEED`.
- **Mob → player attacks** — unlocks real block damage (the block meter + 50% mitigation are already wired
  client/server, just need an incoming-damage source).
- Player **hit reactions** (hit1..5 / knockdown from animConfig) when a mob hits you — needs a
  `playClip` helper on playerAnim (or combat loads them) + the server telling the client.
- **Remote-player directional animation** (playerAnim is local-only; remote chars need their own animator
  driven off the streamed CFrame/velocity).
- Migrate `CombatRemote` → a Blink lane (`Net.blink`) instead of a raw RemoteEvent.
- **True ragdoll** death (replace Motor6D with sockets) instead of the rigid-body fling.
- **Lag-comp rewind** for hitreg (Chrono exposes snapshot history via `Entity.GetAt`).
- **Ground/wall detection — DONE as a raw-map first pass (iter 10).** Gated ground re-cast + wall shapecast
  against real geometry (see the Mobs GROUND/WALL section). **Next major step: the simplified collision
  shell** (CLAUDE.md keystone) — invisible clean boxes/wedges mobs sweep instead of raw visual geometry:
  cheaper, deterministic, and the real scaling answer for 500+ mobs pressing terrain. Then the **CLAUDE.md
  tiers** (T0 no-collision … T2 full swept-volume, keep T2 count small). Deferred first-pass polish: a
  **momentum arc off ledges** (mobs currently drop straight down), an **edge whisker** so mobs avoid walking
  off drops, and wall-checking **airborne/knocked** mobs (only grounded ones check now).
