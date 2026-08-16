-- ServerScriptService/systems/SpawnMob.luau
-- WAVE spawner: spawn a whole wave (normals ramped in over a couple seconds + a few elites),
-- let the player clear it, short breather, then the next (bigger, tougher) wave. Exposes
-- resetRun() so a death/restart wipes the field and starts over at wave 1.
--!optimize 2
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players             = game:GetService("Players")

local blink    = require(ServerScriptService.ServerNet)
local std      = ReplicatedStorage.std
local Nav      = require(std.Nav) -- SAME graph the horde flows over (navmesh or PathData) — serials must match

local world     = require(std.world)
local cts       = require(std.components)
local scheduler = require(std.scheduler)
local phases    = require(std.phases)
local Config    = require(std.config)

local Transform = cts.Transform
local Size      = cts.Size
local Mob       = cts.Mob
local MobType   = cts.MobType
local Speed     = cts.Speed
local PathNode  = cts.PathNode
local Health    = cts.Health
local Elite     = cts.Elite
local Boss      = cts.Boss
local Flying    = cts.Flying
local Slot      = cts.Slot

-- the active graph (navmesh when USE_NAVMESH, else PathData) — MUST be the one horde reads, so a mob's
-- spawn position + PathNode serial line up with the flow field. Nav.init ran in main.server; no-op here.
Nav.init()
local Waypoints = Nav.Waypoints

-- ── Tunables (all live in std/config.luau now — one place to tweak) ─────────────
local Debug = Config.Debug
local C     = Config.Spawn

local ZOMBIE_TYPE  = C.ZOMBIE_TYPE
local ZOMBIE_SPEED = C.ZOMBIE_SPEED
local ZOMBIE_HP    = C.ZOMBIE_HP
local NORMAL_SIZE  = C.NORMAL_SIZE
local ELITE_SIZE   = C.ELITE_SIZE
local ELITE_SPEED  = C.ELITE_SPEED
local ELITE_HP_MUL = C.ELITE_HP_MUL
local BOSS_SIZE    = C.BOSS_SIZE
local BOSS_SPEED   = C.BOSS_SPEED
local BOSS_HP_MUL  = C.BOSS_HP_MUL

local MAX_ZOMBIES   = C.MAX_ZOMBIES
local BASE_WAVE     = C.BASE_WAVE
local WAVE_GROW     = C.WAVE_GROW
local HP_GROWTH     = C.HP_GROWTH
local ELITE_FROM    = C.ELITE_FROM
local BOSS_EVERY    = C.BOSS_EVERY
local BREATHER      = C.BREATHER
local MAX_WAVE_TIME = C.MAX_WAVE_TIME
local SPAWN_EVERY   = C.SPAWN_EVERY
local SPAWN_BATCH   = C.SPAWN_BATCH

-- ── UFO flying enemy (a random sprinkle, not a replacement) ─────────────────────
local UFO_TYPE        = C.UFO_TYPE
local UFO_FROM        = C.UFO_FROM
local UFO_CHANCE      = C.UFO_CHANCE
local UFO_HOVER       = C.UFO_HOVER
local UFO_SPEED       = C.UFO_SPEED
local UFO_N_SCALE     = C.UFO_N_SCALE
local UFO_E_SCALE     = C.UFO_E_SCALE
local UFO_B_SCALE     = C.UFO_B_SCALE
local UFO_N_HP        = C.UFO_N_HP
local UFO_E_HP        = C.UFO_E_HP
local UFO_B_HP        = C.UFO_B_HP
local UFO_ELITE_CHANCE = C.UFO_ELITE_CHANCE
local UFO_BOSS_CHANCE  = C.UFO_BOSS_CHANCE

-- ── Spawn node pool ───────────────────────────────────────────────────────────
local NodeIDs: { number } = {}
for id in Waypoints do NodeIDs[#NodeIDs + 1] = id end
assert(#NodeIDs > 0, "Nav graph is empty! (navmesh bake produced no nodes, or PathData is empty)")
local function randomNodeID(): number
    return NodeIDs[math.random(1, #NodeIDs)]
end

local mobQuery = world:query(Mob):cached()
local function mobCount(): number
    local n = 0
    for _ in mobQuery do n += 1 end
    return n
end

-- ── Dense replication slot allocator ──────────────────────────────────────────────
-- Zombies stream their positions by SLOT (no per-mob id on the wire). Reuse freed slots
-- (lowest-first) so the live range stays dense; horde.luau sends one i8 delta per slot.
local freeSlots: { number } = {}
local nextSlot = 0
local function allocSlot(): number
    local n = #freeSlots
    if n > 0 then local s = freeSlots[n]; freeSlots[n] = nil; return s end
    local s = nextSlot; nextSlot += 1; return s
end

-- ── Spawn one mob ───────────────────────────────────────────────────────────────
local spawnBatch: { blink.MobSpawn } = {}
local function spawnOne(tier: "normal" | "elite" | "boss", hp: number)
    local node = randomNodeID()
    local pos  = Waypoints[node][1] :: Vector3
    local size = if tier == "boss" then BOSS_SIZE elseif tier == "elite" then ELITE_SIZE else NORMAL_SIZE
    local speed = if tier == "boss" then BOSS_SPEED elseif tier == "elite" then ELITE_SPEED else ZOMBIE_SPEED
    -- ±15% per-mob speed jitter: staggers the stream so the horde doesn't move as one uniform blob
    speed *= 0.85 + math.random() * 0.30

    local slot = allocSlot()
    local e = world:entity()
    world:add(e, Mob)
    world:set(e, Size, size)
    world:set(e, Speed, speed)
    world:set(e, MobType, ZOMBIE_TYPE)
    world:set(e, Transform, { new = CFrame.new(pos), old = CFrame.new(pos) })
    world:set(e, PathNode, node)
    world:set(e, Health, { hp = hp, max = hp })
    world:set(e, Slot, slot)
    if tier == "elite" then world:add(e, Elite) end
    if tier == "boss" then world:add(e, Boss) end

    local tierN = if tier == "boss" then 2 elseif tier == "elite" then 1 else 0
    spawnBatch[#spawnBatch + 1] = { id = e, slot = slot, pos = pos, size = size, type = ZOMBIE_TYPE, tier = tierN }
end
-- a UFO: flying ranged enemy. NO PathNode → horde.luau ignores it; ufo.luau drives it.
local function spawnUfo(tier: "normal" | "elite" | "boss", hp: number)
    local node = randomNodeID()
    local gp   = Waypoints[node][1] :: Vector3
    local pos  = gp + Vector3.new(0, UFO_HOVER, 0)
    local scale = if tier == "boss" then UFO_B_SCALE elseif tier == "elite" then UFO_E_SCALE else UFO_N_SCALE

    local e = world:entity()
    world:add(e, Mob)
    world:add(e, Flying)
    world:set(e, Size, scale)
    world:set(e, Speed, UFO_SPEED)
    world:set(e, MobType, UFO_TYPE)
    world:set(e, Transform, { new = CFrame.new(pos), old = CFrame.new(pos) })
    world:set(e, Health, { hp = hp, max = hp })
    if tier == "elite" then world:add(e, Elite) end
    if tier == "boss" then world:add(e, Boss) end

    -- UFOs stream via UfoMove (no Slot component) → slot = 0 (unused by the client for UFOs)
    local tierN = if tier == "boss" then 2 elseif tier == "elite" then 1 else 0
    spawnBatch[#spawnBatch + 1] = { id = e, slot = 0, pos = pos, size = scale, type = UFO_TYPE, tier = tierN }
end

local function flushSpawn()
    if #spawnBatch > 0 then blink.Spawn.FireAll(spawnBatch); table.clear(spawnBatch) end
end

-- ── Wave state machine ──────────────────────────────────────────────────────────
local wave = 0
local running = false -- gated: the run only begins on the first Play / Restart (main menu)
local phase: "spawning" | "fighting" | "breather" = "breather"
local toSpawn, curHp, curEliteHp, curElites = 0, 0, 0, 0
local curBoss = false
local spawnAcc, fightTimer, breatherTimer = 0, 0, 0

local function startWave()
    wave += 1
    local size = math.min(MAX_ZOMBIES, BASE_WAVE + (wave - 1) * WAVE_GROW)
    -- DEBUG: dump the whole horde on wave 1 to stress the renderer right away.
    if Debug.STRESS_TEST and wave == 1 then
        size = math.min(MAX_ZOMBIES, Debug.STRESS_COUNT)
    end
    curHp = ZOMBIE_HP * (1 + (wave - 1) * HP_GROWTH)
    curEliteHp = curHp * ELITE_HP_MUL
    curElites = if wave >= ELITE_FROM then 1 + wave // 4 else 0
    curBoss = (wave % BOSS_EVERY == 0) -- boss wave → drops a pet
    toSpawn = size
    spawnAcc = 0
    phase = "spawning"
    blink.WaveStart.FireAll(wave)
end

local function step(dt: number)
    if not running then return end -- waiting at the main menu
    if phase == "spawning" then
        spawnAcc += dt
        if spawnAcc >= SPAWN_EVERY then
            spawnAcc = 0
            -- fast fill while stress-dumping wave 1, normal ramp otherwise
            local batch = if Debug.STRESS_TEST and wave == 1 then C.STRESS_BATCH else SPAWN_BATCH
            local n = math.min(batch, toSpawn)
            for _ = 1, n do
                if wave >= UFO_FROM and math.random() < UFO_CHANCE then
                    spawnUfo("normal", curHp * UFO_N_HP) -- a stray flyer mixed into the horde
                else
                    spawnOne("normal", curHp)
                end
            end
            toSpawn -= n
            if toSpawn <= 0 then
                for _ = 1, curElites do
                    if math.random() < UFO_ELITE_CHANCE then spawnUfo("elite", curEliteHp * UFO_E_HP)
                    else spawnOne("elite", curEliteHp / 4) end
                end
                if curBoss then
                    if math.random() < UFO_BOSS_CHANCE then spawnUfo("boss", curHp * BOSS_HP_MUL * UFO_B_HP)
                    else spawnOne("boss", curHp * BOSS_HP_MUL / 4) end
                end
                phase = "fighting"
                fightTimer = 0
            end
            flushSpawn()
        end
    elseif phase == "fighting" then
        fightTimer += dt
        if mobCount() == 0 or fightTimer >= MAX_WAVE_TIME then
            phase = "breather"
            breatherTimer = BREATHER
        end
    else -- breather
        breatherTimer -= dt
        if breatherTimer <= 0 then startWave() end
    end
end

-- ── Public ────────────────────────────────────────────────────────────────────
local M = {}
function M.currentWave(): number
    return wave
end

-- combat.luau calls this when a slotted mob (zombie) dies → recycle its slot
function M.freeSlot(slot: number)
    freeSlots[#freeSlots + 1] = slot
end

-- wipe the field and restart waves (called on player restart)
function M.resetRun()
    local ids = {}
    for e in mobQuery do ids[#ids + 1] = e end
    for _, e in ids do world:delete(e) end
    if #ids > 0 then blink.Death.FireAll(ids) end
    -- reset the slot allocator: fresh field starts dense at slot 0
    table.clear(freeSlots)
    nextSlot = 0
    running = true -- Play / Restart begins (or restarts) the run
    wave = 0
    startWave()
end

-- end the round WITHOUT starting a new one: wipe the field + stop spawning. Called when the
-- arena empties (the last living player died or disconnected) so an idle server doesn't keep
-- simulating a ghost horde — the next Play/Restart calls resetRun() for a clean wave 1.
function M.endRun()
    if not running then return end
    running = false
    wave = 0
    phase = "breather"
    breatherTimer = 0
    local ids = {}
    for e in mobQuery do ids[#ids + 1] = e end
    for _, e in ids do world:delete(e) end
    if #ids > 0 then blink.Death.FireAll(ids) end
    table.clear(freeSlots)
    nextSlot = 0
end

function M.isRunning(): boolean
    return running
end

-- ── Late-joiner replay ──────────────────────────────────────────────────────────
local replayQuery = world:query(Transform, Size, MobType):with(Mob):cached()
local function sendAllMobsTo(player: Player)
    local payload: { blink.MobSpawn } = {}
    for e, transform, size, mobType in replayQuery do
        local tierN = if world:has(e, Boss) then 2 elseif world:has(e, Elite) then 1 else 0 -- tags → use has, not get
        payload[#payload + 1] = { id = e, slot = world:get(e, Slot) or 0, pos = transform.new.Position, size = size, type = mobType, tier = tierN }
    end
    if #payload > 0 then blink.Spawn.Fire(player, payload) end
    blink.WaveStart.Fire(player, wave)
end

scheduler.SYSTEM(step, phases.Heartbeat)
scheduler.SYSTEM(sendAllMobsTo, phases.PlayerAdded)
for _, p in Players:GetPlayers() do sendAllMobsTo(p) end

-- NOTE: waves do NOT auto-start. The first Play/Restart (main menu → Restart event) calls
-- resetRun(), which sets running=true and starts wave 1.
return M
