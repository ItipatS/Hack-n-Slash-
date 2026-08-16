-- ClientSystems/devPanel.luau
-- Studio-only dev panel: a count box + Spawn / Clear buttons that ask the server (systems/mobs, over
-- CombatRemote) to spawn a pack of mobs around you or wipe the field. Never shows in a live game.
--!strict

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not RunService:IsStudio() then
	return 0
end

local remote = ReplicatedStorage:WaitForChild("CombatRemote") :: RemoteEvent
local LP = Players.LocalPlayer
local gui = LP:WaitForChild("PlayerGui")

local screen = Instance.new("ScreenGui")
screen.Name = "DevPanel"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.Parent = gui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(170, 196)
frame.Position = UDim2.new(0, 12, 0.5, -59)
frame.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
frame.BackgroundTransparency = 0.1
frame.BorderSizePixel = 0
frame.Parent = screen
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local pad = Instance.new("UIPadding", frame)
pad.PaddingTop = UDim.new(0, 8); pad.PaddingBottom = UDim.new(0, 8)
pad.PaddingLeft = UDim.new(0, 8); pad.PaddingRight = UDim.new(0, 8)
local list = Instance.new("UIListLayout", frame)
list.Padding = UDim.new(0, 6)
list.SortOrder = Enum.SortOrder.LayoutOrder

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 18)
title.BackgroundTransparency = 1
title.Text = "MOB SPAWNER"
title.TextColor3 = Color3.fromRGB(200, 200, 210)
title.Font = Enum.Font.GothamBold
title.TextSize = 12
title.TextXAlignment = Enum.TextXAlignment.Left
title.LayoutOrder = 1
title.Parent = frame

local box = Instance.new("TextBox")
box.Size = UDim2.new(1, 0, 0, 28)
box.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
box.BorderSizePixel = 0
box.Text = "20"
box.PlaceholderText = "count"
box.TextColor3 = Color3.fromRGB(240, 240, 245)
box.Font = Enum.Font.Gotham
box.TextSize = 14
box.ClearTextOnFocus = false
box.LayoutOrder = 2
box.Parent = frame
Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)

local function makeButton(text: string, color: Color3, order: number): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 26)
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.Text = text
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.AutoButtonColor = true
	b.LayoutOrder = order
	b.Parent = frame
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	return b
end

makeButton("Spawn", Color3.fromRGB(60, 130, 90), 3).Activated:Connect(function()
	remote:FireServer("spawnmobs", tonumber(box.Text) or 20)
end)
makeButton("Clear", Color3.fromRGB(150, 60, 60), 4).Activated:Connect(function()
	remote:FireServer("clearmobs")
end)

-- one-click stress presets (server clamps to 2000) — for demoing the crowd at scale fast
local presetRow = Instance.new("Frame")
presetRow.Size = UDim2.new(1, 0, 0, 24)
presetRow.BackgroundTransparency = 1
presetRow.LayoutOrder = 5
presetRow.Parent = frame
local prList = Instance.new("UIListLayout", presetRow)
prList.FillDirection = Enum.FillDirection.Horizontal
prList.Padding = UDim.new(0, 4)
prList.SortOrder = Enum.SortOrder.LayoutOrder

local function preset(n: number, order: number)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, 34, 1, 0)
	b.BackgroundColor3 = Color3.fromRGB(50, 70, 100)
	b.BorderSizePixel = 0
	b.Text = if n >= 1000 then (n // 1000) .. "k" else tostring(n)
	b.TextColor3 = Color3.fromRGB(235, 240, 250)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 12
	b.AutoButtonColor = true
	b.LayoutOrder = order
	b.Parent = presetRow
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
	b.Activated:Connect(function()
		box.Text = tostring(n)
		remote:FireServer("spawnmobs", n)
	end)
end
preset(100, 1); preset(500, 2); preset(1000, 3); preset(2000, 4)

-- Waves: toggle the server survival loop (escalating waves + the wave HUD). The server is authoritative;
-- this button just flips it and mirrors the label optimistically.
local wavesOn = false
local wavesBtn = makeButton("\u{25B6} Start Waves", Color3.fromRGB(70, 110, 155), 6)
wavesBtn.Activated:Connect(function()
	wavesOn = not wavesOn
	wavesBtn.Text = if wavesOn then "\u{25A0} Stop Waves" else "\u{25B6} Start Waves"
	remote:FireServer("waves")
end)

return 0
