-- ClientSystems/itemtab.luau
-- ITEM TAB — a MENU-ONLY codex of the passive items (Milk, Soda, ...). Open with I or the on-screen
-- "ITEMS" button. Lists every item; select one to see its per-level effects and your current run
-- level (items are gained IN-RUN from level-up / boss card packs; your live levels also show on the
-- in-run HUD via playerhud). Read-only — there's nothing to equip; this is reference.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")

local std        = ReplicatedStorage.std
local clientState = require(std:WaitForChild("clientState"))
local ItemReg    = require(std:WaitForChild("itemRegistry"))
local clientPlay = require(std:WaitForChild("clientPlay"))
local Panels     = require(std:WaitForChild("panels"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "ItemTab"
gui.ResetOnSpawn = false
gui.DisplayOrder = 30 -- above the main menu (20); mutually exclusive with the Pets tab via std/panels
gui.Parent = playerGui

-- menu row (right of centre): PETS | ITEMS — sits below the PLAY button, no overlap
local openBtn = Instance.new("TextButton")
openBtn.AnchorPoint = Vector2.new(0, 0.5)
openBtn.Position = UDim2.new(0.5, 8, 0.525, 0)
openBtn.Size = UDim2.new(0, 168, 0, 46)
openBtn.BackgroundColor3 = Color3.fromRGB(80, 150, 90)
openBtn.BorderSizePixel = 0
openBtn.Font = Enum.Font.GothamBold
openBtn.TextSize = 18
openBtn.TextColor3 = Color3.new(1, 1, 1)
openBtn.Text = "📦 ITEMS  [I]"
openBtn.Parent = gui
Instance.new("UICorner").Parent = openBtn

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.5, 0)
frame.Size = UDim2.new(0, 720, 0, 520)
frame.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
frame.BorderSizePixel = 0
frame.Visible = false
frame.Parent = gui
Instance.new("UICorner").Parent = frame
local fStroke = Instance.new("UIStroke")
fStroke.Color = Color3.fromRGB(70, 80, 110)
fStroke.Thickness = 2
fStroke.Parent = frame

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 22, 0, 14)
title.Size = UDim2.new(1, -70, 0, 34)
title.Font = Enum.Font.GothamBold
title.TextSize = 22
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.new(1, 1, 1)
title.Text = "ITEMS   ·   passive buffs you find during a run"
title.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.AnchorPoint = Vector2.new(1, 0)
closeBtn.Position = UDim2.new(1, -16, 0, 14)
closeBtn.Size = UDim2.new(0, 36, 0, 36)
closeBtn.BackgroundColor3 = Color3.fromRGB(70, 50, 56)
closeBtn.BorderSizePixel = 0
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 20
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Text = "✕"
closeBtn.Parent = frame
Instance.new("UICorner").Parent = closeBtn

-- left: item list
local list = Instance.new("Frame")
list.Position = UDim2.new(0, 18, 0, 62)
list.Size = UDim2.new(0, 250, 1, -78)
list.BackgroundTransparency = 1
list.Parent = frame
local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 8)
layout.Parent = list

-- right: detail
local detail = Instance.new("Frame")
detail.Position = UDim2.new(0, 282, 0, 62)
detail.Size = UDim2.new(1, -300, 1, -78)
detail.BackgroundColor3 = Color3.fromRGB(18, 20, 27)
detail.BorderSizePixel = 0
detail.Parent = frame
Instance.new("UICorner").Parent = detail

local badge = Instance.new("TextLabel")
badge.Position = UDim2.new(0, 16, 0, 16)
badge.Size = UDim2.new(0, 84, 0, 84)
badge.BackgroundColor3 = Color3.fromRGB(40, 44, 60)
badge.BorderSizePixel = 0
badge.Font = Enum.Font.GothamBold
badge.TextSize = 46
badge.Text = ""
badge.Parent = detail
Instance.new("UICorner").Parent = badge

local dName = Instance.new("TextLabel")
dName.BackgroundTransparency = 1
dName.Position = UDim2.new(0, 112, 0, 18)
dName.Size = UDim2.new(1, -128, 0, 30)
dName.Font = Enum.Font.GothamBold
dName.TextSize = 26
dName.TextXAlignment = Enum.TextXAlignment.Left
dName.TextColor3 = Color3.fromRGB(200, 235, 255)
dName.Text = ""
dName.Parent = detail

local dLevel = Instance.new("TextLabel")
dLevel.BackgroundTransparency = 1
dLevel.Position = UDim2.new(0, 112, 0, 50)
dLevel.Size = UDim2.new(1, -128, 0, 22)
dLevel.Font = Enum.Font.GothamMedium
dLevel.TextSize = 16
dLevel.TextXAlignment = Enum.TextXAlignment.Left
dLevel.TextColor3 = Color3.fromRGB(255, 220, 140)
dLevel.Text = ""
dLevel.Parent = detail

local dBlurb = Instance.new("TextLabel")
dBlurb.BackgroundTransparency = 1
dBlurb.Position = UDim2.new(0, 16, 0, 110)
dBlurb.Size = UDim2.new(1, -32, 0, 22)
dBlurb.Font = Enum.Font.GothamMedium
dBlurb.TextSize = 16
dBlurb.TextXAlignment = Enum.TextXAlignment.Left
dBlurb.TextColor3 = Color3.fromRGB(170, 180, 200)
dBlurb.Text = ""
dBlurb.Parent = detail

-- per-level effects list
local levels = Instance.new("ScrollingFrame")
levels.Position = UDim2.new(0, 16, 0, 140)
levels.Size = UDim2.new(1, -32, 1, -156)
levels.BackgroundTransparency = 1
levels.BorderSizePixel = 0
levels.ScrollBarThickness = 6
levels.CanvasSize = UDim2.new()
levels.AutomaticCanvasSize = Enum.AutomaticSize.Y
levels.Parent = detail
local lLayout = Instance.new("UIListLayout")
lLayout.SortOrder = Enum.SortOrder.LayoutOrder
lLayout.Padding = UDim.new(0, 4)
lLayout.Parent = levels

-- state
local ownedLevels: { [string]: number } = {}
local rows: { [string]: TextButton } = {}
local selected: string? = nil
local levelLabels: { TextLabel } = {}

local function select(id: string)
    selected = id
    local it = ItemReg.items[id]
    if not it then return end
    badge.Text = it.icon
    badge.BackgroundColor3 = it.color
    dName.Text = it.name
    dBlurb.Text = it.blurb or ""
    local cur = ownedLevels[id] or 0
    dLevel.Text = string.format("Your level: %d / %d", cur, it.maxLevel)
    -- effect per level
    for _, l in levelLabels do l:Destroy() end
    table.clear(levelLabels)
    for lvl = 1, it.maxLevel do
        local l = Instance.new("TextLabel")
        l.BackgroundTransparency = 1
        l.Size = UDim2.new(1, -6, 0, 22)
        l.AutomaticSize = Enum.AutomaticSize.Y
        l.Font = if lvl == cur then Enum.Font.GothamBold else Enum.Font.Gotham
        l.TextSize = 15
        l.TextWrapped = true
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.TextColor3 = if lvl == cur then Color3.fromRGB(255, 235, 150)
            elseif lvl <= cur then Color3.fromRGB(150, 220, 160) else Color3.fromRGB(210, 210, 225)
        l.LayoutOrder = lvl
        l.Text = string.format("%s Lv%d — %s", if lvl <= cur then "✓" else "•", lvl, ItemReg.desc(id, lvl))
        l.Parent = levels
        levelLabels[#levelLabels + 1] = l
    end
    for id2, btn in rows do
        btn.BackgroundColor3 = if id2 == id then Color3.fromRGB(70, 80, 110) else Color3.fromRGB(45, 48, 60)
    end
end

local function refreshRowText()
    for id, btn in rows do
        local it = ItemReg.items[id]
        local lvl = ownedLevels[id] or 0
        btn.Text = string.format("%s %s%s", it.icon, it.name, if lvl > 0 then "  Lv " .. lvl else "")
    end
end

local function build()
    for _, btn in rows do btn:Destroy() end
    table.clear(rows)
    for i, id in ItemReg.order do
        local it = ItemReg.items[id]
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 48)
        btn.BackgroundColor3 = Color3.fromRGB(45, 48, 60)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamMedium
        btn.TextSize = 18
        btn.TextXAlignment = Enum.TextXAlignment.Left
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.LayoutOrder = i
        btn.Text = ""
        btn.Parent = list
        Instance.new("UICorner").Parent = btn
        local pad = Instance.new("UIPadding")
        pad.PaddingLeft = UDim.new(0, 12)
        pad.Parent = btn
        btn.Activated:Connect(function() select(id) end)
        rows[id] = btn
    end
    refreshRowText()
    if not (selected and rows[selected]) then selected = ItemReg.order[1] end
    if selected then select(selected) end
end

clientState.onItems(function(listMsg)
    table.clear(ownedLevels)
    for _, e in listMsg do ownedLevels[e.id] = e.level end
    refreshRowText()
    if selected then select(selected) end
end)

build()

-- ── Open/close (menu-only; mutually exclusive with the Pets tab via std/panels) ───────
local function setOpen(open: boolean)
    frame.Visible = open
    Panels.set("items", open)
end
local function updateOpenBtn()
    local cur = Panels.get()
    openBtn.Visible = (clientPlay.get() == "menu") and (cur == nil or cur == "items")
end
openBtn.Activated:Connect(function() setOpen(not frame.Visible) end)
closeBtn.Activated:Connect(function() setOpen(false) end)

Panels.onChanged(function(cur)
    if cur ~= "items" and frame.Visible then frame.Visible = false end -- another tab opened → close ours
    updateOpenBtn()
end)
clientPlay.onChanged(function(s)
    if s ~= "menu" and frame.Visible then setOpen(false) end
    updateOpenBtn()
end)

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe or clientPlay.get() ~= "menu" then return end
    if input.KeyCode == Enum.KeyCode.I then setOpen(not frame.Visible) end
end)

return 0
