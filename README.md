# Hack & Slash — a scale-engineered Roblox horde prototype

A **Devil-May-Cry-style hit-and-slash PvE horde game**: fluid melee combat against **hundreds of
living, networked enemies** on screen, with a survive-the-horde loop (waves, XP, level-up upgrade
cards) and satisfying ragdoll deaths. It's a **prototype built to validate the engineering** — the
gameplay is real, but the point is the systems underneath: *can Roblox actually run a large,
server-authoritative horde at 60 FPS if you stop using it the idiomatic way?*

> **Why it's in a portfolio — read past "it's Roblox."** The engine is just the runtime. Everything
> hard here is platform-agnostic **systems engineering**: a data-oriented ECS, a custom
> buffer-packed replication protocol, spatial-hash broad-phase, render LOD + instance pooling,
> profiler-driven optimization, and controlled per-system tick budgets. The same architecture drops
> onto Unity DOTS, Bevy, or a custom authoritative game server — the names change, the engineering
> doesn't. See **[Transferable engineering](#transferable-engineering)**.

Detailed current-state write-up: **[`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md)**.

---

## The bet

The idiomatic Roblox NPC is a `Model` + `Humanoid` carrying its own state machine, pathfinder, and
physics — and Roblox's **default replication** streams all of it. That's the wall: not *drawing* a
thousand enemies, but **deciding and streaming** their movement, collisions, and hits every tick
without melting the server CPU or the wire.

So this project **unshackles Roblox's default replication** and runs its own — keeping Roblox's
physics and geometry where they're cheap and correct, and replacing only the networking + simulation
layers where Roblox is slow and unpredictable. Mobs are **kinematic** (no per-mob `Humanoid`, no
solver, no navmesh); the server owns their movement and hit authority; the client assembles its own
rigs and renders a streamed position feed.

## Engineering highlights

- **Custom buffer-packed replication.** Mobs stream over a hand-rolled **[Blink](https://github.com/1Axen/blink)
  dense-slot lane**: positions are written in *slot order* with no per-mob id (the client maps
  slot→entity once from the spawn payload), each axis a signed-byte fixed-point delta, plus periodic
  absolute snapshots to clear drift — **~3 bytes/mob** on the wire (vs ~16 for a general-purpose lib).
- **Data-oriented ECS ([jecs](https://github.com/ukendio/jecs)).** All gameplay state lives in ECS
  tables, not on Instances; hot loops use cached archetype queries.
- **Spatial-hash broad-phase** — one pooled uniform grid, rebuilt each tick, reused for crowd
  separation *and* melee hit queries → O(N·k) neighbor lookups instead of O(N²).
- **Render LOD + pooling.** The client is pure presentation: nearby mobs get a full animated rig
  (capped to a **nearest-N** animation budget); distant mobs get a cheap pooled rig moved in bulk.
  Nothing is `Instance.new`'d in a hot path — rigs, VFX, damage numbers, and ragdolls are all pooled.
- **Kinematic mob sim at controlled rates.** AI runs at ~20 Hz (not per-frame); ground/wall detection
  uses **movement-gated raycasts + footprint shapecasts** (idle mobs cast zero rays), not a `Humanoid`
  or a navmesh — reactive steering, separation, and an **arrival/surround** rule so the crowd wraps
  around the player instead of stacking.
- **Server-authoritative, the right amount.** The player character uses Roblox's native **Server
  Authority**; mobs are a *custom* server-authoritative movement + replication pipeline with
  client-side `AnimationController`-driven rigs. Only hit **outcomes** are server-validated.

## Case study: a profiler-driven optimization

A representative slice of the work. At ~500 on-screen mobs the client frame time was pinned at ~32 ms
(≈30 FPS) and it *looked* like a rendering or animation problem. The microprofiler said otherwise: the
hot cost was **`$newindex` under the LuaBridge** — the raw *count* of individual `CFrame` property
writes crossing the Lua↔C++ boundary each frame (~2,000 of them), from moving each rig's parts
one at a time. Triangles and Animators were nearly free.

The fix was to stop writing transforms per-instance and **batch them through one `BulkMoveTo`**, plus
a rate-split (motion every frame, animation config at 20 Hz with skip-unchanged) and the nearest-N
animation cap. The lesson — *profile to the real bottleneck; don't optimize by guessing* — is the
point of the case study, not the specific fix.

## The game

It plays as a real game, not just a tech demo:

- **Combat** — a DMC-style ground chain (5 hits + heavy), **air combos** (launch → juggle → aerial
  finisher), and an **air-heavy slam** that grabs mobs, drags them down, and scatters them on landing.
  Committed windups/recovery (no walk- or spam-cancel), a block stance, and dashes.
- **Survive the horde** — escalating **waves** with a live HUD, mobs that **swarm and attack** (a
  crowd lunges at you; knockback is rate-limited so it menaces without spamming).
- **XP + level-up cards** — kills drop XP gems that magnet to you; leveling **pauses the world**,
  blurs the screen, and deals **three slot-machine upgrade cards** (five rarities) to pick from.
  Upgrades apply **real effects** — damage/range/knockback scaling, extra air jumps, and **chain
  lightning** that arcs between mobs.
- **Juice** — pooled floating damage numbers, mob health bars, hit reactions, camera shake, and
  pooled client-side ragdoll deaths.

## Architecture at a glance

```
ReplicatedStorage/std/   shared: ECS world + components, scheduler/phases, spatial hash, configs,
                         the generated Blink net layer, and cross-cutting modules (upgradeStats,
                         serverPause, mob/combat config, fx/VFX pool)
ServerScriptService/systems/
  mobs                   kinematic horde sim: reactive steer + separation + arrival/surround +
                         gated ground/wall casts + vertical physics; the Blink streaming sender;
                         the wave director
  combat                 authoritative melee hitreg (OBB vs ECS positions), launchers/slam grab,
                         mob->player attacks, per-player upgrade stats
  players                spawn + player-entity wiring
ClientSystems/           pure presentation: the mob renderer (LOD + pooling), local-player combat +
                         animation, damage numbers, health bars, wave/XP/perf HUDs, level-up cards
```

The client never runs the sim — it renders a streamed position feed and derives facing/animation
locally. Server authority is confined to the one place it's needed (hit outcomes).

## Transferable engineering

What a reviewer should take from it, independent of Roblox:

| In this repo | The general skill |
|---|---|
| jecs world, cached archetype queries in hot loops | **data-oriented ECS** design & cache-friendly iteration |
| Dense-slot, no-id, i8 fixed-point deltas + snapshots | **hand-packed binary protocol design** & bandwidth/quantization budgeting |
| Server owns hit outcomes; client renders a stream | **authoritative simulation / presentation split** |
| Pooled uniform-grid spatial hash | **spatial partitioning: O(N²) → O(N·k) broad-phase** |
| Render LOD + nearest-N budget + pooling everything | **frame-budget engineering & instance-churn control** |
| Microprofiler → LuaBridge write-count → batching | **profile-driven optimization (measure, don't guess)** |
| Reactive steering + separation + arrival/surround | **emergent crowd behavior without per-agent pathfinding** |
| Multi-phase scheduler (deterministic system order) | **tick/frame pipeline design** |

## Tech stack & tooling

- **Luau** (strict) on Roblox · **[jecs](https://github.com/ukendio/jecs)** ECS (pinned 0.9.0)
- **[Blink](https://github.com/1Axen/blink)** networking IDL (binary codegen; never hand-edited)
- **[Rojo](https://rojo.space/)** filesystem ↔ Studio sync · **[Rokit](https://github.com/rojo-rbx/rokit)** toolchain manager · **[Wally](https://wally.run/)** packages
- **[Lune](https://github.com/lune-org/lune)** for headless Luau compile-checks

## Build / run

1. `rokit install` — pulls the toolchain (Rojo, Blink, Lune, …) from `rokit.toml`.
2. `wally install` — restores `Packages/` (pinned in `wally.lock`).
3. Regenerate the net layer if `Net.blink` changed: `blink Net.blink` (writes the generated
   `src/std/ClientNet.luau` + `src/ServerScriptService/ServerNet.luau` — don't hand-edit those).
4. `rojo serve`, connect the Rojo Studio plugin, and press Play. An in-Studio dev panel spawns
   packs / stress-tests up to ~2,000 mobs and toggles the wave loop; a perf HUD shows FPS, live mob
   count, and the LOD split.

## Status & honest limits

- **Prototype, actively developed.** It's a pivot from a prior Vampire-Survivors-style horde game,
  reusing the scale-engineering "bones" (ECS, networking, rendering) for a new combat direction; the
  old game's systems have been pruned from the tree (they remain in git history).
- Performance is validated in Studio (server + client on one machine); the scale target is *hundreds
  of living mobs at 60 FPS*, and some tuning is still per-playtest rather than load-tested with
  multiple live clients.
- A few pieces are placeholders pending art/content (some enemy animations, a chain-lightning beam
  VFX) or a later system (a couple of upgrade effects need a player-HP model). These are called out
  in [`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md).
