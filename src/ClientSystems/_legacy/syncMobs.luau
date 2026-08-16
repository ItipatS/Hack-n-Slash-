-- ClientSystems/syncMobs.luau
-- Client horde rendering — PURE PRESENTATION. The server owns movement + separation and
-- streams authoritative positions (Spawn = initial, UpdateTransformDelta = f16 deltas,
-- UpdateTransformFull = f32 snapshots). The client interpolates toward the latest target and
-- draws one pooled ZOMBIE RIG per mob via BulkMoveTo (only the anchored root is moved; the
-- jointed limbs follow). No recompute, no raycasts, no client-side separation — what you see
-- matches the server hitboxes. Elites/bosses are the same rig, scaled up (server `size`).
--!optimize 2
--!native
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))

local ref    = require(std:WaitForChild("ref"))
local blink  = require(std:WaitForChild("ClientNet"))
local Pool   = require(std:WaitForChild("MobRenderPool"))
local Config = require(std:WaitForChild("config"))
local MobBar = require(std:WaitForChild("mobBar"))

local STEP = Config.Net.STEP -- must match the server's i8 delta quantization

-- ── Render constants ──────────────────────────────────────────────────────────
local BASE_LIFT = 3       -- R6 foot→HumanoidRootPart offset; scales with the rig (×size)
local LERP_RATE = 14      -- interpolation rate toward the streamed target (smooths 15Hz net)
local EPS2      = 0.02    -- min move² to update facing/walk — higher so near-stationary mobs jostling
                         -- in the swarm keep their heading (don't spin to face tiny separation jitter)
local WALK_FREQ = 9       -- procedural leg-swing rate (no Humanoid/Animator — scales to the horde)
local WALK_AMP  = 0.55    -- leg swing amplitude (radians)
local HEADING_RATE = 8    -- how fast the facing eases toward the velocity dir (damps delta jitter)

-- no Assets.Zombie in this place (pivot prototype baseplate) → no horde rendering; bail as a
-- no-op so the rest of the client boot (start() requires every system serially) is never blocked
local assetsFolder = ReplicatedStorage:WaitForChild("Assets", 2)
local zombieSrc = assetsFolder and assetsFolder:WaitForChild("Zombie", 2)
if not (zombieSrc and zombieSrc:IsA("Model")) then
    warn("[syncMobs] no ReplicatedStorage.Assets.Zombie in this place — mob rendering disabled")
    return 0
end

-- ── Zombie rig template (cloned from the Studio rig, stripped + posed for cheap rendering) ──
local function buildTemplate(): Model
    local src = zombieSrc :: Model
    local t = src:Clone()
    -- drop everything non-visual (Humanoid/Animator, scripts, sounds) — we only render a pose.
    -- ALSO strip the Head's SpecialMesh: the rounded head mesh is ~500-1000 tris EACH, and at
    -- 3000 mobs that one mesh was ~2-3M triangles (the whole opaque-tri budget). A blocky head
    -- is 12 tris. This is the single biggest render win for the horde.
    for _, d in t:GetDescendants() do
        if d:IsA("Humanoid") or d:IsA("BaseScript") or d:IsA("ModuleScript")
            or d:IsA("Sound") or d:IsA("SpecialMesh") then
            d:Destroy()
        end
    end
    local prim = (t.PrimaryPart or t:FindFirstChild("HumanoidRootPart")) :: BasePart
    t.PrimaryPart = prim
    -- only the root is anchored; limbs stay jointed (Motor6D) so moving the root drags the body
    for _, d in t:GetDescendants() do
        if d:IsA("BasePart") then
            d.CanCollide = false
            d.CanQuery   = false
            d.CanTouch   = false
            d.CastShadow = false
            d.Massless   = true
            d.Anchored   = (d == prim)
        end
    end
    return t
end

local template = buildTemplate()

-- per-part base colours (for restoring after a hit flash)
local templateColors: { [string]: Color3 } = {}
for _, d in template:GetDescendants() do
    if d:IsA("BasePart") then templateColors[d.Name] = d.Color end
end
local DEFAULT_COLOR = Color3.fromRGB(120, 160, 110)
local FLASH_COLOR   = Color3.fromRGB(255, 255, 255)
local FLASH_DUR     = 0.1

local MobsFolder = Instance.new("Folder")
MobsFolder.Name = "Mobs"
MobsFolder.Parent = workspace

local pool = Pool.new(template, MobsFolder)

-- per-entity streamed target + interpolated render position (ground level)
local target:    { [number]: Vector3 } = {}
local renderPos: { [number]: Vector3 } = {}
local mobLift:   { [number]: number } = {}   -- root lift above ground (scales with rig size)
local mobParts:  { [number]: { BasePart } } = {} -- cached rig parts for the hit flash
local mobLegs:   { [number]: { Motor6D } } = {}  -- {leftHip, rightHip} for the walk swing
local mobWalking: { [number]: boolean } = {}
local flashUntil: { [number]: number } = {}
local heading:    { [number]: Vector3 } = {} -- smoothed facing dir (XZ unit), damps delta jitter
local mobBarGui:  { [number]: BillboardGui } = {} -- elite/boss health-bar billboards (pooled rigs → remove on death)
local mobBarFill: { [number]: Frame } = {}         -- the fill Frame (X scale = hp/max)
-- dense-slot maps: the wire streams positions by SLOT (no id), so we map slot↔entity here
local slotToEntity: { [number]: number } = {}
local slotOf:       { [number]: number } = {}

-- ── Net ───────────────────────────────────────────────────────────────────────
blink.Spawn.On(function(batch)
    for _, payload in batch do
        if payload.type ~= "Zombie" then continue end
        local e = ref("server-" .. tostring(payload.id))
        if pool:get(e) then continue end
        local pos  = payload.pos :: Vector3
        local size = payload.size
        local lift = BASE_LIFT * size
        local model = pool:acquire(e, CFrame.new(pos + Vector3.new(0, lift, 0)), size)
        target[e] = pos
        renderPos[e] = pos
        mobLift[e] = lift
        slotToEntity[payload.slot] = e -- map this zombie's dense slot → its client entity
        slotOf[e] = payload.slot
        if payload.tier >= 1 then -- elite or boss → floating health bar (boss also gets 👑 BOSS)
            local root = model.PrimaryPart
            if root then
                local bb, fill = MobBar.attach(root, 5 * size + 4, payload.tier == 2)
                mobBarGui[e] = bb
                mobBarFill[e] = fill
            end
        end
        local parts: { BasePart } = {}
        local legs: { Motor6D } = {}
        for _, d in model:GetDescendants() do
            if d:IsA("BasePart") then
                parts[#parts + 1] = d
            elseif d:IsA("Motor6D") and d.Part1 then
                if d.Part1.Name == "Left Leg" then legs[1] = d
                elseif d.Part1.Name == "Right Leg" then legs[2] = d end
            end
        end
        mobParts[e] = parts
        if legs[1] and legs[2] then mobLegs[e] = legs end
    end
end)

-- One dense chunk: i8 deltas in slot order from chunk.base. slot = base + index/3; map to entity.
blink.UpdateTransformDelta.On(function(chunk)
    local deltas = chunk.deltas
    local n = #deltas
    local slot = chunk.base
    local i = 0
    while i < n do
        local e = slotToEntity[slot]
        if e then
            local cur = target[e]
            if cur then
                target[e] = cur + Vector3.new(deltas[i + 1] * STEP, deltas[i + 2] * STEP, deltas[i + 3] * STEP)
            end
        end
        i += 3
        slot += 1
    end
end)

blink.UpdateTransformFull.On(function(batch)
    for _, t in batch do
        local e = ref("server-" .. tostring(t.id))
        target[e] = t.dp :: Vector3
        if not renderPos[e] then renderPos[e] = t.dp :: Vector3 end
    end
end)

blink.Death.On(function(ids)
    for _, id in ids do
        local e = ref("server-" .. tostring(id))
        if pool:get(e) then pool:release(e) end
        target[e] = nil
        renderPos[e] = nil
        mobLift[e] = nil
        mobParts[e] = nil
        mobLegs[e] = nil
        mobWalking[e] = nil
        flashUntil[e] = nil
        heading[e] = nil
        if mobBarGui[e] then mobBarGui[e]:Destroy(); mobBarGui[e] = nil; mobBarFill[e] = nil end -- pooled rig → drop the bar
        local s = slotOf[e] -- free the dense slot map (jecs id recycles → must clear)
        if s then slotToEntity[s] = nil; slotOf[e] = nil end
    end
end)

blink.Hit.On(function(ids)
    local now = os.clock()
    for _, id in ids do
        local e = ref("server-" .. tostring(id))
        local parts = mobParts[e]
        if parts then
            for _, p in parts do p.Color = FLASH_COLOR end
            flashUntil[e] = now + FLASH_DUR
        end
    end
end)

-- elite/boss HP → update the floating health bar fill (ManySync; UFOs handle their own ids)
blink.MobHealth.On(function(batch)
    for _, h in batch do
        local fill = mobBarFill[ref("server-" .. tostring(h.id))]
        if fill then
            fill.Size = UDim2.new(if h.max > 0 then math.clamp(h.hp / h.max, 0, 1) else 0, 0, 1, 0)
        end
    end
end)

-- ── Render ──────────────────────────────────────────────────────────────────────
local function move(dt: number)
    local a = math.min(1, LERP_RATE * dt)

    -- restore colour on flashes that have expired
    local now = os.clock()
    for e, until_ in flashUntil do
        if now >= until_ then
            local parts = mobParts[e]
            if parts then
                for _, p in parts do p.Color = templateColors[p.Name] or DEFAULT_COLOR end
            end
            flashUntil[e] = nil
        end
    end

    for e, tgt in target do
        local part = pool:get(e)
        if not part then continue end
        local rp = renderPos[e] or tgt
        local nrp = rp:Lerp(tgt, a)
        renderPos[e] = nrp
        local lift = mobLift[e] or BASE_LIFT

        local fx, fz = tgt.X - rp.X, tgt.Z - rp.Z -- instantaneous velocity dir
        local moving = fx * fx + fz * fz > EPS2
        -- The i8 deltas (sent every tick, incl. tiny separation jitter on packed mobs) make the
        -- raw per-frame direction noisy, which spun the rigs. Ease a KEPT heading toward it instead.
        local h = heading[e]
        if moving then
            local inv = 1 / math.sqrt(fx * fx + fz * fz)
            local ndx, ndz = fx * inv, fz * inv
            if h then
                local b = math.min(1, HEADING_RATE * dt)
                local hx, hz = h.X + (ndx - h.X) * b, h.Z + (ndz - h.Z) * b
                local hm = math.sqrt(hx * hx + hz * hz)
                h = if hm > 1e-4 then Vector3.new(hx / hm, 0, hz / hm) else Vector3.new(ndx, 0, ndz)
            else
                h = Vector3.new(ndx, 0, ndz)
            end
            heading[e] = h
        end
        local p = Vector3.new(nrp.X, nrp.Y + lift, nrp.Z)
        local cf: CFrame = if h then CFrame.lookAt(p, p + h)
            else CFrame.new(nrp.X, nrp.Y + lift, nrp.Z) * part.CFrame.Rotation
        pool:setCFrame(e, cf)

        -- procedural walk: swing the hips while moving, rest to neutral when stopped
        local legs = mobLegs[e]
        if legs then
            if moving then
                -- hip C0 has a -90° Y twist → local Z is the front/back swing axis. The two hips
                -- are MIRRORED, so the SAME signed rotation swings them in opposite world
                -- directions (i.e. alternating stride); opposite signs would move them together.
                local s = math.sin(now * WALK_FREQ + e * 0.7) * WALK_AMP
                legs[1].Transform = CFrame.Angles(0, 0, s)
                legs[2].Transform = CFrame.Angles(0, 0, s)
                mobWalking[e] = true
            elseif mobWalking[e] then
                legs[1].Transform = CFrame.identity
                legs[2].Transform = CFrame.identity
                mobWalking[e] = false
            end
        end
    end
    pool:flush()
end

scheduler.SYSTEM(move, phases.Heartbeat)
return 0
