-- ClientSystems/levelUpCards.luau
-- The level-up pick-1-of-3 screen — the marquee UI moment. On open: blur the screen, freeze the player, tell
-- the server we're "picking" (so mobs stop hitting us), and deal three cards that SLOT-MACHINE spin through
-- random upgrades, decelerate, and lock onto a rarity-rolled upgrade (staggered). Click a locked card →
-- applies it via the onComplete callback, then everything unwinds. Re-entrant level-ups queue.
--!strict

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting          = game:GetService("Lighting")
local TweenService      = game:GetService("TweenService")

local Upgrades = require(ReplicatedStorage.std.upgrades)
local remote   = ReplicatedStorage:WaitForChild("CombatRemote") :: RemoteEvent

local LP  = Players.LocalPlayer
local gui = LP:WaitForChild("PlayerGui")

local M = {}

local function hex(h: string): Color3 return Color3.fromHex(h) end

-- ── persistent UI ────────────────────────────────────────────────────────────────
local blur = Instance.new("BlurEffect")
blur.Size = 0
blur.Enabled = false
blur.Parent = Lighting

local screen = Instance.new("ScreenGui")
screen.Name = "LevelUp"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 80
screen.Enabled = false
screen.Parent = gui

local dim = Instance.new("TextButton") -- full-screen catcher (sinks clicks) + darkener
dim.Size = UDim2.fromScale(1, 1)
dim.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
dim.BackgroundTransparency = 1
dim.Text = ""
dim.AutoButtonColor = false
dim.Modal = true
dim.Parent = screen

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 40)
title.Position = UDim2.new(0, 0, 0.5, -170)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack
title.Text = "LEVEL UP"
title.TextSize = 34
title.TextColor3 = Color3.fromRGB(245, 245, 250)
title.TextStrokeTransparency = 0.6
title.Parent = dim

local row = Instance.new("Frame")
row.Size = UDim2.fromOffset(3 * 176 + 2 * 18, 260)
row.AnchorPoint = Vector2.new(0.5, 0.5)
row.Position = UDim2.fromScale(0.5, 0.5)
row.BackgroundTransparency = 1
row.Parent = dim
local rowList = Instance.new("UIListLayout", row)
rowList.FillDirection = Enum.FillDirection.Horizontal
rowList.Padding = UDim.new(0, 18)
rowList.HorizontalAlignment = Enum.HorizontalAlignment.Center
rowList.VerticalAlignment = Enum.VerticalAlignment.Center

type Card = {
	btn: TextButton, scale: UIScale, stroke: UIStroke,
	nameL: TextLabel, descL: TextLabel, rarL: TextLabel,
	final: Upgrades.Upgrade?, finalR: number, locked: boolean,
}

local function buildCard(order: number): Card
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromOffset(176, 240)
	btn.BackgroundColor3 = Color3.fromRGB(24, 25, 32)
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.LayoutOrder = order
	btn.Parent = row
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 12)
	local scale = Instance.new("UIScale", btn)
	local stroke = Instance.new("UIStroke", btn)
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(120, 120, 130)
	local pad = Instance.new("UIPadding", btn)
	pad.PaddingTop = UDim.new(0, 16); pad.PaddingBottom = UDim.new(0, 16)
	pad.PaddingLeft = UDim.new(0, 14); pad.PaddingRight = UDim.new(0, 14)
	-- text-only card, top-down: RARITY → NAME → DESCRIPTION (no blank icon slot)
	local layout = Instance.new("UIListLayout", btn)
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder

	local rarL = Instance.new("TextLabel")
	rarL.Size = UDim2.new(1, 0, 0, 18)
	rarL.LayoutOrder = 1
	rarL.BackgroundTransparency = 1
	rarL.Font = Enum.Font.GothamBold
	rarL.TextSize = 13
	rarL.TextXAlignment = Enum.TextXAlignment.Left
	rarL.Text = "—"
	rarL.Parent = btn

	local nameL = Instance.new("TextLabel")
	nameL.Size = UDim2.new(1, 0, 0, 54)
	nameL.LayoutOrder = 2
	nameL.BackgroundTransparency = 1
	nameL.Font = Enum.Font.GothamBlack
	nameL.TextSize = 22
	nameL.TextWrapped = true
	nameL.TextColor3 = Color3.fromRGB(245, 245, 250)
	nameL.TextXAlignment = Enum.TextXAlignment.Left
	nameL.TextYAlignment = Enum.TextYAlignment.Top
	nameL.Text = ""
	nameL.Parent = btn

	local descL = Instance.new("TextLabel")
	descL.Size = UDim2.new(1, 0, 0, 112)
	descL.LayoutOrder = 3
	descL.BackgroundTransparency = 1
	descL.Font = Enum.Font.Gotham
	descL.TextSize = 15
	descL.TextWrapped = true
	descL.TextColor3 = Color3.fromRGB(186, 191, 201)
	descL.TextXAlignment = Enum.TextXAlignment.Left
	descL.TextYAlignment = Enum.TextYAlignment.Top
	descL.Text = ""
	descL.Parent = btn

	return { btn = btn, scale = scale, stroke = stroke, nameL = nameL, descL = descL, rarL = rarL, final = nil, finalR = 1, locked = false }
end

local cards: { Card } = { buildCard(1), buildCard(2), buildCard(3) }

local function paint(c: Card, u: Upgrades.Upgrade, rarity: number)
	local r = Upgrades.RARITY[rarity]
	local col = hex(r.color)
	c.rarL.Text = string.upper(r.name)
	c.rarL.TextColor3 = col
	c.stroke.Color = col
	c.nameL.Text = u.name
	c.descL.Text = u.desc
end

-- ── open / spin / pick ───────────────────────────────────────────────────────────
local isOpen = false
local queued = 0
local onPick: ((Upgrades.Upgrade) -> ())? = nil

local function closeScreen()
	isOpen = false
	remote:FireServer("picking", false)
	local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
	if hum then hum.WalkSpeed = 16 end -- restored (baseWalkSpeed handled by playerAnim on next input)
	TweenService:Create(blur, TweenInfo.new(0.2), { Size = 0 }):Play()
	TweenService:Create(dim, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
	task.delay(0.2, function()
		if not isOpen then screen.Enabled = false; blur.Enabled = false end
	end)
	if queued > 0 then queued -= 1; task.defer(M.open, onPick) end
end

local function pick(c: Card)
	if not c.locked or not isOpen then return end
	-- pop the chosen, fade the others
	TweenService:Create(c.scale, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.12 }):Play()
	for _, o in cards do if o ~= c then TweenService:Create(o.btn, TweenInfo.new(0.15), { BackgroundTransparency = 0.7 }):Play() end end
	if c.final and onPick then onPick(c.final) end
	task.delay(0.16, closeScreen)
end

for _, c in cards do c.btn.MouseButton1Click:Connect(function() pick(c) end) end

local function spinCard(c: Card, stopAt: number)
	c.locked = false
	c.final, c.finalR = Upgrades.roll()
	c.btn.BackgroundTransparency = 0
	task.spawn(function()
		local interval, elapsed = 0.04, 0
		while elapsed < stopAt do
			local u, r = Upgrades.roll()
			paint(c, u, r)
			task.wait(interval)
			elapsed += interval
			interval = math.min(interval * 1.13, 0.16) -- decelerate toward a settle
		end
		paint(c, c.final :: Upgrades.Upgrade, c.finalR)
		c.locked = true
		-- lock juice: pop + a stroke flash
		c.scale.Scale = 1.14
		TweenService:Create(c.scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		local t0 = c.stroke.Thickness
		c.stroke.Thickness = 6
		TweenService:Create(c.stroke, TweenInfo.new(0.25), { Thickness = 3 }):Play()
	end)
end

function M.open(cb: ((Upgrades.Upgrade) -> ())?)
	if isOpen then queued += 1; return end
	isOpen = true
	onPick = cb
	remote:FireServer("picking", true)
	local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
	if hum then hum.WalkSpeed = 0 end

	screen.Enabled = true
	blur.Enabled = true
	TweenService:Create(blur, TweenInfo.new(0.25), { Size = 20 }):Play()
	TweenService:Create(dim, TweenInfo.new(0.25), { BackgroundTransparency = 0.4 }):Play()

	-- ENTRANCE transition: title fades in, the card row slides up, each card pops in (staggered), THEN spins.
	title.TextTransparency = 1
	TweenService:Create(title, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
	row.Position = UDim2.new(0.5, 0, 0.5, 36)
	TweenService:Create(row, TweenInfo.new(0.32, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0.5, 0.5) }):Play()

	for i, c in cards do
		c.btn.BackgroundTransparency = 0
		c.stroke.Thickness = 3
		c.scale.Scale = 0
		local tw = TweenService:Create(c.scale, TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		task.delay((i - 1) * 0.06, function() if isOpen then tw:Play() end end) -- staggered pop-in
		spinCard(c, 0.75 + (i - 1) * 0.32) -- staggered stop → they land one after another
	end
end

return M
