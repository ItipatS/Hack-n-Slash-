-- std/dropFx.luau
-- Shared "shiny world pickup" visual: rainbow voxel particles + a glow light on a host part.
-- Used by every drop (pets, hearts, tix) so they all read the same — a spinning model wrapped
-- in particles. Animation (float + spin) stays in each client system (different rates).
--!strict

local RunService = game:GetService("RunService")

local PARTICLE_TEX = "rbxassetid://14657415531" -- voxel sprite

local RAINBOW = ColorSequence.new({
    ColorSequenceKeypoint.new(0.0, Color3.fromRGB(255, 70, 70)),
    ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 200, 60)),
    ColorSequenceKeypoint.new(0.4, Color3.fromRGB(90, 255, 120)),
    ColorSequenceKeypoint.new(0.6, Color3.fromRGB(70, 200, 255)),
    ColorSequenceKeypoint.new(0.8, Color3.fromRGB(170, 110, 255)),
    ColorSequenceKeypoint.new(1.0, Color3.fromRGB(255, 90, 220)),
})

local dropFx = {}
dropFx.RAINBOW = RAINBOW

-- pick a representative BasePart of a Model-or-Part
local function hostPart(inst: Instance): BasePart?
    if inst:IsA("BasePart") then return inst end
    if inst:IsA("Model") then
        return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
    end
    return nil
end

-- Attach particles + a point light. `color` may be a ColorSequence or a single Color3.
function dropFx.decorate(inst: Instance, color: (ColorSequence | Color3)?, lightColor: Color3?)
    local host = hostPart(inst)
    if not host then return end

    local seq: ColorSequence
    if typeof(color) == "ColorSequence" then
        seq = color
    elseif typeof(color) == "Color3" then
        seq = ColorSequence.new(color)
    else
        seq = RAINBOW
    end

    local pe = Instance.new("ParticleEmitter")
    pe.Texture = PARTICLE_TEX
    pe.Color = seq
    pe.LightEmission = 0.6
    pe.Lifetime = NumberRange.new(0.7, 1.1)
    pe.Rate = 22
    pe.Speed = NumberRange.new(2, 4)
    pe.SpreadAngle = Vector2.new(180, 180)
    pe.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.8),
        NumberSequenceKeypoint.new(1, 0.1),
    })
    pe.Rotation = NumberRange.new(0, 360)
    pe.RotSpeed = NumberRange.new(-140, 140)
    pe.Acceleration = Vector3.new(0, 2, 0)
    pe.Parent = host

    local light = Instance.new("PointLight")
    light.Color = lightColor or Color3.fromRGB(255, 255, 255)
    light.Range = 12
    light.Brightness = 2
    light.Parent = host
end

local COLLECT_MAX_DIST = 60 -- beyond this it wasn't a real pickup (e.g. restart wipe) → instant

-- "Vacuum" collect animation: fly the instance to targetPart, accelerating + spinning + shrinking,
-- then Destroy. Caller should first remove it from its own render table so nothing else moves it.
-- Works for a Model (PivotTo/ScaleTo) or a BasePart (CFrame/Size). dur defaults to 0.28s.
function dropFx.collect(inst: Instance, targetPart: BasePart?, dur: number?)
    local d = dur or 0.28
    local isModel = inst:IsA("Model")
    local startPos = if isModel then (inst :: Model):GetPivot().Position else (inst :: BasePart).Position
    -- far away (restart clear, no real pickup) → just remove
    if not targetPart or not targetPart.Parent or (startPos - targetPart.Position).Magnitude > COLLECT_MAX_DIST then
        inst:Destroy()
        return
    end
    local baseSize = if not isModel then (inst :: BasePart).Size else nil
    task.spawn(function()
        local t = 0
        while inst.Parent do
            local dt = RunService.Heartbeat:Wait()
            t += dt
            local a = math.min(1, t / d)
            local ease = a * a -- accelerate toward the player
            local tgt = (targetPart and targetPart.Parent) and targetPart.Position or startPos
            local pos = startPos:Lerp(tgt, ease)
            local cf = CFrame.new(pos) * CFrame.Angles(0, t * 16, 0)
            local s = math.max(0.05, 1 - a)
            if isModel then
                (inst :: Model):PivotTo(cf);
                (inst :: Model):ScaleTo(s)
            else
                local p = inst :: BasePart
                p.CFrame = cf
                if baseSize then p.Size = baseSize * s end
            end
            if a >= 1 then break end
        end
        if inst.Parent then inst:Destroy() end
    end)
end

-- Strip scripts/sounds + make every part a static anchored visual (no collision/query).
function dropFx.staticize(inst: Instance)
    local function fix(p: BasePart)
        p.Anchored = true; p.CanCollide = false; p.CanQuery = false
        p.CanTouch = false; p.CastShadow = false
    end
    if inst:IsA("BasePart") then fix(inst) end
    for _, d in inst:GetDescendants() do
        if d:IsA("BaseScript") or d:IsA("ModuleScript") or d:IsA("Sound") then d:Destroy() end
        if d:IsA("BasePart") then fix(d) end
    end
end

return dropFx
