-- ClientSystems/syncCardDrops.luau
-- Renders boss/elite-dropped CARD PACK pickups (CardDropSpawn / CardDropRemove). Each is the
-- Assets.Card model floating up & down, slowly spinning, wrapped in a glowing aura + sparkle
-- particles. Pure presentation — the server owns the pickup; walking over it (server proximity)
-- fires CardDropRemove (and opens the upgrade choice via LevelUp on the picker's screen).
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))

local Assets   = ReplicatedStorage:WaitForChild("Assets", 2)
if not Assets then warn("[syncCardDrops] no ReplicatedStorage.Assets in this place — rendering disabled"); return 0 end
local cardSrc  = Assets:FindFirstChild("Card")

local PARTICLE_TEX = "rbxassetid://14657415531"
local RAINBOW = ColorSequence.new({
    ColorSequenceKeypoint.new(0.0, Color3.fromRGB(255, 215, 120)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(150, 255, 175)),
    ColorSequenceKeypoint.new(1.0, Color3.fromRGB(120, 200, 255)),
})

local FLOAT_FREQ = 1.7   -- bob cycles/sec
local FLOAT_AMP  = 0.7   -- bob height
local SPIN_SPEED = 1.4   -- rad/sec

local folder = Instance.new("Folder")
folder.Name = "CardDrops"
folder.Parent = workspace

type Drop = { model: PVInstance, x: number, z: number, baseY: number }
local drops: { [number]: Drop } = {}

-- the visual is one PVInstance (Model or BasePart) we PivotTo each frame. Returns it + a BasePart
-- to hang particles/light on.
local function build(): (PVInstance, BasePart)
    local model: PVInstance
    local anchor: BasePart
    if cardSrc and (cardSrc:IsA("Model") or cardSrc:IsA("BasePart")) then
        model = cardSrc:Clone() :: PVInstance
        -- strip logic, make every part inert + anchored so PivotTo isn't fought by physics
        for _, d in (model :: Instance):GetDescendants() do
            if d:IsA("BasePart") then
                d.Anchored = true; d.CanCollide = false; d.CanQuery = false
                d.CanTouch = false; d.CastShadow = false
            elseif d:IsA("Humanoid") or d:IsA("BaseScript") or d:IsA("ModuleScript") then
                d:Destroy()
            end
        end
        if model:IsA("BasePart") then
            (model :: BasePart).Anchored = true
            anchor = model :: BasePart
        else
            local m = model :: Model
            anchor = (m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)) :: BasePart
            if anchor and not m.PrimaryPart then m.PrimaryPart = anchor end
        end
    end
    if not model or not anchor then
        -- fallback: a glowing card-ish slab so a drop is never invisible
        local p = Instance.new("Part")
        p.Size = Vector3.new(2.4, 3.4, 0.25)
        p.Color = Color3.fromRGB(255, 220, 130)
        p.Material = Enum.Material.Neon
        p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
        model = p; anchor = p
    end

    -- sparkle particles + a glow light on the anchor part
    local pe = Instance.new("ParticleEmitter")
    pe.Texture = PARTICLE_TEX
    pe.Color = RAINBOW
    pe.LightEmission = 0.7
    pe.Lifetime = NumberRange.new(0.6, 1.0)
    pe.Rate = 22
    pe.Speed = NumberRange.new(1.5, 3)
    pe.SpreadAngle = Vector2.new(180, 180)
    pe.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.8),
        NumberSequenceKeypoint.new(1, 0.05),
    })
    pe.Rotation = NumberRange.new(0, 360)
    pe.RotSpeed = NumberRange.new(-120, 120)
    pe.Acceleration = Vector3.new(0, 2, 0)
    pe.Parent = anchor

    local light = Instance.new("PointLight")
    light.Range = 13
    light.Brightness = 2.0
    light.Color = Color3.fromRGB(255, 225, 150)
    light.Parent = anchor

    local bb = Instance.new("BillboardGui")
    bb.Size = UDim2.new(0, 130, 0, 28)
    bb.StudsOffset = Vector3.new(0, 3.5, 0)
    bb.AlwaysOnTop = true
    bb.Parent = anchor
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.Font = Enum.Font.GothamBlack
    lbl.TextSize = 18
    lbl.TextColor3 = Color3.fromRGB(255, 235, 150)
    lbl.TextStrokeTransparency = 0.4
    lbl.Text = "Card Pack"
    lbl.Parent = bb

    ;(model :: Instance).Parent = folder
    return model, anchor
end

blink.CardDropSpawn.On(function(batch)
    for _, d in batch do
        if drops[d.id] then continue end
        local pos = d.pos :: Vector3
        local model = build()
        drops[d.id] = { model = model, x = pos.X, z = pos.Z, baseY = pos.Y }
    end
end)

blink.CardDropRemove.On(function(ids)
    for _, id in ids do
        local d = drops[id]
        if d then
            (d.model :: Instance):Destroy() -- (server already opened the offer; this is just the visual)
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
