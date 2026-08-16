-- ClientSystems/syncHazards.luau
-- Renders persistent ground HAZARDS (HazardSpawn / HazardRemove): unicorn rainbow puddles (DoT+slow),
-- panda bamboo pillars, and penguin ICE patches. Pure presentation — the server owns the damage.
-- kind: 1 = rainbow puddle, 2 = bamboo, 3 = giant bamboo, 4 = ice patch. Ground kinds raycast down so
-- they sit ON the floor (server positions are at root/bullet height). Each despawns on HazardRemove,
-- or self-expires after `life` (fallback).
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))

local Assets    = ReplicatedStorage:WaitForChild("Assets", 2)
if not Assets then warn("[syncHazards] no ReplicatedStorage.Assets in this place — rendering disabled"); return 0 end
local bambooSrc = Assets:FindFirstChild("Bamboo")

local folder = Instance.new("Folder")
folder.Name = "Hazards"
folder.Parent = workspace

-- snap a hazard to the floor (CanQuery=false visuals are skipped by raycasts automatically)
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { folder }
local DOWN = Vector3.new(0, -60, 0)
local function groundPos(pos: Vector3): Vector3
    local hit = workspace:Raycast(pos + Vector3.new(0, 6, 0), DOWN, rayParams)
    return if hit then Vector3.new(pos.X, hit.Position.Y + 0.15, pos.Z) else pos
end

type Haz = { inst: Instance, kind: number, born: number, life: number, puddle: BasePart?,
    pos: Vector3?, sink: number?, risen: boolean? } -- pos/sink/risen drive the bamboo rise from the ground
local haz: { [number]: Haz } = {}

local RISE_TIME = 0.35 -- seconds for bamboo to push up out of the ground
-- Assets.Bamboo's pivot is at its BASE, so PivotTo(pos) stands it on the ground. To bury it we drop
-- by ~its height; the giant (ScaleTo 2.2) is taller, so it needs a deeper sink to stay hidden.
local SINK, SINK_GIANT = 16, 36

-- a flat rainbow disc on the ground (Cylinder rotated so its axis points up)
local function buildPuddle(pos: Vector3, r: number): (Instance, BasePart)
    local p = Instance.new("Part")
    p.Shape = Enum.PartType.Cylinder
    p.Size = Vector3.new(0.4, r * 2, r * 2)
    p.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.pi / 2)
    p.Material = Enum.Material.Neon
    p.Color = Color3.fromRGB(200, 150, 255)
    p.Transparency = 0.45
    p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
    p.Parent = folder
    return p, p
end

-- a bamboo stalk popped from the ground (clone Assets.Bamboo). Returns (inst, sinkDepth). The model's
-- pivot is its base, so it starts dropped `sink` below ground (buried); step() raises it to `pos`.
local function buildBamboo(pos: Vector3, r: number, giant: boolean): (Instance, number)
    local sink = if giant then SINK_GIANT else SINK
    if bambooSrc and bambooSrc:IsA("Model") then
        local m = bambooSrc:Clone() :: Model
        for _, d in m:GetDescendants() do
            if d:IsA("BasePart") then
                d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false; d.CastShadow = false
            elseif d:IsA("Humanoid") or d:IsA("BaseScript") or d:IsA("ModuleScript") then
                d:Destroy()
            end
        end
        if not m.PrimaryPart then m.PrimaryPart = m:FindFirstChildWhichIsA("BasePart", true) end
        if giant then m:ScaleTo(2.2) end
        m:PivotTo(CFrame.new(pos - Vector3.new(0, sink, 0))) -- buried (base pivot); step() rises it
        m.Parent = folder
        return m, sink
    end
    -- fallback: a green pole (base pivot via a manual base offset; starts buried)
    local p = Instance.new("Part")
    p.Size = Vector3.new(1.2, giant and 30 or 14, 1.2)
    p.Color = Color3.fromRGB(120, 200, 110)
    p.PivotOffset = CFrame.new(0, -p.Size.Y / 2, 0) -- move pivot to the base so it behaves like the model
    p.CFrame = CFrame.new(pos - Vector3.new(0, sink, 0)) * CFrame.new(0, p.Size.Y / 2, 0)
    p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
    p.Parent = folder
    return p, sink
end

-- a tall ICE WALL column (Glacier Wall): rises from the ground like bamboo, then stands. Square
-- columns side by side read as a wall without needing an orientation on the wire.
local ICE_SINK = 8
local function buildIceWall(pos: Vector3, r: number): (BasePart, number)
    local p = Instance.new("Part")
    p.Size = Vector3.new(r * 2, 7, r * 1.6)
    p.PivotOffset = CFrame.new(0, -3.5, 0) -- pivot at the base so the rise math matches bamboo
    p.CFrame = CFrame.new(pos - Vector3.new(0, ICE_SINK, 0)) * CFrame.new(0, 3.5, 0)
    p.Material = Enum.Material.Ice
    p.Color = Color3.fromRGB(180, 230, 255)
    p.Transparency = 0.15
    p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
    p.Parent = folder
    return p, ICE_SINK
end

-- a flat ICE patch (penguin trail): icy slab, NO rainbow cycle — visually distinct
-- from the unicorn puddle so "what is slowing them" reads at a glance
local function buildIce(pos: Vector3, r: number): BasePart
    local p = Instance.new("Part")
    p.Size = Vector3.new(r * 2, 0.35, r * 2)
    p.CFrame = CFrame.new(pos) * CFrame.Angles(0, (pos.X + pos.Z) * 0.7 % math.pi, 0) -- varied facing, no Random needed
    p.Material = Enum.Material.Ice
    p.Color = Color3.fromRGB(170, 225, 255)
    p.Transparency = 0.25
    p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
    p.Parent = folder
    return p
end

blink.HazardSpawn.On(function(batch)
    for _, h in batch do
        if haz[h.id] then continue end
        local pos = h.pos :: Vector3
        if h.kind == 1 then
            local inst, puddle = buildPuddle(groundPos(pos), h.radius)
            haz[h.id] = { inst = inst, kind = 1, born = os.clock(), life = h.life, puddle = puddle }
        elseif h.kind == 6 then -- MILK puddle (cow splash): white disc, NO rainbow cycle (the
            -- cycler keys off the `puddle` field, so we deliberately don't store one)
            local inst, milk = buildPuddle(groundPos(pos), h.radius)
            milk.Color = Color3.fromRGB(245, 242, 230)
            milk.Material = Enum.Material.SmoothPlastic
            milk.Transparency = 0.2
            haz[h.id] = { inst = inst, kind = 6, born = os.clock(), life = h.life }
        elseif h.kind == 4 then
            local inst = buildIce(groundPos(pos), h.radius)
            haz[h.id] = { inst = inst, kind = 4, born = os.clock(), life = h.life }
        elseif h.kind == 5 then -- ice WALL column: same rise-from-ground path as bamboo (pos/sink)
            local gp = groundPos(pos)
            local inst, sink = buildIceWall(gp, h.radius)
            haz[h.id] = { inst = inst, kind = 5, born = os.clock(), life = h.life, pos = gp, sink = sink, risen = false }
        else
            local inst, sink = buildBamboo(pos, h.radius, h.kind == 3)
            haz[h.id] = { inst = inst, kind = h.kind, born = os.clock(), life = h.life, pos = pos, sink = sink, risen = false }
        end
    end
end)

local function destroy(id: number)
    local h = haz[id]
    if h then (h.inst :: Instance):Destroy(); haz[id] = nil end
end

blink.HazardRemove.On(function(ids)
    for _, id in ids do destroy(id) end
end)

local function step(_dt: number)
    local now = os.clock()
    for id, h in haz do
        if now - h.born > h.life + 0.5 then destroy(id); continue end -- fallback despawn
        if h.puddle then -- cycle the rainbow + gentle pulse
            local t = (now * 0.25 + id * 0.13) % 1
            h.puddle.Color = Color3.fromHSV(t, 0.75, 1)
            h.puddle.Transparency = 0.4 + 0.12 * math.sin(now * 4)
        elseif h.pos and not h.risen then
            -- bamboo: push up out of the ground (ease-out), then stay
            local t = (now - h.born) / RISE_TIME
            if t >= 1 then
                t = 1; h.risen = true
            end
            local ease = 1 - (1 - t) * (1 - t) -- ease-out
            local y = -(h.sink or SINK) * (1 - ease)
            local inst = h.inst :: PVInstance
            inst:PivotTo(CFrame.new(h.pos + Vector3.new(0, y, 0)))
        end
    end
end

scheduler.SYSTEM(step, phases.Heartbeat)
return 0
