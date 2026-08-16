-- ClientSystems/syncHealth.luau
-- Renders Heart health pickups (HealthSpawn / HealthRemove). Clones ReplicatedStorage.Assets.
-- Heart if present (drop model 36974106 there, named "Heart"); otherwise a red glowing fallback.
-- Each floats + spins, wrapped in particles + a glow (shared dropFx, same as pets/tix). Walking
-- over it (server proximity) fires HealthRemove → despawn. Pure presentation; server owns the heal.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))
local dropFx    = require(std:WaitForChild("dropFx"))

local player = Players.LocalPlayer
local function hrp(): BasePart?
    local c = player.Character
    return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local FLOAT_FREQ = 2.2
local FLOAT_AMP  = 0.5
local SPIN_SPEED = 2.0

local HEART_COLOR = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 120, 140)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 40, 70)),
})
local HEART_LIGHT = Color3.fromRGB(255, 90, 110)

local folder = Instance.new("Folder")
folder.Name = "Hearts"
folder.Parent = workspace

local heartSrc: Instance? = nil
do
    local assets = ReplicatedStorage:FindFirstChild("Assets")
    local h = assets and assets:FindFirstChild("Heart")
    if h and (h:IsA("Model") or h:IsA("BasePart")) then heartSrc = h end
end

local function buildFallback(): Model
    local m = Instance.new("Model")
    local p = Instance.new("Part")
    p.Name = "Heart"
    p.Shape = Enum.PartType.Ball
    p.Size = Vector3.new(2.2, 2.2, 2.2)
    p.Material = Enum.Material.Neon
    p.Color = Color3.fromRGB(255, 70, 90)
    p.Parent = m
    m.PrimaryPart = p
    return m
end

local function makeHeart(): Instance
    local inst: Instance
    if heartSrc then
        inst = heartSrc:Clone()
        if inst:IsA("Model") and not inst.PrimaryPart then
            inst.PrimaryPart = inst:FindFirstChildWhichIsA("BasePart")
        end
    else
        inst = buildFallback()
    end
    dropFx.staticize(inst)
    dropFx.decorate(inst, HEART_COLOR, HEART_LIGHT)
    return inst
end

local function pivot(inst: Instance, cf: CFrame)
    if inst:IsA("Model") then inst:PivotTo(cf)
    elseif inst:IsA("BasePart") then inst.CFrame = cf end
end

type Heart = { inst: Instance, x: number, z: number, baseY: number }
local hearts: { [number]: Heart } = {}

blink.HealthSpawn.On(function(batch)
    for _, d in batch do
        if hearts[d.id] then continue end
        local pos = d.pos :: Vector3
        local inst = makeHeart()
        inst.Parent = folder
        pivot(inst, CFrame.new(pos))
        hearts[d.id] = { inst = inst, x = pos.X, z = pos.Z, baseY = pos.Y }
    end
end)

blink.HealthRemove.On(function(ids)
    local target = hrp()
    for _, id in ids do
        local h = hearts[id]
        if h then
            hearts[id] = nil
            dropFx.collect(h.inst, target) -- fly to the player, then despawn
        end
    end
end)

local function step(_dt: number)
    local now = os.clock()
    local bob = math.sin(now * FLOAT_FREQ) * FLOAT_AMP
    local ang = now * SPIN_SPEED
    for _id, h in hearts do
        pivot(h.inst, CFrame.new(h.x, h.baseY + bob, h.z) * CFrame.Angles(0, ang, 0))
    end
end

scheduler.SYSTEM(step, phases.Heartbeat)
return 0
