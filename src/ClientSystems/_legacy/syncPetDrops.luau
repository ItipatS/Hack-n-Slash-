-- ClientSystems/syncPetDrops.luau
-- Renders boss-dropped PET pickups (PetDropSpawn / PetDropRemove). Each is the pet's animal
-- model floating up & down, slowly spinning, wrapped in a glowing aura + rainbow "voxel"
-- particles (texture 14657415531). Pure presentation — the server owns the pickup; walking over
-- it (server proximity) fires PetDropRemove, which we despawn with a little pop.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))

local Registry = require(std:WaitForChild("petRegistry"))
local Animals = ReplicatedStorage:WaitForChild("Animals")

local PARTICLE_TEX = "rbxassetid://14657415531"
local RAINBOW = ColorSequence.new({
    ColorSequenceKeypoint.new(0.0, Color3.fromRGB(255, 70, 70)),
    ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 200, 60)),
    ColorSequenceKeypoint.new(0.4, Color3.fromRGB(90, 255, 120)),
    ColorSequenceKeypoint.new(0.6, Color3.fromRGB(70, 200, 255)),
    ColorSequenceKeypoint.new(0.8, Color3.fromRGB(170, 110, 255)),
    ColorSequenceKeypoint.new(1.0, Color3.fromRGB(255, 90, 220)),
})

local FLOAT_FREQ = 2.0   -- bob cycles/sec
local FLOAT_AMP  = 0.7   -- bob height
local SPIN_SPEED = 1.6   -- rad/sec

local folder = Instance.new("Folder")
folder.Name = "PetDrops"
folder.Parent = workspace

type Drop = { model: Model, x: number, z: number, baseY: number }
local drops: { [number]: Drop } = {}

local function makeAnimal(pet: string): BasePart
    local src = Animals:FindFirstChild(Registry.meshName(pet))
    local p: BasePart
    if src and src:IsA("BasePart") then
        p = src:Clone()
    else
        -- no mesh yet → a CUBE in the pet's registry color, so you can tell WHICH pet dropped
        local def = Registry.pets[pet]
        p = Instance.new("Part")
        p.Size = Vector3.new(3, 3, 3)
        p.Color = (def and def.base.color) or Color3.fromRGB(255, 150, 200)
    end
    p.Name = "Pet"
    p.Anchored = true
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.CastShadow = false
    return p
end

local function build(pet: string): Model
    local model = Instance.new("Model")
    model.Name = "PetDrop"

    local animal = makeAnimal(pet)
    animal.Parent = model
    model.PrimaryPart = animal

    -- glowing aura sphere around the pet
    local aura = Instance.new("Part")
    aura.Name = "Aura"
    aura.Shape = Enum.PartType.Ball
    aura.Size = animal.Size * 1.8 + Vector3.new(2, 2, 2)
    aura.Material = Enum.Material.Neon
    aura.Color = Color3.fromRGB(180, 220, 255)
    aura.Transparency = 0.75
    aura.Anchored = true
    aura.CanCollide = false
    aura.CanQuery = false
    aura.CanTouch = false
    aura.CastShadow = false
    aura.CFrame = animal.CFrame
    -- weld so PivotTo moves the aura with the pet (PrimaryPart drives the pivot)
    local weld = Instance.new("WeldConstraint")
    weld.Part0 = animal
    weld.Part1 = aura
    aura.Parent = model

    -- rainbow voxel particles
    local pe = Instance.new("ParticleEmitter")
    pe.Texture = PARTICLE_TEX
    pe.Color = RAINBOW
    pe.LightEmission = 0.6
    pe.Lifetime = NumberRange.new(0.7, 1.1)
    pe.Rate = 26
    pe.Speed = NumberRange.new(2, 4)
    pe.SpreadAngle = Vector2.new(180, 180)
    pe.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.9),
        NumberSequenceKeypoint.new(1, 0.1),
    })
    pe.Rotation = NumberRange.new(0, 360)
    pe.RotSpeed = NumberRange.new(-140, 140)
    pe.Acceleration = Vector3.new(0, 2, 0)
    pe.Parent = animal

    -- aura light
    local light = Instance.new("PointLight")
    light.Range = 14
    light.Brightness = 2.2
    light.Color = Color3.fromRGB(180, 220, 255)
    light.Parent = animal

    -- name label
    local bb = Instance.new("BillboardGui")
    bb.Size = UDim2.new(0, 120, 0, 28)
    bb.StudsOffset = Vector3.new(0, 3.5, 0)
    bb.AlwaysOnTop = true
    bb.Parent = animal
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.Font = Enum.Font.GothamBlack
    lbl.TextSize = 18
    lbl.TextColor3 = Color3.fromRGB(255, 245, 180)
    lbl.TextStrokeTransparency = 0.4
    lbl.Text = (Registry.pets[pet] and Registry.pets[pet].name) or pet
    lbl.Parent = bb

    model.Parent = folder
    return model
end

blink.PetDropSpawn.On(function(batch)
    for _, d in batch do
        if drops[d.id] then continue end
        local pos = d.pos :: Vector3
        local model = build(d.pet)
        drops[d.id] = { model = model, x = pos.X, z = pos.Z, baseY = pos.Y }
    end
end)

blink.PetDropRemove.On(function(ids)
    for _, id in ids do
        local d = drops[id]
        if d then
            d.model:Destroy() -- (server already credited the pet; this is just the visual)
            drops[id] = nil
        end
    end
end)

local function step(_dt: number)
    local now = os.clock()
    local bob = math.sin(now * FLOAT_FREQ) * FLOAT_AMP
    local ang = now * SPIN_SPEED
    for _id, d in drops do
        d.model:PivotTo(CFrame.new(d.x, d.baseY + bob, d.z) * CFrame.Angles(0, ang, 0))
    end
end

scheduler.SYSTEM(step, phases.Heartbeat)
return 0
