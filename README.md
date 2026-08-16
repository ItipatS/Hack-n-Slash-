# Bullet Heaven — Server-Authoritative Horde at Scale

A Vampire-Survivors-style **bullet-heaven** where the **server owns movement, collision,
damage, and death** for a live horde — **1,000-enemy ship cap, validated to ~3,000 at ~85 FPS**
— a scale *and* a kind of authority Roblox is widely assumed to be incapable of. Built on a
data-oriented **ECS (JECS)** with a hand-rolled binary network protocol.

> **Why this is in a portfolio — the engine doesn't matter.** Roblox is just the runtime here.
> Everything that makes this hard is platform-agnostic **systems engineering**: a data-oriented
> entity-component-system, an authoritative simulation/replication split, hand-packed binary
> deltas, spatial-hash broad-phase collision, formula-based ("send the intent, not the state")
> netcode, and a uniform *apply → resolve → query* data flow with table-driven dispatch. The
> same architecture drops onto Unity DOTS, Bevy, an authoritative Node game server, or a custom
> engine — the names change, the engineering doesn't. See **[Transferable engineering](#transferable-engineering-the-point)**.

Deep dives: **[`docs/SPEC.md`](docs/SPEC.md)** (the scale story + measured perf) ·
**[`docs/STATS.md`](docs/STATS.md)** (the data/stat architecture).

## Demo
Two published places off one codebase — hop between them with an in-game button:
- **▶ Real game:** https://www.roblox.com/games/79858913774130
- **🎬 1000-mob showcase:** https://www.roblox.com/games/101281382095901 
- **Video:** [![Watch the video](https://img.youtube.com/vi/APy7ou8omgM/0.jpg)](https://youtu.be/APy7ou8omgM)

> The video shows an earlier build; the current one is the server-authoritative bullet-heaven below.

---

## What it proves

- **Roblox can run a thousand+ *server-authoritative* enemies at interactive framerates** — the
  server decides every mob's movement, every hit, and every death (you can actually lose). Most
  platform "horde" games fake this with client-only cosmetic mobs or cap at ~50–200.
- A **data-oriented ECS + the right spatial/replication stack beats the idiomatic per-NPC model
  by 20–60×.** The same game built the "normal" way (R6 rig + `Humanoid` + per-mob A\* + per-mob
  raycasts + per-entity replication) **died at ~150 mobs**.
- **At horde scale the GPU is a non-issue** — it's a *logic + bandwidth* problem, and both were
  made cheap. The remaining headroom is all in controllable systems, not the renderer.

## Why it's hard

The idiomatic Roblox NPC is a `Model` + `Humanoid` carrying its own state machine, pathfinder,
and physics — practical ceiling ~50–200. The wall isn't *drawing* the horde; it's **deciding and
streaming** a thousand enemies' steering, neighbor collisions, and damage *every tick*, without
melting the server CPU or the wire, **while the player can die**. Server authority is the hard
mode — single-player or cosmetic-only it's invisible; in PvE-with-death it's the whole point.

## Measured (Studio play-test; a shipped client runs higher)

| Scenario | Result |
|---|---|
| Idiomatic template ceiling (rigs + per-mob A\*/raycasts) | **~150 mobs** |
| 10,000 cheap visuals drawn (static) | **147 FPS**, GPU **~1 ms** |
| 1,000 piled on the player → with spatial separation | **25 → 96 FPS** |
| 1,500 server-authoritative + streaming | **145 idle / 124 moving** (was 61 / 5) |
| **3,000 mobs, validated** | **~85 FPS, moving *and* still** |

**Ships at a 1,000-mob design cap** — deliberately, not as a limit: at a thousand the bottleneck
shifts from mob count to *projectiles + combat resolution*, which is where a bullet-heaven's load
*should* live. The horde tech is proven well past the gameplay it's asked to carry.

## How — one technique per order of magnitude

- **Render** — the client is **pure presentation**: a recycled rig pool moved by batched
  transforms. Drawing 10k is free (147 FPS); the only cost is *applying* transforms, so they're
  batched. The validated single-`Part` pool proved the ceiling; the playable build pools richer
  rigs on the same driver — a drop-in swap when raw scale matters.
- **Nav** — a **flow field** (one multi-source Dijkstra flood per tick from the players' nodes) →
  **O(1) next-hop per mob** instead of per-mob A\*; Y interpolated **along the graph edge** so
  mobs hug ramps/drops with **zero per-mob raycasts** and never sink under the map.
- **Collision / separation** — a pooled **uniform-grid spatial hash** → **O(N·k)** neighbor
  queries instead of O(N²), rebuilt each tick and reused for bullet hits *and* crowd separation.
- **Bullets** — **formula projectiles**: broadcast `{origin, velocity, t0}` once; both ends
  compute `pos = origin + velocity·(now − t0)` off a server-synced clock (≈0 wire per bullet);
  the server tests them against the hash for **authoritative** damage.
- **Replication** — **dense-slot, no-id, i8 deltas**: positions stream in *slot order* (the
  client maps slot→entity once from the spawn payload), each axis a signed byte of fixed-point
  motion, with periodic absolute snapshots to clear drift. Dropping the per-mob `u32` id and
  quantizing to bytes is what keeps 1,000 moving bodies cheap on the wire.

## It's a game, not a tech demo

A **main menu** gates the run; a **wave spawner** ramps hordes with **elite/boss spikes** and a
**UFO flying enemy** (ignores pathfinding — hovers at range with laser bolts, or a slow
player-tracking beam when elite/boss). Kills feed **XP & leveling** → a **card picker** (player
stats / pet upgrades / passive items). You take **one main pet** into a run from a **collection
of 11**, and grow the loadout *in-run* (up to 10 weapons) via new-weapon cards and **boss/elite
pet drops**.

Each pet is a **distinct archetype** with a signature ultimate:

| Pet | Archetype | Ultimate |
|---|---|---|
| Axolotl | piercing projectiles | **Nova** — full ring of bolts |
| Fox | ricochet/chain projectiles | **Barrage** — wide aimed burst |
| Cat | boomerang projectiles (out + back) | **Nine Lives** — boomerang storm |
| Slime / Cow | damage aura | **Quake** — big pulse |
| Bear | melee cone + HP sustain | **Roar** — knockback + heal |
| Mole / Elephant | stone drops on the crowd | **Avalanche** — staggered drops |
| Panda | **bamboo** ground hazards (interference lattice + knockback) | **Giant Bamboo** |
| Unicorn | **rainbow puddle** (DoT + slow) | **Taste the Rainbow** — sweeping aim-tracked beam |
| Turtle | orbiting **shells** + passive armor/thorns | **Shell Nova** — i-frames + radial shove |

Backed by combat primitives — **slow/DoT ground hazards, a sweeping beam, orbiting shells,
armor / thorns / regen / brief invulnerability, knockback, crit, hit-flash** — and an economy:
**passive items**, a **Tix** meta-currency that **persists across sessions via DataStore**
(alongside the owned-pet collection, chosen main, and lifetime best-stats), boss/elite **card
packs** and **pet drops**, and a **Tix shop**. Every drop — XP, hearts, Tix, card packs, pets — is
**per-player instanced**, so co-op loot is never a race: each player gets their own copy and full
rewards. Plus **mobile support** (on-screen aim stick, resolution-scaled HUD). A full
survive-and-build loop, all server-authoritative.

## Architecture

```
ReplicatedStorage/std/   shared: ECS world, components, scheduler/phases, spatial hash,
                         flow field, pathfinder, config, registries, the generated client net,
                         and the resolver modules (statuses, playerBuffs)
ServerScriptService/     authoritative systems (auto-loaded per folder):
  systems/horde          one batch loop: flow-field steer + hash separation + edge-Y + streaming
  systems/ufo            flying-enemy brain (hover/bolt/beam) on its own stream
  systems/combat         pet auto-fire, formula-bubble sim vs the hash, hazards/beam/orbit,
                         crit, contact + ranged damage, death/rewards
  systems/statuses       mob status resolver  (raw Slow → derived SpeedMul)
  systems/playerBuffs    player modifier resolver (gear + items + timed buffs → PlayerMods)
  systems/{exp,progression,profile,...drops,players}  XP/cards, DataStore, drops, spawn gating
ClientSystems/           pure-presentation renderers + UI (sync* + HUD/menu/panels), reading a
                         single client mirror (std/clientState) instead of Blink directly
```

The codebase converges on one shape everywhere — **apply → resolve → query, with table-driven
dispatch** — so adding content is *adding a row or a component field*, never extending a branch
ladder:

- **Resolvers, not inline derivation.** An effect is *applied* in one place; a dedicated system
  *resolves* it (expire + aggregate) into a **derived ECS component**; consumers `world:get` that
  component. Mob slows resolve to `SpeedMul` (read by movement); player gear + passive items +
  timed buffs resolve to `PlayerMods` (read by the entire combat damage *and* firing path).
  Nothing re-derives "is this active / what's the effective value" at the call site.
- **Table dispatch, not branch ladders.** Weapon firing is `KIND_FIRE[kind]`, ultimates are
  `SKILLS[pet]`, buff math is `BUFF_KIND[kind] = {field, op}` — each with a sane fallback so a
  new/typo'd key is never a silent no-op.
- **Single source of truth.** `std/petRegistry.luau` (pet data) and `std/itemRegistry.luau` feed
  both the UI and the real combat math, so the panel and the simulation can never drift.
- **One mirror on the client, too.** Player-data events land in a single `std/clientState` store —
  the *only* Blink listener for each — and HUD widgets *subscribe* to it rather than each listening
  themselves. So no event needs more than one listener, and each value (hp, weapons, Tix…) lives in
  one place: the same single-source discipline as the server resolvers, on the presentation side.
- **Networking** via **Blink** — a binary IDL that generates the (never-hand-edited) buffer
  packing: formula projectiles, dense position deltas, periodic snapshots, and compact event
  channels for hazards / skills / drops / currency.

Full pipeline write-up: **[`docs/STATS.md`](docs/STATS.md)**.

## Transferable engineering (the point)

What a reviewer should read past "it's Roblox" and see:

| In this repo | The general skill |
|---|---|
| JECS world, archetype queries, `:cached()` hot loops | **data-oriented ECS** design & cache-friendly iteration |
| Server owns HP/hits/death; client renders only | **authoritative simulation / presentation split** (anti-cheat-shaped) |
| Dense-slot, no-id, i8 fixed-point deltas + snapshots | **hand-packed binary protocol design** & quantization/bandwidth budgeting |
| `pos = origin + vel·(now−t0)` on a synced clock | **formula/event netcode** — replicate intent, compute on both ends |
| Pooled uniform-grid spatial hash | **spatial partitioning / O(N²) → O(N·k) broad-phase** |
| Flow field (multi-source Dijkstra) → O(1) next-hop | **shared-cost pathfinding at crowd scale** |
| `apply → resolve → query` resolvers + dispatch tables | **decoupled, data-driven architecture** that scales by addition, not branching |
| Phase scheduler (deterministic system order) | **frame/tick pipeline design** |

None of these are engine features — they're the engineering. Roblox just happens to be where it
runs.

## Tech stack & tooling

- **Luau** on Roblox · **[JECS](https://github.com/ukendio/jecs)** ECS (pinned 0.9.0)
- **[Blink](https://github.com/1Axen/blink)** networking IDL (binary codegen; never hand-edited)
- **[Rojo](https://rojo.space/)** filesystem ↔ Studio sync · **[Rokit](https://github.com/rojo-rbx/rokit)** toolchain manager
- **[Lune](https://github.com/lune-org/lune)** for headless Luau syntax/compile checks
- A non-Rodux subset of an in-house UI framework lives in `std/` (tag-driven UI traits, device
  detection, formatting/tween/SFX helpers).

## Build / run

1. Install the toolchain: `rokit install` (pulls Rojo, Blink, Lune, etc. from `rokit.toml`).
2. Regenerate the network layer if `Net.blink` changed: `blink Net.blink` →
   `src/std/ClientNet.luau` + `src/ServerScriptService/ServerNet.luau` (generated; don't hand-edit).
3. Sync to Studio: `rojo serve` and connect the Rojo Studio plugin.
4. Press Play. The game ships as **two published places off one codebase**: a **showcase** place
   (auto-enables `STRESS_TEST` + `INVINCIBLE` + `SHOW_FPS` → ~1000 mobs on join, invincible, FPS
   overlay = "1000 mobs, no lag") and a **real-game** place (those off → ramped, losable, clean).
   `config.luau` picks the mode from `game.PlaceId` (no hand-flipping), and the menu has a button
   that teleports between them. Set `FORCE_SHOWCASE` in `config.luau` to test either mode in Studio.

## Honest limits

- Numbers are Studio play-tests (server + client on one machine); a shipped client runs higher.
- Raw 10,000 mobs is the **last mile** — render LOD/throttle on the client; the *server*
  simulation and the dense-slot wire format already carry it.
- Single-player is the verified path; co-op is designed in (all state is per-player) but not yet
  load-tested with multiple live clients.
