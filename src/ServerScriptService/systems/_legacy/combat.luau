-- ServerScriptService/systems/combat.luau
-- Server-authoritative combat. Per tick: build the spatial hash once, run every weapon by
-- KIND, step projectiles, resolve stone-drop impacts, process deaths, then player contact
-- damage. All damage is authoritative; hits also apply KNOCKBACK (a Knock impulse the horde
-- decays). Death makes the player a GHOST for the rest of the round (they spectate, can't
-- rejoin); the round ends — wiping the horde + drops — only when the LAST living player falls.
--!optimize 2
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players             = game:GetService("Players")

local blink = require(ServerScriptService.ServerNet)
local std   = ReplicatedStorage.std

local world       = require(std.world)
local cts         = require(std.components)
local ref         = require(std.ref)
local scheduler   = require(std.scheduler)
local phases      = require(std.phases)
local SpatialHash = require(std.spatialhash)
local Config      = require(std.config)
local Pet         = require(std.pet)
local Statuses    = require(std.statuses)
local PlayerBuffs = require(std.playerBuffs)
local Obstacles   = require(std.obstacles) -- ice walls: mob-blocking segments the horde respects
local PlayerState = require(std.playerState)
local Registry    = require(std.petRegistry)
local Exp         = require(script.Parent.exp)
local Progress    = require(script.Parent.progression)
local SpawnHost   = require(script.Parent.SpawnMob)
local PetDrops    = require(script.Parent.petdrops)
local CardDrops   = require(script.Parent.carddrops)
local HealthDrops = require(script.Parent.healthdrops)
local TixDrops    = require(script.Parent.tixdrops)
local Profile     = require(script.Parent.profile)
local Chars       = require(script.Parent.players) -- character lifecycle: warpIn / refreshLobby

local Transform = cts.Transform
local Mob       = cts.Mob
local Health    = cts.Health
local Size      = cts.Size
local Character  = cts.Character
local Player     = cts.Player
local Elite      = cts.Elite
local Boss       = cts.Boss
local Knock      = cts.Knock
local Slot       = cts.Slot
local PlayerMods = cts.PlayerMods

-- Fallback modifier set used by damagePlayers if a player's PlayerMods isn't resolved yet (~never — the
-- resolver runs in AIStateMachine before Combat). Fail CLOSED: no armor / no invuln so the player still
-- takes damage. NEVER fail open to "invincible" — that footgun was masked while Debug.INVINCIBLE was on.
local DEFAULT_MODS = {
    invuln = false, armor = 0, reflect = 0, regen = 0, walkSpeed = 16,
    damage = 0, crit = 0, critDmg = 0, atkSize = 1, knock = 1, haste = 1, skillCd = 1, onHitSlow = 1, explodeR = 0,
}

-- ── Tunables ──────────────────────────────────────────────────────────────────
local Y_TOL2        = 6 * 6
-- Mob collision scales with the mob's visual size: a big boss should be hittable across its whole
-- body, not just a point at its centre. Effective hit radius = attackRadius + (size-1)*R_PER_SIZE,
-- and the vertical tolerance grows with size (and with hover height, so flyers are reachable too).
local R_PER_SIZE    = 1.4
local CONTACT_BASE  = 4.5  -- base player-contact distance, before adding the mob's body radius
local EXP_PER_KILL  = 2
local ELITE_EXP     = 10
local HASH_CELL     = 8
local COMBAT_TICK   = 1 / 30
local PER_MOB_DPS   = 5
local MAX_CONTACTS  = 6
local HP_SEND       = 1 / 6
local DROP_DELAY    = 0.8
local SAMPLE        = 16
local DENSE_R2      = 8 * 8
local SPLIT_N       = 3
local CHAIN_R2      = 18 * 18  -- fox ricochet: max distance to the next bounce target
local SPLIT_SPREAD  = math.rad(60)
local SPLIT_FRAC    = 0.5
local SPLIT_R2      = 2 * 2
local SPLIT_LIFE    = 0.5
local SPLIT_SPEED   = 55
local FX_AURA, FX_MELEE, FX_DROP, FX_TONGUE, FX_EXPLODE = 1, 2, 3, 4, 5
local HZ_PUDDLE, HZ_ICE, HZ_WALL = 1, 4, 5 -- hazard visual kinds (2/3 = bamboo/giant); ice patch / ice WALL
local WALL_LIFE = 4.0 -- seconds a Glacier Wall stands (blocking + visual share this)
local ZERO = Vector3.zero
local BLEED_DUR = 2.0  -- seconds a melee bleed (w.dot) ticks on the bitten mob
local HOWL_DUR  = 5.0  -- wolf Pack Howl team-buff duration
local ONHIT_SLOW_DUR = 1.5 -- seconds an on-hit slow lasts (one-shot; hazards/beams refresh theirs every tick)

-- ── State ─────────────────────────────────────────────────────────────────────
local hash = SpatialHash.new(HASH_CELL)
local queryOut: { number } = {}
local aoeOut: { number } = {} -- separate buffer for burst-on-hit (must not clobber queryOut mid-loop)
local posCache: { [number]: Vector3 } = {}
local mobR:     { [number]: number } = {}  -- per-mob XZ hit-radius bonus (scales with Size)
local mobYt:    { [number]: number } = {}  -- per-mob vertical hit tolerance (Size + hover height)
local mobSample: { Vector3 } = {}

type Bubble = {
    id: number, ox: number, oy: number, oz: number, vx: number, vy: number, vz: number, t0: number,
    pierce: number, baseDmg: number, critChance: number, critDamage: number,
    r2: number, br: number, life: number, split: number, knock: number, color: Vector3, hits: { [number]: boolean },
    aoe: number, splitPierce: boolean, -- weapon-level upgrades: burst-on-hit radius / piercing splits
    boomerang: boolean?, chain: number?, returned: boolean?, -- cat (returns) / fox (ricochets)
    slow: number?, -- on-hit slow factor (<1 = hits chill the mob; weapon slowFactor × mods.onHitSlow) BUL-47
    -- on-land hook (BUL-48): when the bubble retires (expiry OR pierce out), splash a hazard there.
    -- Mods are folded in at fire time; primaries only (splits/ricochets/returns don't re-splash).
    land: { kind: number, r: number, dmg: number, knock: number, cc: number, cd: number,
            slowFactor: number, tickEvery: number, life: number }?,
    -- ice trail (penguin): every `every`s of flight, drop a short freeze patch at the bubble's position
    trail: { every: number, r: number, slowFactor: number, life: number }?, nextTrail: number?,
}
local bubbles: { Bubble } = {}
local nextBubbleId = 0

type Drop = { x: number, y: number, z: number, t: number, r2: number, dmg: number, cc: number, cd: number, knock: number }
local pendingDrops: { Drop } = {}

-- per-mob BLEED (wolf bites; any melee weapon with dot>0): dps ticked by bleedStep until untilT.
-- MUST be cleared on death AND on round wipe — jecs recycles entity ids, so a stale entry would
-- bleed a fresh mob that reuses the id (the id-recycling gotcha).
local bleeds: { [number]: { dps: number, untilT: number } } = {}

local aim: { [Player]: Vector3 } = {}
local skillCd: { [Player]: { [number]: number } } = {} -- [plr][slot] = next-allowed server time
-- Players who DIED in the current round → ghosts. Locked out of rejoining until the round ends
-- (the last living player falls); endRoundIfEmpty clears this and broadcasts RoundOver.
local ghosts: { [Player]: boolean } = {}

local fireBatch: { blink.BubbleFire } = {}
local effectBatch: { blink.EffectMsg } = {}
local dead: { [number]: boolean } = {}
local deathIds: { number } = {}
local hitSet: { [number]: boolean } = {} -- mobs damaged-but-survived this tick (cosmetic flash)
local hitIds: { number } = {}
local HIT_CHUNK = 180 -- keep each unreliable Hit packet under the ~900B cap
local spentBubbles: { number } = {} -- bubble ids retired early (pierce used up) → tell the client
local healthBatch: { blink.MobHp } = {} -- elite/boss HP → client health bars (tiny set)

-- ── Ground hazards (puddles / bamboo) + ult beams ────────────────────────────────
-- A hazard is a persistent ground AoE that ticks damage (and optional slow/knock) for its life.
-- Server owns the damage; the client renders the visual from HazardSpawn/HazardRemove.
type Hazard = {
    id: number, x: number, y: number, z: number, r: number, r2: number,
    dmg: number, knock: number, cc: number, cd: number,
    slowFactor: number, slowDur: number, tickEvery: number, nextTick: number, untilT: number,
}
local hazards: { Hazard } = {}
local nextHazardId = 0
local hazardSpawnBatch: { blink.HazardMsg } = {}
local hazardRemoveBatch: { number } = {}
-- unicorn ult beam (owner sweeps it via local aim; server damages from the streamed aim)
type Beam = { untilT: number, dmg: number, slowFactor: number, width: number, length: number }
local beams: { [Player]: Beam } = {}
local BEAM_STEP = 6   -- studs between beam damage samples
local SLOW_TICK = 0.1 -- how often a hazard/beam re-applies its slow (refreshes the expiry)

blink.Aim.On(function(plr, dir) aim[plr] = dir end)

local zombies    = world:query(Transform, Health, Size):with(Mob):cached()
local characters = world:query(Character, Player):cached()
local bossMobs   = world:query(Health):with(Mob, Boss):cached()  -- for the boss/elite health bars
local eliteMobs  = world:query(Health):with(Mob, Elite):cached()

-- Flush a per-tick accumulation batch over the wire: one packet if non-empty, then reset. Only for the
-- plain "FireAll the whole table" sends — the chunked (packet-cap) / filtered sends stay bespoke.
local function flush<T>(event: any, batch: { T })
    if #batch > 0 then event.FireAll(batch); table.clear(batch) end
end

-- ── Damage primitives (kx,kz = knockback impulse) ────────────────────────────────
local function hurt(ze: number, dmg: number, kx: number, kz: number)
    if dead[ze] then return end
    local h = world:get(ze, Health)
    if not h then return end
    local hp = h.hp - dmg
    if hp <= 0 then
        dead[ze] = true
    else
        h.hp = hp
        world:set(ze, Health, h)
        hitSet[ze] = true
        if kx ~= 0 or kz ~= 0 then
            local cur = world:get(ze, Knock)
            world:set(ze, Knock, Vector3.new((if cur then cur.X else 0) + kx, 0, (if cur then cur.Z else 0) + kz))
        end
    end
end

local function rollDmg(dmg: number, cc: number, cd: number): number
    return if math.random() < cc then dmg * cd else dmg
end

-- the firing weapon's color as the wire vector (EffectMsg.color) — FX tint per pet
local function wcol(w: any): Vector3
    local c = w.color
    return if c then Vector3.new(c.R, c.G, c.B) else Vector3.new(1, 1, 1)
end

local function aoeDamage(cx, cy, cz, r2, dmg, cc, cd, knock)
    local baseR = math.sqrt(r2)
    local cnt = hash:queryInto(cx, cy, cz, queryOut)
    for j = 1, cnt do
        local ze = queryOut[j]
        if not dead[ze] then
            local p = posCache[ze]
            if p then
                local dx, dz = p.X - cx, p.Z - cz
                local d2 = dx * dx + dz * dz
                local reach = baseR + (mobR[ze] or 0)
                local yt = mobYt[ze] or 6
                if d2 <= reach * reach and (p.Y - cy) ^ 2 <= yt * yt then
                    local kx, kz = 0, 0
                    if knock > 0 and d2 > 1e-3 then
                        local inv = knock / math.sqrt(d2); kx, kz = dx * inv, dz * inv
                    end
                    hurt(ze, rollDmg(dmg, cc, cd), kx, kz)
                end
            end
        end
    end
end

-- bleedDps (optional, >0): every mob the cone hits also starts BLEEDING for BLEED_DUR (refresh on re-hit;
-- keep the stronger dps so a leveled bite never gets overwritten by a weaker spirit-wolf sweep).
local function coneDamage(cx, cy, cz, ax, az, r2, cosHalf, dmg, cc, cd, knock, bleedDps: number?)
    local baseR = math.sqrt(r2)
    local now = if bleedDps and bleedDps > 0 then workspace:GetServerTimeNow() else 0
    local cnt = hash:queryInto(cx, cy, cz, queryOut)
    for j = 1, cnt do
        local ze = queryOut[j]
        if not dead[ze] then
            local p = posCache[ze]
            if p then
                local dx, dz = p.X - cx, p.Z - cz
                local d2 = dx * dx + dz * dz
                local reach = baseR + (mobR[ze] or 0)
                if d2 <= reach * reach and d2 > 1e-3 and (p.Y - cy) ^ 2 <= (mobYt[ze] or 6) ^ 2 then
                    local inv = 1 / math.sqrt(d2)
                    if (dx * inv) * ax + (dz * inv) * az >= cosHalf then
                        hurt(ze, rollDmg(dmg, cc, cd), dx * inv * knock, dz * inv * knock)
                        if bleedDps and bleedDps > 0 and not dead[ze] then
                            local cur = bleeds[ze]
                            if cur then
                                cur.dps = math.max(cur.dps, bleedDps)
                                cur.untilT = now + BLEED_DUR
                            else
                                bleeds[ze] = { dps = bleedDps, untilT = now + BLEED_DUR }
                            end
                        end
                    end
                end
            end
        end
    end
end

-- tick active bleeds; drop expired/dead entries (death also clears in processDeaths — both paths
-- matter because a mob can die from something else between our ticks).
local function bleedStep(now: number, dt: number)
    for ze, b in bleeds do
        if now >= b.untilT or dead[ze] then
            bleeds[ze] = nil
        else
            hurt(ze, b.dps * dt, 0, 0)
        end
    end
end

-- apply a Slow (factor<1) to every mob within r2 of (x,z); refreshes expiry to now+dur. Effects are
-- owned by std/statuses — we only hand it the raw (entity, factor, untilT); it derives the SpeedMul
-- that movement reads. (No-op for factor>=1 so callers can pass a neutral slow unconditionally.)
local function applySlow(x: number, y: number, z: number, r2: number, factor: number, dur: number, now: number)
    if factor >= 1 then return end
    local cnt = hash:queryInto(x, y, z, queryOut)
    for j = 1, cnt do
        local ze = queryOut[j]
        local p = posCache[ze]
        if p and not dead[ze] then
            local dx, dz = p.X - x, p.Z - z
            if dx * dx + dz * dz <= r2 then
                Statuses.slow(ze, factor, now + dur)
            end
        end
    end
end

-- spawn a persistent ground hazard (puddle/bamboo): ticks dmg (+knock/slow) for `life`s. kind drives
-- the client visual (1 puddle, 2 bamboo, 3 giant bamboo).
local function spawnHazard(kind: number, x: number, y: number, z: number, r: number, dmg: number,
                           knock: number, cc: number, cd: number, slowFactor: number,
                           tickEvery: number, life: number)
    nextHazardId += 1
    local now = workspace:GetServerTimeNow()
    hazards[#hazards + 1] = {
        id = nextHazardId, x = x, y = y, z = z, r = r, r2 = r * r,
        dmg = dmg, knock = knock, cc = cc, cd = cd,
        slowFactor = slowFactor, slowDur = tickEvery + 0.2, tickEvery = tickEvery,
        nextTick = now, untilT = now + life,
    }
    hazardSpawnBatch[#hazardSpawnBatch + 1] =
        { id = nextHazardId, kind = kind, pos = Vector3.new(x, y, z), radius = r, life = life }
end

local function hazardStep(now: number)
    local write = 1
    for i = 1, #hazards do
        local hz = hazards[i]
        if now >= hz.nextTick then
            hz.nextTick = now + hz.tickEvery
            aoeDamage(hz.x, hz.y, hz.z, hz.r2, hz.dmg, hz.cc, hz.cd, hz.knock)
            applySlow(hz.x, hz.y, hz.z, hz.r2, hz.slowFactor, hz.slowDur, now)
        end
        if now < hz.untilT then
            hazards[write] = hz; write += 1
        else
            hazardRemoveBatch[#hazardRemoveBatch + 1] = hz.id
        end
    end
    for i = #hazards, write, -1 do hazards[i] = nil end
end

-- unicorn ult: a sweeping beam. The owner renders it from local aim (UltBeam); the server damages
-- along the streamed aim each tick. `dmg` is a DPS (scaled by dt per tick).
local function startBeam(plr: Player, life: number, dmg: number, slowFactor: number, width: number, length: number)
    local now = workspace:GetServerTimeNow()
    beams[plr] = { untilT = now + life, dmg = dmg, slowFactor = slowFactor, width = width, length = length }
    blink.UltBeam.Fire(plr, { active = 1, life = life, width = width, length = length })
end

local function beamStep(now: number, dt: number)
    for plr, bm in beams do
        if now >= bm.untilT or not PlayerState.get(plr).playing then beams[plr] = nil; continue end
        local char = plr.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then continue end
        local mods = world:get(ref(plr.UserId), PlayerMods)
        if not mods then continue end
        local pos = (root :: BasePart).Position
        -- 3D aim: the beam follows VERTICAL pitch too (the streamed aim is player→cursor in 3D), so it
        -- can sweep up at flying UFOs / down — not just along the ground plane.
        local ax, ay, az = 0, 0, 1
        local dir = aim[plr]
        if dir then
            local m = dir.Magnitude
            if m > 1e-3 then ax, ay, az = dir.X / m, dir.Y / m, dir.Z / m end
        end
        local r2 = bm.width * bm.width
        local cc, cd = mods.crit, mods.critDmg
        local tick = bm.dmg * dt -- DPS → per-tick
        for s = 1, math.floor(bm.length / BEAM_STEP) do
            local d = s * BEAM_STEP
            local sx, sy, sz = pos.X + ax * d, pos.Y + ay * d, pos.Z + az * d
            aoeDamage(sx, sy, sz, r2, tick, cc, cd, 0)
            applySlow(sx, sy, sz, r2, bm.slowFactor, SLOW_TICK + 0.2, now)
        end
    end
end

local function densestPoint(): Vector3?
    local best: Vector3?, bestN = nil, -1
    for _, p in mobSample do
        local cnt = hash:queryInto(p.X, p.Y, p.Z, queryOut)
        local c = 0
        for j = 1, cnt do
            local q = posCache[queryOut[j]]
            if q then
                local dx, dz = q.X - p.X, q.Z - p.Z
                if dx * dx + dz * dz <= DENSE_R2 then c += 1 end
            end
        end
        if c > bestN then bestN = c; best = p end
    end
    return best
end

-- ── Summons (temporary auto-firing entities) — BUL-45 ────────────────────────────
-- A summon is a short-lived, server-owned emitter: it sits at a position (optionally drifting),
-- fires a pattern on its own cadence, then despawns. The pattern is a caller-supplied closure that
-- reuses the normal combat helpers (spawnBubble / aoeDamage / coneDamage), so a summon's SHOTS are
-- visible through the existing bubble/effect channels — the summon BODY needs no model/replication.
-- First consumers: Bee's Hive (stationary turret) and Wolf's Pack Howl (drifting melee).
type Summon = {
    id: number, kind: number,     -- kind drives the client placeholder visual (1 hive, 2 spirit wolf)
    ownerId: number,              -- UserId that spawned it (dropped on death / leave / round end)
    x: number, y: number, z: number,
    vx: number, vz: number,       -- studs/sec drift on XZ (0,0 = stationary turret)
    fireEvery: number, nextFire: number, untilT: number,
    fire: (Summon, number) -> (), -- (self, now): run the pattern off self.x/self.y/self.z
}
local summons: { Summon } = {}
local nextSummonId = 0
local summonSpawnBatch: { blink.SummonMsg } = {}
local summonRemoveBatch: { number } = {}

-- Spawn a summon at (x,y,z). vx/vz drift in studs/sec (0 for a turret); fireEvery = seconds between
-- pattern fires; life = seconds before despawn. First fire lands on the next combat tick. The client
-- renders it from ONE SummonSpawn (formula position: origin + velocity*(now-t0)) — no streaming.
local function spawnSummon(ownerId: number, kind: number, x: number, y: number, z: number, vx: number, vz: number,
                           fireEvery: number, life: number, fire: (Summon, number) -> ())
    local now = workspace:GetServerTimeNow()
    nextSummonId += 1
    summons[#summons + 1] = {
        id = nextSummonId, kind = kind, ownerId = ownerId, x = x, y = y, z = z, vx = vx, vz = vz,
        fireEvery = fireEvery, nextFire = now, untilT = now + life, fire = fire,
    }
    summonSpawnBatch[#summonSpawnBatch + 1] = {
        id = nextSummonId, kind = kind, origin = Vector3.new(x, y, z),
        velocity = Vector3.new(vx, 0, vz), t0 = now, life = life,
    }
end

-- Drop every summon owned by `ownerId` (player death / leave). Order-preserving compaction.
local function clearSummons(ownerId: number)
    local write = 1
    for i = 1, #summons do
        local s = summons[i]
        if s.ownerId ~= ownerId then
            summons[write] = s; write += 1
        else
            summonRemoveBatch[#summonRemoveBatch + 1] = s.id -- early clear → client despawns now
        end
    end
    for i = #summons, write, -1 do summons[i] = nil end
end

-- Per tick: drift moving summons, fire those due, drop the expired. Runs right after fireStep so a
-- summon's shots are stepped by bubbleStep the same tick. (Expiry needs no remove send — the client
-- self-expires by life; SummonRemove is only for EARLY clears.)
local function summonStep(now: number, dt: number)
    local write = 1
    for i = 1, #summons do
        local s = summons[i]
        if s.vx ~= 0 or s.vz ~= 0 then
            s.x += s.vx * dt
            s.z += s.vz * dt
        end
        if now >= s.nextFire then
            s.nextFire = now + s.fireEvery
            s.fire(s, now)
        end
        if now < s.untilT then
            summons[write] = s; write += 1
        end
    end
    for i = #summons, write, -1 do summons[i] = nil end
end

-- ── Bubbles ──────────────────────────────────────────────────────────────────
local function rotateY(v: Vector3, ang: number): Vector3
    local c, s = math.cos(ang), math.sin(ang)
    return Vector3.new(v.X * c - v.Z * s, v.Y, v.X * s + v.Z * c)
end

local function pushBubble(now, ox, oy, oz, vx, vy, vz, dmg, pierce, r2, life, color: Vector3, split, knock, cc, cd, aoe, splitPierce)
    nextBubbleId += 1
    bubbles[#bubbles + 1] = {
        id = nextBubbleId, ox = ox, oy = oy, oz = oz, vx = vx, vy = vy, vz = vz, t0 = now,
        pierce = pierce, baseDmg = dmg, critChance = cc, critDamage = cd,
        r2 = r2, br = math.sqrt(r2), life = life, split = split, knock = knock, color = color, hits = {},
        aoe = aoe or 0, splitPierce = splitPierce or false,
    }
    fireBatch[#fireBatch + 1] = {
        id = nextBubbleId, origin = Vector3.new(ox, oy, oz), velocity = Vector3.new(vx, vy, vz),
        t0 = now, life = life, color = color, size = 2 * math.sqrt(r2),
    }
end

-- `mods` is the player's resolved PlayerMods (offensive modifiers already folded: damage/crit/atkSize/knock).
local function spawnBubble(now: number, origin: Vector3, dirUnit: Vector3, w: any, mods: any)
    local v = dirUnit * w.speed
    local col = Vector3.new(w.color.R, w.color.G, w.color.B)
    local radius = w.radius * mods.atkSize -- item attack-size buff (Milk) folded into mods.atkSize
    pushBubble(now, origin.X, origin.Y, origin.Z, v.X, v.Y, v.Z,
        w.dmg * mods.damage, w.pierce, radius * radius, w.life, col,
        w.split, w.knock * mods.knock,
        mods.crit, mods.critDmg,
        -- Explosive Rounds (item): every bullet bursts on hit — take the BIGGER of the weapon's own
        -- blast (bee) and the item's radius, so it adds bombs to ANY pet (reuses bubbleBurst + FX).
        math.max(w.aoeRadius * mods.atkSize, mods.explodeR or 0), w.splitPierce)
    fireBatch[#fireBatch].shape = w.shape -- visual "lane" (1 = ice cube); nil → ball. Secondaries stay balls.
    local b = bubbles[#bubbles] -- tag the just-pushed bubble with archetype behavior
    b.boomerang = w.boomerang or false
    b.chain = w.chain or 0
    b.returned = false
    -- on-hit slow (BUL-47): the weapon's own factor (penguin frost bolts) × the player's item/buff
    -- factor (Frostbite). Both default 1 (no slow); <1 makes every hit chill the mob.
    b.slow = (w.slowFactor or 1) * (mods.onHitSlow or 1)
    -- on-land splash (BUL-48): weapon declares `onLand` (frog) → the bubble carries fully-scaled
    -- hazard params and splashes wherever it retires (lands or pops on its last pierce)
    local ol = w.onLand
    if ol then
        b.land = {
            kind = ol.kind or 1, r = (ol.r or 4) * mods.atkSize,
            dmg = (ol.dmg or 0) * mods.damage, knock = (ol.knock or 0) * mods.knock,
            cc = mods.crit, cd = mods.critDmg,
            slowFactor = ol.slowFactor or 1, tickEvery = ol.tickEvery or 0.4, life = ol.life or 2,
        }
    end
    -- ice trail (penguin): carve a chilled lane behind the cube as it flies
    local tr = w.trail
    if tr then
        b.trail = { every = tr.every or 0.3, r = (tr.r or 3) * mods.atkSize, slowFactor = tr.slowFactor or 0.7, life = tr.life or 1.2 }
        b.nextTrail = now + (tr.every or 0.3) -- first patch a beat out, not under the player's feet
    end
end

-- ── Pet skills (ULTS) ───────────────────────────────────────────────────────────────
-- Metadata (name/desc/cooldown) lives in petRegistry; the EFFECT lives here, keyed by pet id.
-- Each fn: (plr, now, root, w, state, ax, az). Most ignore plr (only beam/invuln need it).
local NOVA_COUNT = 20
local FAN_COUNT  = 14
local AVA_COUNT  = 5

-- fn: (plr, now, root, w, state, mods, ax, az). `mods` = resolved PlayerMods (offensive stats already
-- folded); `state` is only for the hp RESOURCE (bear's heal) — never re-read offensive stats off it.
local SKILLS: { [string]: (Player, number, BasePart, any, any, any, number, number) -> () } = {
    -- Axolotl "Nova": a full ring of piercing bubbles.
    axolotl = function(_plr, now, root, w, state, mods)
        -- fire from the MAIN pet's ACTUAL ring slot (skills only run for the main weapon) — with
        -- 2+ weapons equipped, Pet.pos (slot 0 of 1) is NOT where this pet is rendered
        local origin = Pet.slotPos(root.Position, state.main - 1, #state.weapons)
        local count = NOVA_COUNT + (w.skillBubbles or 0) -- weapon-level upgrades scale the skill
        local times = 1 + (w.skillRepeat or 0)
        for _ = 1, times do
            for i = 1, count do
                local a = (i / count) * (2 * math.pi)
                spawnBubble(now, origin, Vector3.new(math.cos(a), 0, math.sin(a)), w, mods)
            end
        end
    end,
    -- Fox "Barrage": a wide burst of fast (ricocheting) shots where you aim.
    fox = function(_plr, now, root, w, state, mods, ax, az)
        local origin = Pet.slotPos(root.Position, state.main - 1, #state.weapons) -- from the fox's real slot
        local base = Vector3.new(ax, 0, az)
        local count = FAN_COUNT + (w.skillBubbles or 0)
        local times = 1 + (w.skillRepeat or 0)
        for _ = 1, times do
            for i = 0, count - 1 do
                local ang = ((i / math.max(1, count - 1)) - 0.5) * math.rad(120)
                spawnBubble(now, origin, rotateY(base, ang), w, mods)
            end
        end
    end,
    -- Slime "Quake": one big damaging pulse around the player.
    slime = function(_plr, _now, root, w, _state, mods)
        local p = root.Position
        local r = w.radius * 2.0 * mods.atkSize
        aoeDamage(p.X, p.Y, p.Z, r * r, w.dmg * 5 * mods.damage, mods.crit, mods.critDmg, w.knock * 3 * mods.knock)
        effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = p, radius = r, dir = ZERO, color = wcol(w) }
    end,
    -- Mole "Avalanche": several staggered stone drops on the crowd.
    mole = function(_plr, now, root, w, _state, mods)
        for i = 1, AVA_COUNT do
            local tp = densestPoint()
            if tp then
                local jx, jz = math.random() * 16 - 8, math.random() * 16 - 8
                local r = w.radius * mods.atkSize
                pendingDrops[#pendingDrops + 1] = {
                    x = tp.X + jx, y = tp.Y, z = tp.Z + jz, t = now + DROP_DELAY + i * 0.15,
                    r2 = r * r, dmg = w.dmg * mods.damage, cc = mods.crit, cd = mods.critDmg, knock = w.knock * mods.knock,
                }
                effectBatch[#effectBatch + 1] = { kind = FX_DROP, pos = Vector3.new(tp.X + jx, tp.Y, tp.Z + jz), radius = r, dir = ZERO }
            end
        end
    end,
    -- Bear "Roar": radial knockback shockwave + a HEAL burst (bruiser sustain).
    bear = function(_plr, _now, root, w, state, mods)
        local p = root.Position
        local r = w.radius * 1.3 * mods.atkSize
        aoeDamage(p.X, p.Y, p.Z, r * r, w.dmg * 2.5 * mods.damage, mods.crit, mods.critDmg, w.knock * 2.8 * mods.knock)
        state.hp = math.min(state.maxHp, state.hp + state.maxHp * 0.25) -- heal 25% max HP (hp resource stays on state)
        effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = p, radius = r, dir = ZERO, color = wcol(w) }
    end,
    -- Panda "Giant Bamboo": one huge bamboo erupts ahead — big knockback + damage.
    panda = function(_plr, _now, root, w, _state, mods, ax, az)
        local p = root.Position
        local bx, bz = p.X + ax * 14, p.Z + az * 14
        spawnHazard(3, bx, p.Y, bz, (w.radius + 6) * mods.atkSize,
            w.dmg * 3 * mods.damage, (w.knock + 30) * mods.knock, mods.crit, mods.critDmg, 1, 0.25, 2.5)
    end,
    -- Unicorn "Taste the Rainbow": a slow sweeping rainbow beam that tracks aim (Final Spark).
    unicorn = function(plr, _now, _root, w, _state, mods)
        local life = 3.5 + (w.skillBubbles or 0) * 1.5 -- tree extends the beam
        local dps = (w.dot * 3 + 10) * mods.damage
        startBeam(plr, life, dps, math.max(0.4, w.slowFactor), 4, 80)
    end,
    -- Cat "Nine Lives": a storm of boomerangs flung outward in a ring.
    cat = function(_plr, now, root, w, state, mods)
        local origin = Pet.slotPos(root.Position, state.main - 1, #state.weapons) -- from the cat's real slot
        for i = 1, 12 do
            local a = (i / 12) * (2 * math.pi)
            spawnBubble(now, origin, Vector3.new(math.cos(a), 0, math.sin(a)), w, mods)
        end
    end,
    -- Turtle "Shell Nova": brief invulnerability + a huge radial shove (and a damage pulse).
    turtle = function(plr, now, root, w, _state, mods)
        local p = root.Position
        local r = (w.radius + 16) * mods.atkSize
        aoeDamage(p.X, p.Y, p.Z, r * r, w.dmg * 4 * mods.damage, mods.crit, mods.critDmg, (w.knock + 30) * mods.knock)
        PlayerBuffs.apply(plr, "invuln", 0, now + 2.5) -- timed buff → resolved into PlayerMods (combat + ufo read it)
        effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = p, radius = r, dir = ZERO, color = wcol(w) }
    end,
    -- Bee "Hive": deploy stationary turret(s) (summon scaffolding) that lob bomber bees at the nearest
    -- mob for a while. The bombers are normal bee shots — aoeRadius>0 makes them burst on impact — so a
    -- turret has no body model; only its (visible) shots matter. `skillRepeat`→turret count, `skillBubbles`→life.
    bee = function(plr, _now, root, w, _state, mods)
        local p = root.Position
        local turrets = 1 + (w.skillRepeat or 0)
        local life = 6 + (w.skillBubbles or 0) * 2
        local ring = if turrets > 1 then 4 else 0 -- spread multiples so they don't stack on one point
        for t = 1, turrets do
            local a = (t / turrets) * (2 * math.pi)
            local tx, tz = p.X + math.cos(a) * ring, p.Z + math.sin(a) * ring
            spawnSummon(plr.UserId, 1, tx, p.Y, tz, 0, 0, 0.5, life, function(self, snow) -- kind 1 = hive turret
                -- aim the next bomber at the nearest living mob in range (none → hold fire this tick)
                local best: Vector3?, bd2 = nil, math.huge
                local cnt = hash:queryInto(self.x, self.y, self.z, queryOut)
                for j = 1, cnt do
                    local ze = queryOut[j]
                    if not dead[ze] then
                        local q = posCache[ze]
                        if q then
                            local dx, dz = q.X - self.x, q.Z - self.z
                            local d2 = dx * dx + dz * dz
                            if d2 < bd2 then bd2 = d2; best = q end
                        end
                    end
                end
                if best then
                    local dx, dz = best.X - self.x, best.Z - self.z
                    local m = math.sqrt(dx * dx + dz * dz)
                    if m > 1e-3 then
                        spawnBubble(snow, Vector3.new(self.x, self.y, self.z), Vector3.new(dx / m, 0, dz / m), w, mods)
                    end
                end
            end)
        end
    end,
    -- Penguin "Glacier Wall": a REAL ice wall erupts ACROSS your aim — a blocking segment the horde
    -- integrator refuses to cross (std/obstacles), so mobs pile up against it. The player is NOT
    -- blocked (step through your own wall; the horde can't follow). Slabs also chill anything
    -- pressing the face. skillBubbles → more slabs → a WIDER wall.
    penguin = function(_plr, now, root, w, _state, mods, ax, az)
        local p = root.Position
        local slabs = 5 + (w.skillBubbles or 0)
        local slabR = 3 * mods.atkSize                  -- half-width of one ice column
        local px, pz = -az, ax                          -- perpendicular to aim = the wall line
        local cx, cz = p.X + ax * 12, p.Z + az * 12     -- wall centre, 12 studs ahead
        local half = slabs * slabR
        Obstacles.add(cx - px * half, cz - pz * half, cx + px * half, cz + pz * half, now + WALL_LIFE)
        for s = 1, slabs do
            local off = (s - (slabs + 1) / 2) * (slabR * 2)
            spawnHazard(HZ_WALL, cx + px * off, p.Y, cz + pz * off, slabR, 0, 0, 0, 0, 0.5, 0.4, WALL_LIFE)
        end
    end,
    -- Frog "Feeding Frenzy": rapid tongue lashes at the nearest mobs around you, at DOUBLE the eat
    -- odds (capped) — a heal burst when surrounded. skillBubbles → more lashes.
    frog = function(_plr, _now, root, w, state, mods)
        local p = root.Position
        local org = Pet.slotPos(p, state.main - 1, #state.weapons) -- lashes come from the frog's slot
        local lashes = 6 + (w.skillBubbles or 0)
        local cnt = hash:queryInto(p.X, p.Y, p.Z, queryOut)
        local cand: { number } = {}
        for j = 1, cnt do
            local ze = queryOut[j]
            if not dead[ze] and posCache[ze] then cand[#cand + 1] = ze end
        end
        table.sort(cand, function(a, b)
            local qa, qb = posCache[a], posCache[b]
            return (qa.X - p.X) ^ 2 + (qa.Z - p.Z) ^ 2 < (qb.X - p.X) ^ 2 + (qb.Z - p.Z) ^ 2
        end)
        local eatC = math.min(0.5, w.eatChance * 2)
        for i = 1, math.min(lashes, #cand) do
            local ze = cand[i]
            local q = posCache[ze]
            local dx, dz = q.X - org.X, q.Z - org.Z
            local m = math.sqrt(dx * dx + dz * dz)
            if m > 1e-3 then
                effectBatch[#effectBatch + 1] = { kind = FX_TONGUE, pos = Vector3.new(org.X, p.Y, org.Z), radius = m, dir = Vector3.new(dx / m, 0, dz / m), color = wcol(w) }
            end
            hurt(ze, rollDmg(w.dmg * 1.5 * mods.damage, mods.crit, mods.critDmg), 0, 0)
            if not dead[ze] and math.random() < eatC and not world:has(ze, Elite) and not world:has(ze, Boss) then
                dead[ze] = true -- GULP
                state.hp = math.min(state.maxHp, state.hp + w.eatHeal)
            end
        end
    end,
    -- Hedgehog "Bramble Ring": a circle of thorn hazards erupts AROUND you (self-centred denial —
    -- the inverse of Panda's forward lattice) + a thorn-skin surge (timed reflect buff).
    hedgehog = function(plr, now, root, w, _state, mods)
        local p = root.Position
        local thorns = 6 + (w.skillBubbles or 0)
        local r = (w.radius + 1) * mods.atkSize
        local RING_R = 9
        for s = 1, thorns do
            local a = (s / thorns) * (2 * math.pi)
            spawnHazard(2, p.X + math.cos(a) * RING_R, p.Y, p.Z + math.sin(a) * RING_R, r,
                w.dmg * 2 * mods.damage, (w.knock + 8) * mods.knock, mods.crit, mods.critDmg, 1, 0.4, 3)
        end
        PlayerBuffs.apply(plr, "reflect", 0.3, now + 4)
    end,
    -- Dragon "Inferno Breath": a sustained aim-tracked flame beam — pure damage (the inverse of
    -- Unicorn's slow beam; the BURN identity lives on the cone's dot/bleed instead).
    dragon = function(plr, _now, _root, w, _state, mods)
        local life = 2.5 + (w.skillBubbles or 0)
        local dps = (w.dmg * 2 + 14) * mods.damage
        startBeam(plr, life, dps, 1, 5, 70)
    end,
    -- Owl "Death Mark": mark the TOUGHEST living mobs (top HP — elites/bosses float up naturally)
    -- and snipe each with a guaranteed-crit bolt from the owl's slot. skillBubbles → +targets,
    -- skillRepeat → extra volley waves.
    owl = function(_plr, now, root, w, state, mods)
        local org = Pet.slotPos(root.Position, state.main - 1, #state.weapons)
        local targets = 3 + (w.skillBubbles or 0)
        local waves = 1 + (w.skillRepeat or 0)
        local cand: { { hp: number, p: Vector3 } } = {}
        for e, transform, h in zombies do
            if not dead[e] then cand[#cand + 1] = { hp = h.hp, p = transform.new.Position } end
        end
        table.sort(cand, function(a, b) return a.hp > b.hp end)
        for _ = 1, waves do
            for t = 1, math.min(targets, #cand) do
                local q = cand[t].p
                local dx, dz = q.X - org.X, q.Z - org.Z
                local m = math.sqrt(dx * dx + dz * dz)
                if m > 1e-3 then
                    spawnBubble(now, org, Vector3.new(dx / m, 0, dz / m), w, mods)
                    bubbles[#bubbles].critChance = 1 -- marked → the bolt ALWAYS crits
                end
            end
        end
    end,
    -- Crab "Riptide": staged EXPANDING knockback rings (you can watch the wave travel out) + a brief
    -- shell-up. Implemented as an invisible stationary summon whose fire ticks ring k at growing radius.
    crab = function(plr, now, root, w, _state, mods)
        local p = root.Position
        local rings = 3 + (w.skillBubbles or 0)
        PlayerBuffs.apply(plr, "armor", 0.2, now + 3)
        local ring = 0
        spawnSummon(plr.UserId, 3, p.X, p.Y, p.Z, 0, 0, 0.22, rings * 0.22 + 0.05, function(self, _snow)
            ring += 1
            local r = (10 + ring * 7) * mods.atkSize
            aoeDamage(self.x, self.y, self.z, r * r, w.dmg * 2.5 * mods.damage, mods.crit, mods.critDmg, (w.knock + 18) * mods.knock)
            effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = Vector3.new(self.x, self.y, self.z), radius = r, dir = ZERO, color = wcol(w) }
        end)
    end,
    -- Cow "Stampede": a spectral herd CHARGES along your aim — a moving trample wave (invisible
    -- moving summon; the traveling aura pulses are the herd). Replaces the old Quake alias.
    cow = function(plr, _now, root, w, _state, mods, ax, az)
        local p = root.Position
        local life = 1.1 + (w.skillBubbles or 0) * 0.4
        local SPEED = 30
        spawnSummon(plr.UserId, 3, p.X + ax * 4, p.Y, p.Z + az * 4, ax * SPEED, az * SPEED, 0.16, life, function(self, _snow)
            local r = (w.radius * 0.9 + 4) * mods.atkSize
            aoeDamage(self.x, self.y, self.z, r * r, w.dmg * 2 * mods.damage, mods.crit, mods.critDmg, (w.knock + 14) * mods.knock)
            effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = Vector3.new(self.x, self.y, self.z), radius = r, dir = ZERO, color = wcol(w) }
        end)
    end,
    -- Elephant "Earthshaker": one MASSIVE stomp at your feet — concentric quake rings + a stagger
    -- slow on everything nearby. Replaces the old Avalanche alias. skillBubbles → +rings.
    elephant = function(_plr, now, root, w, _state, mods)
        local p = root.Position
        local rings = 1 + (w.skillBubbles or 0)
        for k = 0, rings - 1 do
            local r = (16 + k * 8) * mods.atkSize
            aoeDamage(p.X, p.Y, p.Z, r * r, w.dmg * 2 * mods.damage, mods.crit, mods.critDmg, (w.knock + 16) * mods.knock)
        end
        applySlow(p.X, p.Y, p.Z, (24 * mods.atkSize) ^ 2, 0.5, 2.5, now) -- staggered: half speed
        effectBatch[#effectBatch + 1] = { kind = FX_EXPLODE, pos = p, radius = 16 * mods.atkSize, dir = ZERO, color = wcol(w) }
    end,
    -- Phoenix "Rebirth" (active): erupt in flame — big radial burst + heal + brief invuln. The
    -- once-per-run CHEAT DEATH is the weapon's `revives` field read by reviveCap — no code here.
    -- skillBubbles → bigger burst; skillRepeat → longer invuln.
    phoenix = function(plr, now, root, w, state, mods)
        local p = root.Position
        local r = (14 + (w.skillBubbles or 0) * 4) * mods.atkSize
        aoeDamage(p.X, p.Y, p.Z, r * r, w.dmg * 4 * mods.damage, mods.crit, mods.critDmg, (w.knock + 24) * mods.knock)
        state.hp = math.min(state.maxHp, state.hp + state.maxHp * 0.35) -- heal 35% (hp resource on state)
        PlayerBuffs.apply(plr, "invuln", 0, now + 2 + (w.skillRepeat or 0) * 0.75)
        effectBatch[#effectBatch + 1] = { kind = FX_EXPLODE, pos = p, radius = r, dir = ZERO, color = wcol(w) } -- a fiery ERUPTION, not a green pulse
    end,
    -- Wolf "Pack Howl": rally the whole pack (every living fighter gets damage+speed) AND send spirit
    -- wolves dashing through the crowd — MOVING summons whose fire pattern is a bleeding cone sweep
    -- along their dash heading (rendered via the existing melee FX; no body model needed).
    wolf = function(plr, now, root, w, _state, mods, ax, az)
        local untilT = now + HOWL_DUR
        for _, p2 in Players:GetPlayers() do
            if PlayerState.get(p2).playing then
                PlayerBuffs.apply(p2, "damage", 1.2, untilT)
                PlayerBuffs.apply(p2, "speed", 1.15, untilT)
            end
        end
        local wolves = 2 + (w.skillRepeat or 0)
        local p = root.Position
        local DASH_SPEED = 26
        for t = 1, wolves do
            -- fan the pack ±25° around aim so they carve parallel lanes through the horde
            local ang = (if wolves > 1 then ((t - 1) / (wolves - 1)) - 0.5 else 0) * math.rad(50)
            local d = rotateY(Vector3.new(ax, 0, az), ang)
            spawnSummon(plr.UserId, 2, p.X + d.X * 4, p.Y, p.Z + d.Z * 4, d.X * DASH_SPEED, d.Z * DASH_SPEED,
                0.3, 2.5, function(self, _snow) -- kind 2 = spirit wolf
                local r = (w.radius + 2) * mods.atkSize
                coneDamage(self.x, self.y, self.z, d.X, d.Z, r * r, math.cos(math.rad(120) * 0.5),
                    w.dmg * 1.5 * mods.damage, mods.crit, mods.critDmg, w.knock * mods.knock, w.dot * mods.damage)
                effectBatch[#effectBatch + 1] = { kind = FX_MELEE, pos = Vector3.new(self.x, self.y, self.z), radius = r, dir = Vector3.new(d.X, 0, d.Z), arc = math.rad(120), color = wcol(w) }
            end)
        end
    end,
}

-- (cow/elephant now have their own ults — Stampede / Earthshaker — defined in the table above)

-- slot = equipped weapon index (1/2/3). Runs that pet's skill on its registry cooldown.
blink.UseSkill.On(function(plr, slot)
    local state = PlayerState.get(plr)
    if not state.playing then return end
    if slot ~= state.main then return end -- only the player's MAIN weapon has a usable skill
    local w = state.weapons[slot]
    if not w then return end
    local fn = SKILLS[w.id]
    if not fn then return end
    local mods = world:get(ref(plr.UserId), PlayerMods)
    if not mods then return end -- resolver hasn't written this player yet (first frame of play)
    local petDef = Registry.pets[w.id]
    local cd = ((petDef and petDef.skill and petDef.skill.cooldown) or 8) * mods.skillCd -- Soda slows skills
    local now = workspace:GetServerTimeNow()
    local slots = skillCd[plr]
    if not slots then slots = {}; skillCd[plr] = slots end
    if now < (slots[slot] or 0) then return end
    local root = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
    if not root then return end
    slots[slot] = now + cd

    -- aim XZ (cursor aim if streamed, else facing)
    local ax, az = 0, 1
    local dir = aim[plr]
    if dir then
        local m = math.sqrt(dir.X * dir.X + dir.Z * dir.Z)
        if m > 1e-3 then ax, az = dir.X / m, dir.Z / m end
    else
        local lv = (root :: BasePart).CFrame.LookVector
        local m = math.sqrt(lv.X * lv.X + lv.Z * lv.Z)
        if m > 1e-3 then ax, az = lv.X / m, lv.Z / m end
    end

    fn(plr, now, root :: BasePart, w, state, mods, ax, az)
    flush(blink.FireBubble, fireBatch)
    flush(blink.Effect, effectBatch)
    flush(blink.SummonSpawn, summonSpawnBatch) -- bee/wolf ults spawn summons outside the combat tick
    flush(blink.HazardSpawn, hazardSpawnBatch) -- ...and penguin's Glacier Wall spawns hazards
end)

-- ── Steps ──────────────────────────────────────────────────────────────────────
local function rebuildHash()
    hash:beginFrame()
    table.clear(posCache)
    table.clear(mobR)
    table.clear(mobYt)
    table.clear(mobSample)
    local n = 0
    for e, transform, _health, size in zombies do
        local p = transform.new.Position
        posCache[e] = p
        mobR[e] = (size - 1) * R_PER_SIZE -- 0 for normals → unchanged feel; big for elites/bosses
        -- vertical reach: grows with size (tall boss column) AND covers hover height (flyers at p.Y
        -- so a ground-level shot still connects). Ground mobs sit near p.Y≈0 so this stays ~6.
        mobYt[e] = math.max(6 + (size - 1) * 3, p.Y + 6)
        hash:insert(e, p.X, p.Y, p.Z)
        n += 1
        if #mobSample < SAMPLE then
            mobSample[#mobSample + 1] = p
        else
            local r = math.random(1, n)
            if r <= SAMPLE then mobSample[r] = p end
        end
    end
end

-- Weapon-kind firing — TABLE-DRIVEN dispatch (mirrors SKILLS), keyed by w.kind. Each handler:
--   (now, pos, d, w, mods, i, n) — pos = player root, d = aim unit dir, i/n = weapon slot index / count.
-- Offensive stats come straight off `mods` (resolved PlayerMods). Add a weapon kind = add ONE row; an
-- unknown/legacy kind falls back to `projectile` below — never a silent no-op (CLAUDE.md allowlist gotcha).
local KIND_FIRE: { [string]: (number, Vector3, Vector3, any, any, number, number, any?) -> () } = {
    aura = function(now, pos, _d, w, mods)
        local r = w.radius * mods.atkSize
        aoeDamage(pos.X, pos.Y, pos.Z, r * r, w.dmg * mods.damage, mods.crit, mods.critDmg, w.knock * mods.knock)
        -- on-hit slow (BUL-47): an aura pulse chills everything it damages (weapon × item factor)
        local sl = (w.slowFactor or 1) * (mods.onHitSlow or 1)
        if sl < 1 then applySlow(pos.X, pos.Y, pos.Z, r * r, sl, ONHIT_SLOW_DUR, now) end
        effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = pos, radius = r, dir = ZERO, color = wcol(w) }
    end,
    melee = function(_now, pos, d, w, mods, i, n)
        local axz = math.sqrt(d.X * d.X + d.Z * d.Z)
        local ax, az = if axz > 1e-3 then d.X / axz else 0, if axz > 1e-3 then d.Z / axz else 1
        local r = w.radius * mods.atkSize
        -- the swing comes FROM the pet's ring slot (same Pet.slotPos the client renders the pet at),
        -- so the bear/wolf visibly attacks — hitbox apex moves WITH the visual, staying matched
        local apex = Pet.slotPos(pos, i - 1, n)
        -- w.dot > 0 (wolf) → every bitten mob bleeds; 0 (bear) → plain cone, unchanged
        coneDamage(apex.X, pos.Y, apex.Z, ax, az, r * r, math.cos(w.spread * 0.5), w.dmg * mods.damage, mods.crit, mods.critDmg, w.knock * mods.knock, w.dot * mods.damage)
        effectBatch[#effectBatch + 1] = { kind = FX_MELEE, pos = Vector3.new(apex.X, pos.Y, apex.Z), radius = r, dir = Vector3.new(ax, 0, az), arc = w.spread, color = wcol(w) }
    end,
    drop = function(now, pos, _d, w, mods)
        for s = 1, w.shots do -- weapon level → multiple stones (jittered around dense spots)
            local tp = densestPoint()
            if tp then
                local jx, jz = 0, 0
                if s > 1 then jx, jz = math.random() * 16 - 8, math.random() * 16 - 8 end
                local dx, dz = tp.X + jx, tp.Z + jz
                local r = w.radius * mods.atkSize
                pendingDrops[#pendingDrops + 1] = {
                    x = dx, y = tp.Y, z = dz, t = now + DROP_DELAY + (s - 1) * 0.1,
                    r2 = r * r, dmg = w.dmg * mods.damage, cc = mods.crit, cd = mods.critDmg, knock = w.knock * mods.knock,
                }
                effectBatch[#effectBatch + 1] = { kind = FX_DROP, pos = Vector3.new(dx, tp.Y, dz), radius = r, dir = ZERO }
            end
        end
    end,
    -- panda: summon `shots` bamboo from the ground in an interference (zig-zag lattice) ahead of aim;
    -- each is a thin, knockback hazard that lingers w.life (zone-control), ticking knock+damage every 0.4s
    bamboo = function(_now, pos, d, w, mods)
        local axz = math.sqrt(d.X * d.X + d.Z * d.Z)
        local ax, az = if axz > 1e-3 then d.X / axz else 0, if axz > 1e-3 then d.Z / axz else 1
        local px, pz = -az, ax -- perpendicular
        for s = 0, w.shots - 1 do
            local along = 10 + s * 5
            local side = (if s % 2 == 0 then 1 else -1) * (3 + (s // 2) * 4)
            local bx = pos.X + ax * along + px * side
            local bz = pos.Z + az * along + pz * side
            spawnHazard(2, bx, pos.Y, bz, w.radius * mods.atkSize, w.dmg * mods.damage, w.knock * mods.knock, mods.crit, mods.critDmg, 1, 0.4, w.life)
        end
    end,
    -- unicorn: lob a rainbow puddle out along aim — a DoT + slow zone for `life`s
    puddle = function(_now, pos, d, w, mods)
        local axz = math.sqrt(d.X * d.X + d.Z * d.Z)
        local ax, az = if axz > 1e-3 then d.X / axz else 0, if axz > 1e-3 then d.Z / axz else 1
        local bx, bz = pos.X + ax * 22, pos.Z + az * 22
        spawnHazard(1, bx, pos.Y, bz, w.radius * mods.atkSize, w.dot * mods.damage, 0, mods.crit, mods.critDmg, w.slowFactor, 0.4, w.life)
    end,
    -- turtle: shells circle the player (synced clock so the client visual aligns), hit + knock
    orbit = function(now, pos, _d, w, mods)
        local count = math.max(1, w.shots)
        local baseA = now * 2.2
        local orbitR = 7 + w.radius
        local r = w.radius * mods.atkSize
        for s = 0, count - 1 do
            local a = baseA + (s / count) * (2 * math.pi)
            local sx, sz = pos.X + math.cos(a) * orbitR, pos.Z + math.sin(a) * orbitR
            aoeDamage(sx, pos.Y, sz, r * r, w.dmg * mods.damage, mods.crit, mods.critDmg, w.knock * mods.knock)
        end
    end,
    projectile = function(now, pos, d, w, mods, i, n)
        local origin = Pet.slotPos(pos, i - 1, n)
        local shots = w.shots
        if shots <= 1 then
            spawnBubble(now, origin, d, w, mods)
        else
            for s = 0, shots - 1 do
                spawnBubble(now, origin, rotateY(d, ((s / (shots - 1)) - 0.5) * w.spread), w, mods)
            end
        end
    end,
    -- frog: a long TONGUE lash along aim (w.radius = reach). The first mob on the line gets bitten,
    -- PULLED toward the player (knock points inward — a yank, not a shove), and small mobs are
    -- sometimes EATEN whole: marked dead (the death pipeline still pays drops/EXP) + heal the player.
    -- `state` (8th arg) carries the hp resource for the heal; elites/bosses can never be swallowed.
    tongue = function(_now, pos, d, w, mods, i, n, state)
        local axz = math.sqrt(d.X * d.X + d.Z * d.Z)
        local ax, az = if axz > 1e-3 then d.X / axz else 0, if axz > 1e-3 then d.Z / axz else 1
        local reach = w.radius * mods.atkSize
        -- the tongue lashes FROM the frog's ring slot (where the client renders the frog),
        -- so the lash visibly comes out of the pet's mouth — sim and visual share the origin
        local org = Pet.slotPos(pos, i - 1, n)
        local STEP = 5
        local target: number?, tx, tz = nil, 0, 0
        local td2 = math.huge
        for s = 1, math.ceil(reach / STEP) do
            local sx, sz = org.X + ax * s * STEP, org.Z + az * s * STEP
            local cnt = hash:queryInto(sx, pos.Y, sz, queryOut)
            for j = 1, cnt do
                local ze = queryOut[j]
                if not dead[ze] then
                    local p = posCache[ze]
                    if p then
                        local dx, dz = p.X - sx, p.Z - sz
                        local d2 = dx * dx + dz * dz
                        local lw = 4 + (mobR[ze] or 0) -- line half-width + mob body radius
                        if d2 <= lw * lw and (p.Y - pos.Y) ^ 2 <= (mobYt[ze] or 6) ^ 2 and d2 < td2 then
                            target, td2, tx, tz = ze, d2, p.X, p.Z
                        end
                    end
                end
            end
            if target then break end -- first sample with a hit = nearest mob along the tongue
        end
        -- narrow tongue line (NOT an AoE disc) — length = distance to the bite, or full reach on a whiff
        local tlen = reach
        if target then tlen = math.sqrt((tx - org.X) ^ 2 + (tz - org.Z) ^ 2) end
        effectBatch[#effectBatch + 1] = { kind = FX_TONGUE, pos = Vector3.new(org.X, pos.Y, org.Z), radius = tlen, dir = Vector3.new(ax, 0, az), color = wcol(w) }
        if not target then return end
        local pdx, pdz = org.X - tx, org.Z - tz -- yank: knock impulse points back AT the frog
        local pm = math.sqrt(pdx * pdx + pdz * pdz)
        local kx, kz = 0, 0
        if pm > 1e-3 then kx, kz = pdx / pm * w.knock * mods.knock, pdz / pm * w.knock * mods.knock end
        hurt(target, rollDmg(w.dmg * mods.damage, mods.crit, mods.critDmg), kx, kz)
        if not dead[target] and w.eatChance > 0 and math.random() < w.eatChance
            and not world:has(target, Elite) and not world:has(target, Boss) then
            dead[target] = true -- GULP — swallowed whole (drops/EXP still pay out via processDeaths)
            if state then state.hp = math.min(state.maxHp, state.hp + w.eatHeal) end
        end
    end,
}

local function fireStep(now: number)
    for e, char, plr in characters do
        local root = (char :: Model).PrimaryPart
        if not root then continue end
        local state = PlayerState.get(plr)
        if not state.playing then continue end
        -- offensive modifiers (card stats × item buffs × any timed offense buff) are resolved into
        -- PlayerMods by the playerBuffs system — read them, never re-derive inline. `state` still owns
        -- the run loadout (weapons) + hp/playing, which aren't modifiers.
        local mods = world:get(e, PlayerMods)
        if not mods then continue end

        local dir = aim[plr]
        if not dir then
            local lv = root.CFrame.LookVector
            dir = Vector3.new(lv.X, 0, lv.Z)
        end
        local mag = dir.Magnitude
        if mag < 1e-3 then continue end
        local d = dir / mag
        local pos = root.Position
        local haste = mods.haste -- fire-rate gate (w.fireCd / haste)
        local n = #state.weapons

        for i = 1, n do
            local w = state.weapons[i]
            if now < w.cd then continue end
            w.cd = now + w.fireCd / haste
            local fire = KIND_FIRE[w.kind] or KIND_FIRE.projectile -- unknown/legacy kind → projectile
            fire(now, pos, d, w, mods, i, n, state) -- state = hp RESOURCE only (frog eat-heal); stats stay on mods
        end
    end
end

-- ── On-hit behaviors (each a self-contained weapon-level effect; called from bubbleStep on a hit) ──
-- All AoE scans below use aoeOut, NOT queryOut, so they can't corrupt the caller's in-progress neighbour
-- loop. (cx,cy,cz) is the impact centre (mob XZ at the bubble's height). `ze` is the mob just struck.

-- boomerang (cat): at half-life, launch a return bolt back toward the throw origin (the second pass).
local function bubbleReturn(b: Bubble, now: number, bx: number, by: number, bz: number)
    b.returned = true
    local rdx, rdz = b.ox - bx, b.oz - bz
    local rm = math.sqrt(rdx * rdx + rdz * rdz)
    if rm <= 1e-3 then return end
    local sp = math.sqrt(b.vx * b.vx + b.vz * b.vz)
    if sp < 1e-3 then sp = 60 end
    pushBubble(now, bx, by, bz, rdx / rm * sp, 0, rdz / rm * sp, b.baseDmg, b.pierce, b.r2,
        b.life * 0.5, b.color, 0, b.knock, b.critChance, b.critDamage, b.aoe, b.splitPierce)
    bubbles[#bubbles].slow = b.slow -- the return pass chills too
end

-- weapon-level "burst on hit": a small AoE (half damage) around the impact — WITH a visible
-- explosion (bee bombers were doing this invisibly; now every burst flashes in the weapon color).
local function bubbleBurst(b: Bubble, ze: number, cx: number, cy: number, cz: number)
    local ar2 = b.aoe * b.aoe
    local admg = b.baseDmg * 0.5
    effectBatch[#effectBatch + 1] = { kind = FX_EXPLODE, pos = Vector3.new(cx, cy, cz), radius = b.aoe, dir = ZERO, color = b.color }
    local ac = hash:queryInto(cx, cy, cz, aoeOut)
    for jj = 1, ac do
        local ze2 = aoeOut[jj]
        if ze2 ~= ze and not dead[ze2] then
            local q = posCache[ze2]
            if q then
                local ddx, ddz = q.X - cx, q.Z - cz
                if ddx * ddx + ddz * ddz <= ar2 and (q.Y - cy) ^ 2 <= Y_TOL2 then
                    hurt(ze2, rollDmg(admg, b.critChance, b.critDamage), 0, 0)
                end
            end
        end
    end
end

-- split: a fan of SPLIT_N short-lived bolts from the impact, along the bubble's heading (`sp` = its speed).
local function bubbleSplit(b: Bubble, now: number, cx: number, cy: number, cz: number, sp: number)
    local base = if sp > 1e-3 then Vector3.new(b.vx, 0, b.vz).Unit else Vector3.new(0, 0, -1)
    local splitPierce = if b.splitPierce then 2 else 1
    for s = 0, SPLIT_N - 1 do
        local cdir = rotateY(base, ((s / (SPLIT_N - 1)) - 0.5) * SPLIT_SPREAD)
        pushBubble(now, cx, cy, cz, cdir.X * SPLIT_SPEED, 0, cdir.Z * SPLIT_SPEED,
            b.baseDmg * SPLIT_FRAC, splitPierce, SPLIT_R2, SPLIT_LIFE, b.color, 0, b.knock * 0.5, b.critChance, b.critDamage, 0, false)
        bubbles[#bubbles].slow = b.slow -- splits inherit the chill
    end
end

-- chain (fox): ricochet a bolt to the nearest un-hit, living mob within CHAIN_R2 of the impact. The new
-- bolt inherits `b.hits` semantics via a fresh set but carries chain-1, so the ricochet count is bounded.
local function bubbleChain(b: Bubble, now: number, ze: number, cx: number, cy: number, cz: number, bchain: number)
    local best: Vector3?, bd2 = nil, CHAIN_R2
    local cnt = hash:queryInto(cx, cy, cz, aoeOut)
    for jj = 1, cnt do
        local ze2 = aoeOut[jj]
        if ze2 ~= ze and not dead[ze2] and not b.hits[ze2] then
            local q = posCache[ze2]
            if q then
                local ddx, ddz = q.X - cx, q.Z - cz
                local d2 = ddx * ddx + ddz * ddz
                if d2 < bd2 then bd2 = d2; best = q end
            end
        end
    end
    if not best then return end
    local dirx, dirz = best.X - cx, best.Z - cz
    local m = math.sqrt(dirx * dirx + dirz * dirz)
    if m <= 1e-3 then return end
    local sp = math.sqrt(b.vx * b.vx + b.vz * b.vz)
    if sp < 1e-3 then sp = 70 end
    pushBubble(now, cx, cy, cz, dirx / m * sp, 0, dirz / m * sp, b.baseDmg, 1,
        b.r2, b.life, b.color, 0, b.knock, b.critChance, b.critDamage, b.aoe, b.splitPierce)
    bubbles[#bubbles].chain = bchain - 1
    bubbles[#bubbles].slow = b.slow -- ricochets inherit the chill
end

-- retire splash (BUL-48): a landing weapon (frog) leaves a hazard wherever its bubble ends
local function bubbleLand(b: Bubble, x: number, y: number, z: number)
    local ld = b.land
    if not ld then return end
    spawnHazard(ld.kind, x, y, z, ld.r, ld.dmg, ld.knock, ld.cc, ld.cd, ld.slowFactor, ld.tickEvery, ld.life)
end

local function bubbleStep(now: number)
    local write = 1
    for i = 1, #bubbles do
        local b = bubbles[i]
        local age = now - b.t0
        if age > b.life then -- flew its full life → LANDS at the end-of-flight point
            bubbleLand(b, b.ox + b.vx * b.life, b.oy + b.vy * b.life, b.oz + b.vz * b.life)
            continue
        end
        local bx, by, bz = b.ox + b.vx * age, b.oy + b.vy * age, b.oz + b.vz * age

        if b.boomerang and not b.returned and age >= b.life * 0.5 then
            bubbleReturn(b, now, bx, by, bz)
        end

        local tr = b.trail -- ice trail: drop a freeze patch (pure control, 0 dmg) along the flight
        if tr and now >= (b.nextTrail or 0) then
            b.nextTrail = now + tr.every
            spawnHazard(HZ_ICE, bx, by, bz, tr.r, 0, 0, 0, 0, tr.slowFactor, 0.3, tr.life)
        end

        local cnt = hash:queryInto(bx, by, bz, queryOut)
        for j = 1, cnt do
            local ze = queryOut[j]
            if b.hits[ze] or dead[ze] then continue end
            local p = posCache[ze]
            if not p then continue end
            local dx, dz = p.X - bx, p.Z - bz
            local reach = b.br + (mobR[ze] or 0) -- + mob body radius so big bosses are hittable
            if dx * dx + dz * dz > reach * reach or (p.Y - by) ^ 2 > (mobYt[ze] or 6) ^ 2 then continue end

            -- HIT: damage + knockback, then any weapon-level on-hit effects (burst / split / chain).
            b.hits[ze] = true
            b.pierce -= 1
            local sp = math.sqrt(b.vx * b.vx + b.vz * b.vz)
            local kx, kz = 0, 0
            if b.knock > 0 and sp > 1e-3 then kx, kz = b.vx / sp * b.knock, b.vz / sp * b.knock end
            hurt(ze, rollDmg(b.baseDmg, b.critChance, b.critDamage), kx, kz)
            local sl = b.slow -- on-hit slow (BUL-47): chill the struck mob via the status resolver
            if sl and sl < 1 and not dead[ze] then Statuses.slow(ze, sl, now + ONHIT_SLOW_DUR) end

            if b.aoe > 0 then bubbleBurst(b, ze, p.X, by, p.Z) end
            if b.split > 0 then bubbleSplit(b, now, p.X, by, p.Z, sp); b.split = 0 end
            local bchain = b.chain or 0
            if bchain > 0 then b.chain = 0; bubbleChain(b, now, ze, p.X, by, p.Z, bchain) end

            if b.pierce <= 0 then break end
        end

        if b.pierce > 0 then
            bubbles[write] = b
            write += 1
        else
            spentBubbles[#spentBubbles + 1] = b.id -- pierce used up → client despawns it now
            bubbleLand(b, bx, by, bz) -- popped on its last pierce → splash at the impact (BUL-48)
        end
    end
    for i = #bubbles, write, -1 do bubbles[i] = nil end
end

local function dropStep(now: number)
    local write = 1
    for i = 1, #pendingDrops do
        local dp = pendingDrops[i]
        if now >= dp.t then
            aoeDamage(dp.x, dp.y, dp.z, dp.r2, dp.dmg, dp.cc, dp.cd, dp.knock)
        else
            pendingDrops[write] = dp
            write += 1
        end
    end
    for i = #pendingDrops, write, -1 do pendingDrops[i] = nil end
end

local function processDeaths()
    table.clear(deathIds)
    for ze in dead do
        local zt = world:get(ze, Transform)
        deathIds[#deathIds + 1] = ze
        -- Boss/Elite are value-less TAGS (world:add) → world:get returns nil even when present.
        -- MUST use world:has, or every boss/elite is misread as a normal mob (no card/big-EXP drop).
        local isBoss  = world:has(ze, Boss)
        local isElite = world:has(ze, Elite)
        if zt then
            local p = zt.new.Position
            local w = SpawnHost.currentWave()
            if isBoss then
                -- boss ALWAYS drops: a CARD PACK + a guaranteed-new PET + a big EXP orb + tix
                CardDrops.drop(p.X, p.Z)
                PetDrops.dropBoss(p.X, p.Z) -- guaranteed pet (prefers one you don't own)
                Exp.dropBig(p.X, p.Z, w * 5)
                TixDrops.drop(p.X, p.Z, 20 + w * 5) -- >20 → StackofTix
            elseif isElite then
                CardDrops.drop(p.X, p.Z)        -- elites also drop a card pack
                PetDrops.maybeDropElite(p.X, p.Z) -- ...and an uncommon pet
                Exp.drop(p.X, p.Z, w * (ELITE_EXP - 8))
                TixDrops.drop(p.X, p.Z, 4 + w * 2)  -- scales Tix→Pile→Stack with the wave
                HealthDrops.maybeDrop(p.X, p.Z)
            else
                Exp.drop(p.X, p.Z, EXP_PER_KILL)
                HealthDrops.maybeDrop(p.X, p.Z) -- small chance of a heart
                TixDrops.maybeDrop(p.X, p.Z)    -- small chance of a tix
            end
        end
        local slot = world:get(ze, Slot)
        if slot then SpawnHost.freeSlot(slot) end -- recycle the dense replication slot (zombies)
        bleeds[ze] = nil -- entity id recycles after delete — never leak a bleed onto its successor
        world:delete(ze)
    end
    if #deathIds > 0 then
        blink.Death.FireAll(deathIds)
        local kills = #deathIds
        for _, plr in Players:GetPlayers() do
            Profile.addKills(plr, kills) -- lifetime kills
            -- Leech (item): heal per kill. Single-player = exactly "lifesteal on your kills"; in co-op
            -- every fighter leeches off the shared horde (acceptable until co-op is load-tested).
            local s = PlayerState.get(plr)
            if s.playing and s.itemLifesteal > 0 and s.hp > 0 then
                s.hp = math.min(s.maxHp, s.hp + s.itemLifesteal * kills)
            end
        end
    end
    -- (elites/bosses no longer grant a free pick — they DROP a card pack you walk over; carddrops.luau)
end

-- ── Revive / cheat-death (BUL-46) ─────────────────────────────────────────────
-- Capacity is DERIVED, never stored: the Second Wind item's `itemRevives` (BUL-38) + any equipped
-- weapon's `revives` (Phoenix, BUL-65). Derived-cap vs a monotonic `revivesUsed` survives the item
-- recompute (which resets item* fields to identity) — a consumed charge can never come back mid-run,
-- and capacity gained mid-run works immediately. Grant a charge = add to either source.
local REVIVE_HP_FRAC = 0.5
local REVIVE_INVULN  = 1.5

local function reviveCap(state: any): number
    local cap = state.itemRevives or 0 -- itemRegistry field lands with BUL-38; absent → 0
    for _, w in state.weapons do cap += (w.revives or 0) end
    return cap
end

-- Lethal-damage interception, called at the SINGLE hp<=0 checkpoint (damagePlayers — UFO bolts/beam
-- only drain hp and floor at 0, so they funnel here too). Humanoid.Died (fall/void) bypasses by
-- design: that body is already gone, restoring hp can't resurrect it. True = the death was cheated.
local function tryRevive(plr: Player, state: any, pos: Vector3): boolean
    if (state.revivesUsed or 0) >= reviveCap(state) then return false end
    state.revivesUsed = (state.revivesUsed or 0) + 1
    state.hp = state.maxHp * REVIVE_HP_FRAC
    PlayerBuffs.apply(plr, "invuln", 0, workspace:GetServerTimeNow() + REVIVE_INVULN)
    -- golden "second wind" ERUPTION — unmissable feedback that a death was cheated
    effectBatch[#effectBatch + 1] = { kind = FX_EXPLODE, pos = pos, radius = 14, dir = ZERO, color = Vector3.new(1, 0.85, 0.35) }
    return true
end

-- End the run. Idempotent (the dead flag guards), so every death source funnels here:
-- contact damage, AND Humanoid.Died (fall / void / anything else).
local function killPlayer(plr: Player)
    local s = PlayerState.get(plr)
    if s.dead then return end
    s.dead = true
    s.playing = false -- out of the arena → no longer fired/targeted; the dead body just lies there
    s.hp = 0
    ghosts[plr] = true -- a ghost for the rest of this round — can't rejoin until it ends
    clearSummons(plr.UserId) -- their turrets/spirits die with them
    local time = workspace:GetServerTimeNow() - s.runStart
    blink.GameOver.Fire(plr, { time = time, level = s.level }) -- client → spectate mode
    Profile.recordRun(plr, SpawnHost.currentWave(), s.level, time) -- persist best stats + runs
end

-- Hook Humanoid.Died for a character so external deaths also end the run. CharacterAutoLoads is
-- off (players.luau) — the dead body stays put until Restart calls LoadCharacter, so a death
-- can't silently reset the character out from under the GameOver screen.
local function hookChar(plr: Player, char: Model)
    task.spawn(function()
        local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
        if hum then (hum :: Humanoid).Died:Connect(function() killPlayer(plr) end) end
    end)
end
local function watchPlayer(plr: Player)
    plr.CharacterAdded:Connect(function(c) hookChar(plr, c) end)
    if plr.Character then hookChar(plr, plr.Character) end
end
Players.PlayerAdded:Connect(watchPlayer)
for _, plr in Players:GetPlayers() do watchPlayer(plr) end

local function damagePlayers(dt: number)
    for e, char, plr in characters do
        local state = PlayerState.get(plr)
        if not state.playing then continue end
        -- ALL combat modifiers (passive gear defense + active timed buffs) are resolved by the
        -- playerBuffs system into PlayerMods — read them here, never re-derive inline. Fall back to a
        -- no-armor/no-invuln default if it's somehow unresolved, so a hiccup can never read as invincible.
        local mods = world:get(e, PlayerMods) or DEFAULT_MODS
        -- regen: Regeneration card + bear regenBonus + any timed regen buff (all folded into mods.regen)
        if mods.regen > 0 and state.hp < state.maxHp then
            state.hp = math.min(state.maxHp, state.hp + mods.regen * dt)
        end
        -- keep the live Humanoid's walk speed in sync (base stat × any active speed buff)
        local hum = (char :: Model):FindFirstChildOfClass("Humanoid")
        if hum and hum.WalkSpeed ~= mods.walkSpeed then hum.WalkSpeed = mods.walkSpeed end
        local root = (char :: Model).PrimaryPart
        if not root then continue end
        local pos = root.Position
        local cnt = hash:queryInto(pos.X, pos.Y, pos.Z, queryOut)
        local contacts = 0
        local reflectDmg = PER_MOB_DPS * mods.reflect * dt -- thorns: damage back per contacting mob
        for j = 1, cnt do
            local qe = queryOut[j]
            local p = posCache[qe]
            if p then
                local dx, dz = p.X - pos.X, p.Z - pos.Z
                local reach = CONTACT_BASE + (mobR[qe] or 0) -- big bosses touch you at their edge
                if dx * dx + dz * dz <= reach * reach and (p.Y - pos.Y) ^ 2 <= (mobYt[qe] or 6) ^ 2 then
                    contacts += 1
                    if reflectDmg > 0 then hurt(qe, reflectDmg, 0, 0) end -- turtle thorns
                end
            end
        end
        if contacts > 0 and not Config.Debug.INVINCIBLE and not mods.invuln then
            -- armor reduces incoming contact damage (turtle); Shell Nova grants brief invuln
            state.hp -= math.min(contacts, MAX_CONTACTS) * PER_MOB_DPS * dt * (1 - mods.armor)
        end
        -- death check covers EVERY damage source (contact + UFO bolts/beam drained hp elsewhere)
        if state.hp <= 0 then
            if tryRevive(plr, state, pos) then continue end -- cheat-death: back up with i-frames instead
            state.hp = 0
            local hum = (char :: Model):FindFirstChildOfClass("Humanoid")
            if hum then hum.Health = 0 end -- kill the body (also fires Humanoid.Died)
            killPlayer(plr)                -- immediate GameOver (Died is a no-op after this)
        end
    end
end

-- PLAY. Round-tracked (NOT a per-player horde reset):
--   • A ghost (died THIS round) is ignored — they stay spectating until the round ends.
--   • If a round is live, this player JOINS it as-is (e.g. straight into wave 50) — fresh
--     character + own progression, shared horde untouched. Covers new joiners AND reconnects.
--   • If no round is live, this Play STARTS one: wipe any leftovers + spawn wave 1.
blink.Restart.On(function(plr)
    if ghosts[plr] then return end -- dead this round → locked out until RoundOver frees you
    if not SpawnHost.isRunning() then
        SpawnHost.resetRun()   -- begin a fresh round (horde + wave 1)
        Exp.clearAll()         -- wipe any leftover orbs
        PetDrops.clearAll()    -- ... pet drops
        CardDrops.clearAll()   -- ... card packs
        HealthDrops.clearAll() -- ... hearts
        TixDrops.clearAll()    -- ... tix (banked balance is kept)
    end
    PlayerState.reset(plr)
    Progress.resetPlayer(plr)
    PlayerState.get(plr).playing = true -- BEFORE warpIn so the spawn handler won't re-park them
    Chars.warpIn(plr) -- warp the parked lobby body into the arena (no cold LoadCharacter hitch)
end)

-- Leaving cleans up per-player combat state (and frees the ghost slot for the leak's sake).
Players.PlayerRemoving:Connect(function(plr)
    ghosts[plr] = nil
    aim[plr] = nil
    skillCd[plr] = nil
    beams[plr] = nil
    clearSummons(plr.UserId)
end)

-- ── Round lifecycle ─────────────────────────────────────────────────────────────
-- A round lives only while at least one player is alive in the arena. The instant the last
-- one falls (death) OR disconnects, the round is OVER: wipe the horde + every ground drop and
-- stop spawning, so an empty/all-dead server doesn't grind on a ghost horde and the next Play
-- starts clean at wave 1. A player who joins/restarts while someone is still alive JOINS the
-- run in progress instead (handled in the Restart handler above). Polled from the combat tick
-- (outside every query) so the field-wipe never deletes mobs mid-iteration.
local function noOneFighting(): boolean
    for _, plr in Players:GetPlayers() do
        if PlayerState.get(plr).playing then return false end
    end
    return true
end

local function endRoundIfEmpty()
    if SpawnHost.isRunning() and noOneFighting() then
        SpawnHost.endRun()     -- wipe the horde + stop waves (running → false)
        Exp.clearAll()         -- and every leftover ground drop (banked Tix is kept)
        PetDrops.clearAll()
        CardDrops.clearAll()
        HealthDrops.clearAll()
        TixDrops.clearAll()
        -- wipe live hazards + beams + summons so the next round starts clean
        local hids = {}
        for _, hz in hazards do hids[#hids + 1] = hz.id end
        local sids = {}
        for _, s in summons do sids[#sids + 1] = s.id end
        table.clear(hazards); table.clear(beams); table.clear(summons); table.clear(bleeds)
        Obstacles.clear() -- ice walls down with the round
        if #hids > 0 then blink.HazardRemove.FireAll(hids) end
        if #sids > 0 then blink.SummonRemove.FireAll(sids) end
        table.clear(ghosts)        -- everyone is freed → eligible to Play the next round
        blink.RoundOver.FireAll(1) -- clients: exit spectate, back to the menu/Play
        -- re-park a fresh lobby body for anyone whose body died this round → next Play warps in
        -- cleanly (and the dead bodies are cleared off the field). Invisible: camera is the menu.
        for _, plr in Players:GetPlayers() do
            PlayerState.get(plr).playing = false
            Chars.refreshLobby(plr)
        end
    end
end

-- ── Tick ──────────────────────────────────────────────────────────────────────
local acc, hpAcc = 0, 0
local function combatWrapper(dt: number)
    acc += dt
    if acc < COMBAT_TICK then return end
    local step = acc
    acc = 0
    endRoundIfEmpty() -- before any query: tear down a finished round (all players dead/gone)
    local now = workspace:GetServerTimeNow()

    rebuildHash()
    table.clear(dead)
    table.clear(hitSet)
    fireStep(now)
    summonStep(now, step) -- temporary auto-firing entities (Bee/Wolf summons); before bubbleStep so summon shots step this tick
    bubbleStep(now)
    dropStep(now)
    hazardStep(now)      -- puddles + bamboo tick damage/slow
    bleedStep(now, step) -- wolf-bite bleeds tick on the bitten mobs
    beamStep(now, step)  -- unicorn ult sweeping beam
    processDeaths()
    damagePlayers(step)

    flush(blink.FireBubble, fireBatch)
    flush(blink.Effect, effectBatch)
    flush(blink.HazardSpawn, hazardSpawnBatch)
    flush(blink.HazardRemove, hazardRemoveBatch)
    flush(blink.SummonSpawn, summonSpawnBatch)
    flush(blink.SummonRemove, summonRemoveBatch)

    -- bubbles that used up their pierce this tick → client despawns them (pierce reads finite)
    if #spentBubbles > 0 then
        for i = 1, #spentBubbles, HIT_CHUNK do
            local chunk = table.move(spentBubbles, i, math.min(i + HIT_CHUNK - 1, #spentBubbles), 1, {})
            blink.RemoveBubble.FireAll(chunk)
        end
        table.clear(spentBubbles)
    end

    -- hit-flash: mobs that took damage but survived (deaths already go via Death)
    table.clear(hitIds)
    for ze in hitSet do
        if not dead[ze] then
            hitIds[#hitIds + 1] = ze
            if #hitIds >= HIT_CHUNK then blink.Hit.FireAll(hitIds); table.clear(hitIds) end
        end
    end
    if #hitIds > 0 then blink.Hit.FireAll(hitIds) end

    -- elite/boss HP → client health bars (the set is tiny; dead ones are already deleted above)
    table.clear(healthBatch)
    for e, h in bossMobs do
        healthBatch[#healthBatch + 1] = { id = e, hp = math.max(0, math.floor(h.hp)), max = math.max(1, math.floor(h.max)) }
    end
    for e, h in eliteMobs do
        healthBatch[#healthBatch + 1] = { id = e, hp = math.max(0, math.floor(h.hp)), max = math.max(1, math.floor(h.max)) }
    end
    if #healthBatch > 0 then blink.MobHealth.FireAll(healthBatch) end

    hpAcc += step
    if hpAcc >= HP_SEND then
        hpAcc = 0
        for _, plr in Players:GetPlayers() do blink.Stats.Fire(plr, PlayerState.statsMsg(plr)) end
    end
end

scheduler.SYSTEM(combatWrapper, phases.Combat)
return 0
