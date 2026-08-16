-- ServerScriptService/systems/ufo.luau
-- UFO flying enemies — server-authoritative, NO pathfinding (they have no PathNode, so horde.luau
-- skips them). Each UFO hovers above the nearest player's ground level and keeps a STANDOFF range
-- (long-range attacker). Not agile (capped speed). Attacks:
--   • normal      → laser BOLTS (formula projectiles) fired at the player on a cooldown
--   • elite/boss  → a continuous BEAM whose endpoint slowly follows the player (dodgeable)
-- UFOs are normal mobs otherwise (Transform+Health+Mob), so player weapons hit them and combat's
-- processDeaths handles their death/rewards. Player damage drops PlayerState.hp; combat kills at 0.
--!optimize 2
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local blink = require(ServerScriptService.ServerNet)
local std   = ReplicatedStorage.std

local world       = require(std.world)
local cts         = require(std.components)
local scheduler   = require(std.scheduler)
local phases      = require(std.phases)
local PlayerState = require(std.playerState)
local Config      = require(std.config)

local Transform = cts.Transform
local Health    = cts.Health
local Speed     = cts.Speed
local Mob       = cts.Mob
local Flying    = cts.Flying
local Elite     = cts.Elite
local Boss      = cts.Boss
local Character  = cts.Character
local Player     = cts.Player
local PlayerMods = cts.PlayerMods

-- ── Tunables ──────────────────────────────────────────────────────────────────
local TICK        = 1 / 20
local HOVER       = 14      -- height above the player's ground level
local STANDOFF    = 34      -- preferred hover distance (XZ)
local NEAR_FRAC   = 0.75    -- back off if closer than STANDOFF*this
local Y_LERP      = 3
local CHUNK       = 50      -- entries per unreliable packet (UfoPos/UfoBeam)
-- normal laser bolt
local FIRE_CD     = 1.8
local BOLT_SPEED  = 35      -- normal UFO laser bolt speed (halved — was 70; slower = dodgeable)
local BOLT_LIFE   = 2.5
local BOLT_DMG    = 7
local BOLT_HIT_R2 = 4 * 4
-- elite/boss beam — fires in BURSTS (ON for BEAM_ON, then a COOLDOWN of BEAM_OFF, repeating) so it
-- isn't a constant death ray. Each UFO is phase-staggered by id so they don't all fire in sync.
local BEAM_FOLLOW = 1.25     -- elite/boss beam tracking speed (halved — was 2.5; slower = dodgeable)
local BEAM_HIT_R2 = 3 * 3    -- beam hit radius halved (was 6 → 3) — it was OP
local BEAM_DPS    = 10
local BOSS_BEAM_MUL = 1.8
local BEAM_TELEGRAPH = 1.1      -- WARNING window before damage: a faint line tracks you so you can dodge
local BEAM_ON        = 2.5      -- seconds the beam actually fires (deals damage)
local BEAM_OFF       = 5.0      -- cooldown (off) between bursts — BIGGER = more downtime
local BEAM_CYCLE     = BEAM_TELEGRAPH + BEAM_ON + BEAM_OFF
-- "telegraph" (charging, NO damage), "fire" (damaging), or "off". e%CYCLE staggers the UFOs apart.
local function beamPhase(e: number, now: number): string
    local t = (now + (e % BEAM_CYCLE)) % BEAM_CYCLE
    if t < BEAM_TELEGRAPH then return "telegraph"
    elseif t < BEAM_TELEGRAPH + BEAM_ON then return "fire"
    else return "off" end
end

-- Split the UFOs by TIER into their own cached queries. The archetype IS the tier, so we
-- never `world:get(e, Elite/Boss)` per-mob each tick — normals fire bolts, elites/bosses
-- run the beam (boss beam is stronger). (Tiers are fixed at spawn, so the sets are disjoint.)
local ufosNormal = world:query(Transform, Speed, Health):with(Mob, Flying):without(Elite, Boss):cached()
local ufosElite  = world:query(Transform, Speed, Health):with(Mob, Flying, Elite):cached()
local ufosBoss   = world:query(Transform, Speed, Health):with(Mob, Flying, Boss):cached()
local characters = world:query(Character, Player):cached()

-- ── State ─────────────────────────────────────────────────────────────────────
local fireCdAt:  { [number]: number } = {}
local beamTarget: { [number]: Vector3 } = {}

type Bolt = { ox: number, oy: number, oz: number, vx: number, vy: number, vz: number, t0: number, dmg: number }
local bolts: { Bolt } = {}

-- Per-tick TARGET CACHE: each live player's root position + state, resolved ONCE per tick.
-- nearestTarget/damageAt then scan this tiny array instead of doing GetPlayers() +
-- FindFirstChild + PlayerState.get on every bolt and every beam.
-- invuln/armor are RESOLVED from the player's PlayerMods once per tick (the playerBuffs system owns
-- them) so the per-bolt/beam damageAt never re-reads PlayerState modifiers.
type Target = { pos: Vector3, state: any, invuln: boolean, armor: number }
local targets: { Target } = {}
local moveBatch: { blink.UfoPos } = {}
local beamBatch: { blink.UfoBeamMsg } = {}
local boltBatch: { blink.UfoBolt } = {}
local seen: { [number]: boolean } = {}

local function gatherTargets()
    table.clear(targets)
    for e, char, plr in characters do
        local s = PlayerState.get(plr)
        if not s.playing then continue end -- only target players actually in the arena
        local root = (char :: Model).PrimaryPart
        if root then
            local mods = world:get(e, PlayerMods)
            targets[#targets + 1] = {
                pos = root.Position, state = s,
                invuln = (mods ~= nil and mods.invuln) or false,
                armor = if mods then mods.armor else 0,
            }
        end
    end
end

local function nearestTarget(x: number, z: number): Vector3?
    local best: Vector3? = nil
    local bd2 = math.huge
    for _, t in targets do
        local dx, dz = t.pos.X - x, t.pos.Z - z
        local d2 = dx * dx + dz * dz
        if d2 < bd2 then bd2 = d2; best = t.pos end
    end
    return best
end

-- damage the first cached (live) player within r2 (3D) of `pt`; returns true if one was hit
local function damageAt(pt: Vector3, r2: number, dmg: number): boolean
    for _, t in targets do
        local p = t.pos
        local dx, dy, dz = p.X - pt.X, p.Y - pt.Y, p.Z - pt.Z
        if dx * dx + dy * dy + dz * dz <= r2 then
            -- still "hit" (bolt is consumed) but skip the drain in debug invincible / Shell Nova invuln
            if not Config.Debug.INVINCIBLE and not t.invuln then
                t.state.hp = math.max(0, t.state.hp - dmg * (1 - t.armor)) -- turtle armor; combat kills at 0
            end
            return true
        end
    end
    return false
end

local function boltStep(now: number)
    local write = 1
    for i = 1, #bolts do
        local b = bolts[i]
        local age = now - b.t0
        if age > BOLT_LIFE then continue end
        local pt = Vector3.new(b.ox + b.vx * age, b.oy + b.vy * age, b.oz + b.vz * age)
        if not damageAt(pt, BOLT_HIT_R2, b.dmg) then
            bolts[write] = b
            write += 1
        end
    end
    for i = #bolts, write, -1 do bolts[i] = nil end
end

local function fireChunked(ev: any, arr: { any })
    for i = 1, #arr, CHUNK do
        ev.FireAll(table.move(arr, i, math.min(i + CHUNK - 1, #arr), 1, {}))
    end
end

-- per-UFO standoff so the flock forms a loose CLOUD at varied distances instead of one tight ring
-- all at the same radius (which read as a spinning wall). ~0.65..1.35 × STANDOFF.
local function standoffFor(e: number): number
    return STANDOFF * (0.65 + (e % 17) / 17 * 0.7)
end

-- shared: ease toward the STANDOFF ring + hover, stream the new pos. Returns (npos, targetPos).
local function moveUfo(e: number, transform: any, speed: number, dt: number): (Vector3?, Vector3?)
    seen[e] = true
    local pos = transform.new.Position
    local target = nearestTarget(pos.X, pos.Z)
    if not target then return nil, nil end

    -- XZ: hold the (per-UFO) standoff distance (approach if far, back off if too close)
    local so = standoffFor(e)
    local dx, dz = target.X - pos.X, target.Z - pos.Z
    local dist = math.sqrt(dx * dx + dz * dz)
    local move = if dist > so then 1 elseif dist < so * NEAR_FRAC then -1 else 0
    local nx, nz = pos.X, pos.Z
    if move ~= 0 and dist > 1e-3 then
        nx = pos.X + (dx / dist) * move * speed * dt
        nz = pos.Z + (dz / dist) * move * speed * dt
    end
    -- Y: ease toward the player's level + hover
    local ny = pos.Y + ((target.Y + HOVER) - pos.Y) * math.min(1, Y_LERP * dt)
    local npos = Vector3.new(nx, ny, nz)
    transform.new = CFrame.new(nx, ny, nz) -- combat hash + this stream read it
    moveBatch[#moveBatch + 1] = { id = e, pos = npos }
    return npos, target
end

-- BOLT: fire at the player's torso on a cooldown (normal UFOs)
local function doBolt(e: number, now: number, npos: Vector3, target: Vector3)
    if now < (fireCdAt[e] or 0) then return end
    fireCdAt[e] = now + FIRE_CD
    local aim = (target + Vector3.new(0, 3, 0)) - npos
    local am = aim.Magnitude
    if am > 1e-3 then
        local v = aim / am * BOLT_SPEED
        bolts[#bolts + 1] = { ox = npos.X, oy = npos.Y, oz = npos.Z, vx = v.X, vy = v.Y, vz = v.Z, t0 = now, dmg = BOLT_DMG }
        boltBatch[#boltBatch + 1] = { origin = npos, vel = v, t0 = now, life = BOLT_LIFE }
    end
end

-- BEAM: endpoint lags toward the player → slow, dodgeable (elite/boss UFOs). Bursts ON/OFF; during
-- the OFF cooldown we send NOTHING for this UFO, so the client drops the beam after BEAM_TIMEOUT.
local function doBeam(e: number, now: number, npos: Vector3, target: Vector3, dt: number, dps: number)
    local phase = beamPhase(e, now)
    if phase == "off" then beamTarget[e] = nil; return end -- cooling down → beam off
    local aimPt = target + Vector3.new(0, 3, 0)
    local bt = (beamTarget[e] or npos):Lerp(aimPt, math.min(1, BEAM_FOLLOW * dt))
    beamTarget[e] = bt
    local firing = phase == "fire"
    beamBatch[#beamBatch + 1] = { id = e, target = bt, charging = if firing then 0 else 1 }
    if firing then damageAt(bt, BEAM_HIT_R2, dps * dt) end -- damage ONLY once the warning is over
end

local function tick(dt: number)
    gatherTargets()
    local now = workspace:GetServerTimeNow()
    table.clear(moveBatch)
    table.clear(beamBatch)
    table.clear(seen)

    if #targets > 0 then
        for e, transform, speed in ufosNormal do
            local npos, target = moveUfo(e, transform, speed, dt)
            if npos then doBolt(e, now, npos, target :: Vector3) end
        end
        for e, transform, speed in ufosElite do
            local npos, target = moveUfo(e, transform, speed, dt)
            if npos then doBeam(e, now, npos, target :: Vector3, dt, BEAM_DPS) end
        end
        for e, transform, speed in ufosBoss do
            local npos, target = moveUfo(e, transform, speed, dt)
            if npos then doBeam(e, now, npos, target :: Vector3, dt, BEAM_DPS * BOSS_BEAM_MUL) end
        end
    end

    boltStep(now)

    -- drop per-UFO state for ones that died (no longer in the query)
    for e in fireCdAt do if not seen[e] then fireCdAt[e] = nil end end
    for e in beamTarget do if not seen[e] then beamTarget[e] = nil end end

    if #moveBatch > 0 then fireChunked(blink.UfoMove, moveBatch) end
    if #beamBatch > 0 then fireChunked(blink.UfoBeam, beamBatch) end
    if #boltBatch > 0 then blink.UfoFire.FireAll(boltBatch); table.clear(boltBatch) end
end

local acc = 0
local function wrapper(dt: number)
    acc += dt
    if acc < TICK then return end
    local step = acc
    acc = 0
    tick(step)
end

scheduler.SYSTEM(wrapper, phases.AIMovement)
return 0
