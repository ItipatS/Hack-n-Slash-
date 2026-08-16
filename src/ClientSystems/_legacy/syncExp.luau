-- ClientSystems/syncExp.luau
-- Renders dropped EXP orbs (static; the server resolved their floor Y once). Colour + size
-- come from `tier` (1 green → 2 blue → 3 orange → 4 purple); merging just removes the old
-- ids (RemoveExp) and spawns one bigger orb (SpawnExp), so this stays simple.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

local std    = ReplicatedStorage.std
local blink  = require(std:WaitForChild("ClientNet"))
local dropFx = require(std:WaitForChild("dropFx"))

local player = Players.LocalPlayer
local function hrp(): BasePart?
    local c = player.Character
    return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local folder = Instance.new("Folder")
folder.Name = "ExpOrbs"
folder.Parent = workspace

local TIER = {
    [1] = { color = Color3.fromRGB(150, 255, 120), size = 1.0 },
    [2] = { color = Color3.fromRGB(90, 170, 255),  size = 1.7 },
    [3] = { color = Color3.fromRGB(255, 170, 70),  size = 2.5 },
    [4] = { color = Color3.fromRGB(205, 120, 255), size = 3.4 },
    [5] = { color = Color3.fromRGB(255, 225, 90),  size = 5.0 }, -- boss big gold orb (wave×5)
}

local function makePart(): BasePart
    local p = Instance.new("Part")
    p.Shape = Enum.PartType.Ball
    p.Material = Enum.Material.Neon
    p.Anchored = true
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.CastShadow = false
    return p
end

local orbs: { [number]: BasePart } = {}

blink.SpawnExp.On(function(batch)
    for _, o in batch do
        if orbs[o.id] then continue end
        local style = TIER[o.tier] or TIER[1]
        local p = makePart()
        p.Size = Vector3.new(style.size, style.size, style.size)
        p.Color = style.color
        p.Position = o.pos :: Vector3
        p.Parent = folder
        orbs[o.id] = p
    end
end)

blink.RemoveExp.On(function(ids)
    local target = hrp()
    for _, id in ids do
        local p = orbs[id]
        if p then
            orbs[id] = nil
            dropFx.collect(p, target) -- fly to the player, then despawn
        end
    end
end)

return 0
