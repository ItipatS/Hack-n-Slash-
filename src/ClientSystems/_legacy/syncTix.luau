-- ClientSystems/syncTix.luau
-- Renders Tix currency pickups (TixSpawn / TixRemove) — clones ReplicatedStorage.Assets.<kind>
-- (Tix / PileofTix / StackofTix), floating + spinning with gold particles + glow (shared dropFx,
-- same treatment as pets/hearts). Also draws the Tix balance HUD, updated by TixCount. Pure
-- presentation — the server owns the currency.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))
local dropFx    = require(std:WaitForChild("dropFx"))
local clientState = require(std:WaitForChild("clientState"))
local clientPlay = require(std:WaitForChild("clientPlay"))
local Format    = require(std:WaitForChild("FormatUtils"))

local FLOAT_FREQ = 2.0
local FLOAT_AMP  = 0.5
local SPIN_SPEED = 2.4

local GOLD = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 150)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 180, 40)),
})
local GOLD_LIGHT = Color3.fromRGB(255, 210, 90)

local Assets = ReplicatedStorage:WaitForChild("Assets", 2)
if not Assets then warn("[syncTix] no ReplicatedStorage.Assets in this place — rendering disabled"); return 0 end

local folder = Instance.new("Folder")
folder.Name = "TixDrops"
folder.Parent = workspace

-- ── HUD: Tix balance (top-right) ──────────────────────────────────────────────────
local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local gui = Instance.new("ScreenGui")
gui.Name = "Currency"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local label = Instance.new("TextLabel")
label.AnchorPoint = Vector2.new(1, 0)
label.Position = UDim2.new(1, -12, 0, 12)
label.Size = UDim2.new(0, 150, 0, 30)
label.BackgroundColor3 = Color3.fromRGB(30, 26, 16)
label.BackgroundTransparency = 0.3
label.BorderSizePixel = 0
label.Font = Enum.Font.GothamBold
label.TextSize = 17
label.TextColor3 = Color3.fromRGB(255, 215, 100)
label.TextXAlignment = Enum.TextXAlignment.Right
label.Text = "⛁ 0 Tix  "
label.Parent = gui
Instance.new("UICorner").Parent = label

-- in-game balance HUD only during a run (the menu shows Tix in its best-stats line already)
clientPlay.onChanged(function(s) gui.Enabled = s == "playing" end)

clientState.onTix(function(n)
    label.Text = "⛁ " .. Format.format_to_short_value(n) .. " Tix  " -- 12345 → 12.3K
end)

-- ── Drops ─────────────────────────────────────────────────────────────────────────
-- amount → which Assets model to render: ≤5 Tix, ≤20 PileofTix, else StackofTix
local function kindFor(amount: number): string
    if amount <= 5 then return "Tix"
    elseif amount <= 20 then return "PileofTix"
    else return "StackofTix" end
end

local function makeTix(kind: string): Instance
    local src = Assets:FindFirstChild(kind)
    local inst: Instance
    if src and (src:IsA("Model") or src:IsA("BasePart")) then
        inst = src:Clone()
        if inst:IsA("Model") and not inst.PrimaryPart then
            inst.PrimaryPart = inst:FindFirstChildWhichIsA("BasePart")
        end
    else
        local m = Instance.new("Model")
        local p = Instance.new("Part")
        p.Shape = Enum.PartType.Cylinder
        p.Size = Vector3.new(0.4, 2, 2)
        p.Material = Enum.Material.Neon
        p.Color = Color3.fromRGB(255, 200, 60)
        p.Parent = m
        m.PrimaryPart = p
        inst = m
    end
    dropFx.staticize(inst)
    dropFx.decorate(inst, GOLD, GOLD_LIGHT)
    return inst
end

local function pivot(inst: Instance, cf: CFrame)
    if inst:IsA("Model") then inst:PivotTo(cf)
    elseif inst:IsA("BasePart") then inst.CFrame = cf end
end

type Tix = { inst: Instance, x: number, z: number, baseY: number }
local tix: { [number]: Tix } = {}

blink.TixSpawn.On(function(batch)
    for _, d in batch do
        if tix[d.id] then continue end
        local pos = d.pos :: Vector3
        local inst = makeTix(kindFor(d.amount))
        inst.Parent = folder
        pivot(inst, CFrame.new(pos))
        tix[d.id] = { inst = inst, x = pos.X, z = pos.Z, baseY = pos.Y }
    end
end)

blink.TixRemove.On(function(ids)
    local c = player.Character
    local target = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
    for _, id in ids do
        local t = tix[id]
        if t then
            tix[id] = nil
            dropFx.collect(t.inst, target) -- fly to the player, then despawn
        end
    end
end)

local function step(_dt: number)
    local now = os.clock()
    local bob = math.sin(now * FLOAT_FREQ) * FLOAT_AMP
    local ang = now * SPIN_SPEED
    for _id, t in tix do
        pivot(t.inst, CFrame.new(t.x, t.baseY + bob, t.z) * CFrame.Angles(0, ang, 0))
    end
end

scheduler.SYSTEM(step, phases.Heartbeat)
return 0
