-- ClientSystems/syncUFO.luau
-- Renders UFO flying enemies — PURE PRESENTATION. They arrive on the shared Spawn event
-- (type "UFO", size = scale), move via their own UfoMove stream, and despawn on Death (shared
-- with zombies, ManySync). Also draws their attacks: laser BOLTS (UfoFire, formula motion) and
-- the elite/boss BEAM (UfoBeam: a line from the UFO to the streamed, lagging endpoint).
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))
local dropFx    = require(std:WaitForChild("dropFx"))
local MobBar    = require(std:WaitForChild("mobBar"))

local Assets = ReplicatedStorage:WaitForChild("Assets", 2)
if not Assets then warn("[syncUFO] no ReplicatedStorage.Assets in this place — rendering disabled"); return 0 end

local LERP_RATE = 12
local BOB_FREQ  = 2.0
local BOB_AMP   = 0.6
local UFO_ORIENT = CFrame.Angles(0, 0, math.rad(-90)) -- render-time orientation fix for the asset
local BEAM_TIMEOUT = 0.25 -- beam off if no update within this (server streams it ~20Hz)
local FLASH_COLOR = Color3.fromRGB(255, 255, 255)
local FLASH_DUR   = 0.1

local folder = Instance.new("Folder") -- UFO models only (so the HUD mob-count is clean)
folder.Name = "UFOs"
folder.Parent = workspace

local fxFolder = Instance.new("Folder") -- bolts + beams
fxFolder.Name = "UfoFx"
fxFolder.Parent = workspace

-- ── UFO model ─────────────────────────────────────────────────────────────────────
local function makeUfo(scale: number): Model
    local src = Assets:FindFirstChild("UFO")
    local m: Model
    if src and src:IsA("Model") then
        m = src:Clone()
    else
        m = Instance.new("Model")
        local p = Instance.new("Part")
        p.Shape = Enum.PartType.Ball
        p.Size = Vector3.new(6, 2.4, 6)
        p.Color = Color3.fromRGB(150, 160, 175)
        p.Material = Enum.Material.Metal
        if src and src:IsA("BasePart") then p = src:Clone() end
        p.Parent = m
        m.PrimaryPart = p
    end
    -- Do NOT touch PrimaryPart for the authored model: with none set, PivotTo uses the model's
    -- axis-aligned bounding-box pivot, which keeps the asset's authored orientation. Forcing a
    -- random part as PrimaryPart would tilt the whole model to that part's frame.
    dropFx.staticize(m)
    if m:GetScale() ~= scale then m:ScaleTo(scale) end
    return m
end

-- Each UFO is WELDED into a single assembly with one anchored root part, so per frame we move
-- ONE root (the ~28 parts follow via WeldConstraints) instead of pushing all 28 through
-- BulkMoveTo. At ~170 UFOs that's 170 moved parts/frame instead of ~4700 — UFOs were secretly
-- moving more parts than the entire zombie horde (3000 roots).
type Ufo = { model: Model, root: BasePart, target: Vector3, render: Vector3, parts: { BasePart }, colors: { Color3 }, flashUntil: number }
local ufos: { [number]: Ufo } = {}
local ufoBarFill: { [number]: Frame } = {} -- elite/boss UFO health-bar fill (X scale = hp/max)

blink.Spawn.On(function(batch)
    for _, p in batch do
        if p.type ~= "UFO" then continue end
        if ufos[p.id] then continue end
        local pos = p.pos :: Vector3
        local m = makeUfo(p.size)
        local pivot = CFrame.new(pos) * UFO_ORIENT
        m:PivotTo(pivot)
        -- anchored invisible root at the pivot; weld every visible part to it (capturing their
        -- current world offsets) and unanchor them so moving the root drags the whole UFO
        local root = Instance.new("Part")
        root.Name = "MoveRoot"
        root.Size = Vector3.new(0.2, 0.2, 0.2)
        root.Transparency = 1
        root.Anchored = true
        root.CanCollide = false; root.CanQuery = false; root.CanTouch = false; root.CastShadow = false
        root.CFrame = pivot
        root.Parent = m
        local parts: { BasePart }, colors: { Color3 } = {}, {}
        for _, d in m:GetDescendants() do
            if d:IsA("BasePart") and d ~= root then
                parts[#parts + 1] = d
                colors[#colors + 1] = d.Color
                d.Anchored = false
                local wc = Instance.new("WeldConstraint")
                wc.Part0 = root; wc.Part1 = d; wc.Parent = root
            end
        end
        m.PrimaryPart = root
        m.Parent = folder
        if p.tier >= 1 then -- elite/boss UFO → health bar (boss also gets 👑 BOSS); dies with the model
            local _bb, fill = MobBar.attach(root, 4 * p.size + 3, p.tier == 2)
            ufoBarFill[p.id] = fill
        end
        ufos[p.id] = { model = m, root = root, target = pos, render = pos, parts = parts, colors = colors, flashUntil = 0 }
    end
end)

-- hurt flash: server sends Hit{ids} for mobs that took damage but survived (ManySync)
blink.Hit.On(function(ids)
    local now = os.clock()
    for _, id in ids do
        local u = ufos[id]
        if u then
            for _, part in u.parts do part.Color = FLASH_COLOR end
            u.flashUntil = now + FLASH_DUR
        end
    end
end)

blink.UfoMove.On(function(batch)
    for _, u in batch do
        local r = ufos[u.id]
        if r then r.target = u.pos :: Vector3 end
    end
end)

-- elite/boss UFO HP → update the floating health bar fill (ManySync; zombies handle their own ids)
blink.MobHealth.On(function(batch)
    for _, h in batch do
        local fill = ufoBarFill[h.id]
        if fill then
            fill.Size = UDim2.new(if h.max > 0 then math.clamp(h.hp / h.max, 0, 1) else 0, 0, 1, 0)
        end
    end
end)

-- ── Bolts (laser bullets) ───────────────────────────────────────────────────────
type Bolt = { part: BasePart, ox: number, oy: number, oz: number, vx: number, vy: number, vz: number, t0: number, life: number }
local bolts: { Bolt } = {}
local boltFree: { BasePart } = {}

local function makeBoltPart(): BasePart
    local p = table.remove(boltFree)
    if p then return p end
    p = Instance.new("Part")
    -- a thin glowing BAR (oriented along travel below) reads as a laser bolt and is 12 tris,
    -- vs ~760 for a Ball — at a few hundred bolts that's the difference between ~190k and ~3k tris
    p.Shape = Enum.PartType.Block
    p.Size = Vector3.new(0.5, 0.5, 3.2)
    p.Material = Enum.Material.Neon
    p.Color = Color3.fromRGB(255, 120, 50)
    p.Anchored = true
    p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
    return p
end

blink.UfoFire.On(function(batch)
    for _, b in batch do
        local o = b.origin :: Vector3
        local v = b.vel :: Vector3
        local part = makeBoltPart()
        part.Position = o
        part.Parent = fxFolder
        bolts[#bolts + 1] = { part = part, ox = o.X, oy = o.Y, oz = o.Z, vx = v.X, vy = v.Y, vz = v.Z, t0 = b.t0, life = b.life }
    end
end)

-- ── Beams (elite/boss) ──────────────────────────────────────────────────────────
type Beam = { part: BasePart, target: Vector3, last: number, charging: boolean }
local beams: { [number]: Beam } = {}

local function makeBeamPart(): BasePart
    local p = Instance.new("Part")
    p.Material = Enum.Material.Neon
    p.Color = Color3.fromRGB(255, 60, 60)
    p.Size = Vector3.new(0.6, 0.6, 1)
    p.Anchored = true
    p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
    p.Parent = fxFolder
    return p
end

blink.UfoBeam.On(function(batch)
    local now = os.clock()
    for _, bm in batch do
        local b = beams[bm.id]
        if not b then b = { part = makeBeamPart(), target = bm.target :: Vector3, last = now, charging = false }; beams[bm.id] = b end
        b.target = bm.target :: Vector3
        b.last = now
        b.charging = bm.charging == 1
    end
end)

-- ── Despawn (shared Death event) ──────────────────────────────────────────────────
blink.Death.On(function(ids)
    for _, id in ids do
        local r = ufos[id]
        if r then r.model:Destroy(); ufos[id] = nil end
        ufoBarFill[id] = nil -- bar billboard was parented to the model → destroyed with it
        local b = beams[id]
        if b then b.part:Destroy(); beams[id] = nil end
    end
end)

-- Defensive: a round ended → wipe ALL lingering UFO state (models, beams, in-flight bolts) so
-- nothing can survive into the next round if a Death was ever missed (host teardown, etc.).
blink.RoundOver.On(function()
    for _, u in ufos do u.model:Destroy() end
    table.clear(ufos)
    for _, b in beams do b.part:Destroy() end
    table.clear(beams)
    for _, b in bolts do b.part.Parent = nil; boltFree[#boltFree + 1] = b.part end
    table.clear(bolts)
    table.clear(ufoBarFill)
end)

-- ── Render ──────────────────────────────────────────────────────────────────────
-- Reused scratch arrays for the one-shot BulkMoveTo (no per-frame realloc).
local moveParts: { BasePart } = {}
local moveCfs: { CFrame } = {}

local function step(dt: number)
    local a = math.min(1, LERP_RATE * dt)
    local clk = os.clock()
    local srvNow = workspace:GetServerTimeNow()

    -- UFOs: lerp toward streamed target + gentle bob, queue ONE root per UFO (welded parts follow).
    local mw = 0
    for _id, u in ufos do
        u.render = u.render:Lerp(u.target, a)
        local bob = math.sin(clk * BOB_FREQ + _id) * BOB_AMP
        mw += 1
        moveParts[mw] = u.root
        moveCfs[mw] = CFrame.new(u.render.X, u.render.Y + bob, u.render.Z) * UFO_ORIENT
        -- restore colours when the hurt flash expires
        if u.flashUntil > 0 and clk >= u.flashUntil then
            for i, part in u.parts do part.Color = u.colors[i] end
            u.flashUntil = 0
        end
    end
    -- bolts: formula motion, despawn at life. Queue live ones into the SAME scratch arrays so
    -- UFO parts AND every bolt move together in one BulkMoveTo below.
    local w = 1
    for i = 1, #bolts do
        local b = bolts[i]
        local age = srvNow - b.t0
        if age >= b.life then
            b.part.Parent = nil
            boltFree[#boltFree + 1] = b.part
        else
            mw += 1
            moveParts[mw] = b.part
            -- orient the bar along its velocity so the laser points where it's going
            local px, py, pz = b.ox + b.vx * age, b.oy + b.vy * age, b.oz + b.vz * age
            moveCfs[mw] = CFrame.lookAt(Vector3.new(px, py, pz), Vector3.new(px + b.vx, py + b.vy, pz + b.vz))
            bolts[w] = b
            w += 1
        end
    end
    for i = #bolts, w, -1 do bolts[i] = nil end

    -- trim scratch tails from a previous (larger) frame, then move UFOs + bolts at once
    for i = #moveParts, mw + 1, -1 do moveParts[i] = nil; moveCfs[i] = nil end
    if mw > 0 then workspace:BulkMoveTo(moveParts, moveCfs, Enum.BulkMoveMode.FireCFrameChanged) end

    -- beams: draw UFO → endpoint; drop if its UFO is gone or it stopped updating
    for id, b in beams do
        local u = ufos[id]
        if not u or (clk - b.last) > BEAM_TIMEOUT then
            b.part:Destroy()
            beams[id] = nil
        else
            local from = u.render
            local to = b.target
            local len = (from - to).Magnitude
            if b.charging then -- TELEGRAPH: thin, pulsing amber warning line — no damage yet, dodge it
                b.part.Size = Vector3.new(0.2, 0.2, math.max(0.2, len))
                b.part.Color = Color3.fromRGB(255, 190, 50)
                b.part.Transparency = 0.25 + 0.3 * (0.5 + 0.5 * math.sin(clk * 10))
            else -- FIRING: thick, opaque red death beam
                b.part.Size = Vector3.new(0.6, 0.6, math.max(0.2, len))
                b.part.Color = Color3.fromRGB(255, 60, 60)
                b.part.Transparency = 0
            end
            b.part.CFrame = CFrame.lookAt((from + to) * 0.5, to)
        end
    end
end

scheduler.SYSTEM(step, phases.Heartbeat)
return 0
