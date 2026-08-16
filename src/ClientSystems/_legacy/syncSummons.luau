-- ClientSystems/syncSummons.luau
-- Renders SUMMONED entities (bee Hive turrets / wolf spirits) as PLACEHOLDER cubes until real
-- models land. FORMULA position — SummonSpawn carries {origin, velocity, t0, life} once and the
-- client computes pos = origin + velocity*(now - t0), exactly like bubbles (no streaming).
-- Self-expires after `life`; SummonRemove handles early clears (owner died/left, round wipe).
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))

local folder = Instance.new("Folder")
folder.Name = "Summons"
folder.Parent = workspace

-- kind → placeholder look: 1 = hive turret (honey cube), 2 = spirit wolf (ghostly grey cube),
-- 3 = invisible emitter (crab Riptide / cow Stampede — the FX pulses ARE the visual)
local LOOKS: { [number]: { size: Vector3, color: Color3, transparency: number } } = {
    [1] = { size = Vector3.new(2.6, 2.6, 2.6), color = Color3.fromRGB(255, 200, 60), transparency = 0.1 },
    [2] = { size = Vector3.new(2, 2, 3), color = Color3.fromRGB(200, 205, 225), transparency = 0.45 },
    [3] = { size = Vector3.new(0.4, 0.4, 0.4), color = Color3.new(1, 1, 1), transparency = 1 },
}

type Summon = {
    part: BasePart,
    ox: number, oy: number, oz: number,
    vx: number, vy: number, vz: number,
    t0: number, life: number,
}
local active: { [number]: Summon } = {}

local function makePart(kind: number): BasePart
    local look = LOOKS[kind] or LOOKS[1]
    local p = Instance.new("Part")
    p.Size = look.size
    p.Color = look.color
    p.Material = Enum.Material.Neon
    p.Transparency = look.transparency
    p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
    p.Parent = folder
    return p
end

blink.SummonSpawn.On(function(batch)
    for _, s in batch do
        if active[s.id] then continue end
        local o = s.origin :: Vector3
        local v = s.velocity :: Vector3
        active[s.id] = {
            part = makePart(s.kind), ox = o.X, oy = o.Y, oz = o.Z,
            vx = v.X, vy = v.Y, vz = v.Z, t0 = s.t0, life = s.life,
        }
    end
end)

local function destroy(id: number)
    local s = active[id]
    if s then s.part:Destroy(); active[id] = nil end
end

blink.SummonRemove.On(function(ids)
    for _, id in ids do destroy(id) end
end)

local function step(_dt: number)
    local now = workspace:GetServerTimeNow()
    for id, s in active do
        local age = now - s.t0
        if age >= s.life then
            destroy(id) -- removing the current key mid-iteration is fine
        else
            local x, y, z = s.ox + s.vx * age, s.oy + s.vy * age, s.oz + s.vz * age
            local p = s.part
            -- moving summons (wolves) face their travel; turrets just spin slowly so they read "alive"
            if s.vx ~= 0 or s.vz ~= 0 then
                p.CFrame = CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(x + s.vx, y, z + s.vz))
            else
                p.CFrame = CFrame.new(x, y, z) * CFrame.Angles(0, now * 1.2, 0)
            end
        end
    end
end

scheduler.SYSTEM(step, phases.Heartbeat)
return 0
