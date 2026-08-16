-- ClientSystems/syncCards.luau
-- Progression UI: a small Level + XP-bar HUD (Stats), and the level-up upgrade picker —
-- 3 cards on the right (LevelUp). Clicking one fires ChooseCard(index); the server applies
-- it and (if more level-ups are queued) sends the next set.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

local std       = ReplicatedStorage.std
local blink     = require(std:WaitForChild("ClientNet"))
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local clientPlay = require(std:WaitForChild("clientPlay"))
local clientState = require(std:WaitForChild("clientState"))
local Registry  = require(std:WaitForChild("petRegistry"))
local ItemReg   = require(std:WaitForChild("itemRegistry"))

local Animals = ReplicatedStorage:WaitForChild("Animals")
local MAX_CARDS = 5 -- level-up offers 4; a boss/elite card pack offers 3-5

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "Progression"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- gameplay HUD: only during a live run (hidden at the menu + while spectating)
clientPlay.onChanged(function(s) gui.Enabled = s == "playing" end)

-- ── HUD: Level + XP bar (top center) ─────────────────────────────────────────────
local hud = Instance.new("Frame")
hud.AnchorPoint = Vector2.new(0.5, 0)
hud.Position = UDim2.new(0.5, 0, 0, 8)
hud.Size = UDim2.new(0, 320, 0, 26)
hud.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
hud.BackgroundTransparency = 0.35
hud.BorderSizePixel = 0
hud.Parent = gui
Instance.new("UICorner").Parent = hud

local xpFill = Instance.new("Frame")
xpFill.Size = UDim2.new(0, 0, 1, 0)
xpFill.BackgroundColor3 = Color3.fromRGB(120, 220, 140)
xpFill.BorderSizePixel = 0
xpFill.Parent = hud
Instance.new("UICorner").Parent = xpFill

local lvlLabel = Instance.new("TextLabel")
lvlLabel.BackgroundTransparency = 1
lvlLabel.Size = UDim2.new(1, 0, 1, 0)
lvlLabel.Font = Enum.Font.GothamBold
lvlLabel.TextScaled = false
lvlLabel.TextSize = 16
lvlLabel.TextColor3 = Color3.new(1, 1, 1)
lvlLabel.Text = "Lv 1"
lvlLabel.ZIndex = 2
lvlLabel.Parent = hud

-- HP bar (just under the level/XP bar)
local hpBar = Instance.new("Frame")
hpBar.AnchorPoint = Vector2.new(0.5, 0)
hpBar.Position = UDim2.new(0.5, 0, 0, 38)
hpBar.Size = UDim2.new(0, 320, 0, 20)
hpBar.BackgroundColor3 = Color3.fromRGB(45, 22, 22)
hpBar.BackgroundTransparency = 0.3
hpBar.BorderSizePixel = 0
hpBar.Parent = gui
Instance.new("UICorner").Parent = hpBar

local hpFill = Instance.new("Frame")
hpFill.Size = UDim2.new(1, 0, 1, 0)
hpFill.BackgroundColor3 = Color3.fromRGB(230, 70, 70)
hpFill.BorderSizePixel = 0
hpFill.Parent = hpBar
Instance.new("UICorner").Parent = hpFill

local hpLabel = Instance.new("TextLabel")
hpLabel.BackgroundTransparency = 1
hpLabel.Size = UDim2.new(1, 0, 1, 0)
hpLabel.ZIndex = 2
hpLabel.Font = Enum.Font.GothamBold
hpLabel.TextSize = 14
hpLabel.TextColor3 = Color3.new(1, 1, 1)
hpLabel.Text = "100 / 100"
hpLabel.Parent = hpBar

-- ── Enemy count (top-left) ───────────────────────────────────────────────────────
local enemyLabel = Instance.new("TextLabel")
enemyLabel.AnchorPoint = Vector2.new(0, 0)
enemyLabel.Position = UDim2.new(0, 12, 0, 12) -- top-left corner (left edge reserved for weapon slots)
enemyLabel.Size = UDim2.new(0, 200, 0, 24)
enemyLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
enemyLabel.BackgroundTransparency = 0.35
enemyLabel.BorderSizePixel = 0
enemyLabel.Font = Enum.Font.GothamBold
enemyLabel.TextSize = 16
enemyLabel.TextColor3 = Color3.fromRGB(255, 160, 160)
enemyLabel.TextXAlignment = Enum.TextXAlignment.Left
enemyLabel.Text = "  Mobs: 0"
enemyLabel.Parent = gui
Instance.new("UICorner").Parent = enemyLabel

-- ── Wave banner (center, fades) ──────────────────────────────────────────────────
local waveBanner = Instance.new("TextLabel")
waveBanner.AnchorPoint = Vector2.new(0.5, 0.5)
waveBanner.Position = UDim2.new(0.5, 0, 0.3, 0)
waveBanner.Size = UDim2.new(0, 420, 0, 64)
waveBanner.BackgroundTransparency = 1
waveBanner.Font = Enum.Font.GothamBlack
waveBanner.TextSize = 46
waveBanner.TextColor3 = Color3.fromRGB(255, 230, 150)
waveBanner.TextStrokeTransparency = 1
waveBanner.TextTransparency = 1
waveBanner.Text = ""
waveBanner.Parent = gui

blink.WaveStart.On(function(wave)
    waveBanner.Text = "WAVE " .. wave
    waveBanner.TextTransparency = 0
    waveBanner.TextStrokeTransparency = 0.3
    TweenService:Create(waveBanner, TweenInfo.new(1.6), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
end)

-- ── Toast (center, just below the wave banner) — e.g. "New pet: Bear!" ─────────────
local toast = Instance.new("TextLabel")
toast.AnchorPoint = Vector2.new(0.5, 0.5)
toast.Position = UDim2.new(0.5, 0, 0.42, 0)
toast.Size = UDim2.new(0, 460, 0, 44)
toast.BackgroundTransparency = 1
toast.Font = Enum.Font.GothamBlack
toast.TextSize = 30
toast.TextColor3 = Color3.fromRGB(150, 255, 175)
toast.TextStrokeTransparency = 1
toast.TextTransparency = 1
toast.Text = ""
toast.Parent = gui

blink.Toast.On(function(msg)
    toast.Text = msg
    toast.TextTransparency = 0
    toast.TextStrokeTransparency = 0.3
    TweenService:Create(toast, TweenInfo.new(2.2), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
end)

-- ── Cards: up to 4 on the right, hidden until an offer (level-up or a card pack) ──────
local cardsHolder = Instance.new("Frame")
cardsHolder.AnchorPoint = Vector2.new(1, 0.5)
cardsHolder.Position = UDim2.new(1, -16, 0.5, 0)
cardsHolder.Size = UDim2.new(0, 264, 0, 610)
cardsHolder.BackgroundTransparency = 1
cardsHolder.Visible = false
cardsHolder.Parent = gui

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 8)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.VerticalAlignment = Enum.VerticalAlignment.Center
layout.Parent = cardsHolder

-- source banner above the cards (LEVEL UP vs CARD PACK) — LayoutOrder 0 keeps it on top
local cardHeader = Instance.new("TextLabel")
cardHeader.LayoutOrder = 0
cardHeader.Size = UDim2.new(1, 0, 0, 34)
cardHeader.BackgroundTransparency = 1
cardHeader.Font = Enum.Font.GothamBlack
cardHeader.TextSize = 24
cardHeader.TextStrokeTransparency = 0.5
cardHeader.Text = ""
cardHeader.Parent = cardsHolder

type CardUI = { btn: TextButton, title: TextLabel, desc: TextLabel, tag: TextLabel,
    viewport: ViewportFrame, cam: Camera, badge: TextLabel }
local cards: { CardUI } = {}
local vpModels: { [number]: BasePart } = {} -- per-card spinning thumbnail model (cleared on reuse)

for i = 1, MAX_CARDS do
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 104)
    btn.BackgroundColor3 = Color3.fromRGB(34, 36, 48)
    btn.AutoButtonColor = true
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.LayoutOrder = i
    btn.Parent = cardsHolder
    Instance.new("UICorner").Parent = btn

    -- 3D weapon thumbnail (left), spun by the Heartbeat loop below
    local viewport = Instance.new("ViewportFrame")
    viewport.Name = "Viewport"
    viewport.Position = UDim2.new(0, 8, 0, 8)
    viewport.Size = UDim2.new(0, 90, 0, 96)
    viewport.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
    viewport.BorderSizePixel = 0
    viewport.Ambient = Color3.fromRGB(190, 195, 205)
    viewport.LightColor = Color3.fromRGB(255, 255, 255)
    viewport.LightDirection = Vector3.new(-1, -1.2, -0.6)
    viewport.Parent = btn
    Instance.new("UICorner").Parent = viewport
    local cam = Instance.new("Camera")
    cam.FieldOfView = 45
    viewport.CurrentCamera = cam
    cam.Parent = viewport

    -- badge (items/stats have no 3D model) — a colored emoji tile shown in place of the viewport
    local badge = Instance.new("TextLabel")
    badge.Name = "Badge"
    badge.Position = viewport.Position
    badge.Size = viewport.Size
    badge.BackgroundColor3 = Color3.fromRGB(40, 44, 60)
    badge.BorderSizePixel = 0
    badge.Font = Enum.Font.GothamBold
    badge.TextSize = 40
    badge.TextColor3 = Color3.new(1, 1, 1)
    badge.Text = ""
    badge.Visible = false
    badge.Parent = btn
    Instance.new("UICorner").Parent = badge

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, 106, 0, 8)
    title.Size = UDim2.new(1, -116, 0, 24)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 18
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(180, 230, 255)
    title.Text = ""
    title.Parent = btn

    local tag = Instance.new("TextLabel")
    tag.Name = "Tag"
    tag.BackgroundTransparency = 1
    tag.Position = UDim2.new(0, 106, 0, 32)
    tag.Size = UDim2.new(1, -116, 0, 16)
    tag.Font = Enum.Font.GothamBold
    tag.TextSize = 12
    tag.TextXAlignment = Enum.TextXAlignment.Left
    tag.Text = ""
    tag.Parent = btn

    local desc = Instance.new("TextLabel")
    desc.Name = "Desc"
    desc.BackgroundTransparency = 1
    desc.Position = UDim2.new(0, 106, 0, 50)
    desc.Size = UDim2.new(1, -116, 1, -58)
    desc.Font = Enum.Font.Gotham
    desc.TextSize = 14
    desc.TextWrapped = true
    desc.TextXAlignment = Enum.TextXAlignment.Left
    desc.TextYAlignment = Enum.TextYAlignment.Top
    desc.TextColor3 = Color3.fromRGB(220, 220, 230)
    desc.Text = ""
    desc.Parent = btn

    btn.Activated:Connect(function()
        blink.ChooseCard.Fire(i)
        cardsHolder.Visible = false
    end)
    cards[i] = { btn = btn, title = title, desc = desc, tag = tag, viewport = viewport, cam = cam, badge = badge }
end

-- put the pet's mesh in card `i`'s viewport (or clear it for player-stat cards)
local function setCardModel(i: number, petId: string?)
    local old = vpModels[i]
    if old then old:Destroy(); vpModels[i] = nil end
    if not petId or petId == "" then return end
    local src = Animals:FindFirstChild(Registry.meshName(petId))
    if src and src:IsA("BasePart") then
        local p = src:Clone()
        p.Anchored = true
        p.CanCollide = false
        p.CFrame = CFrame.new(0, 0, 0)
        p.Parent = cards[i].viewport
        vpModels[i] = p
    end
end

-- spin each visible thumbnail's camera around its model
local vpAngle = 0
RunService.Heartbeat:Connect(function(dt)
    if not cardsHolder.Visible then return end
    vpAngle += dt * 0.8
    for i, m in vpModels do
        local dist = m.Size.Magnitude + 1.4
        local eye = Vector3.new(math.cos(vpAngle) * dist, m.Size.Y * 0.35, math.sin(vpAngle) * dist)
        cards[i].cam.CFrame = CFrame.lookAt(eye, Vector3.new(0, 0, 0))
    end
end)

-- ── Net ───────────────────────────────────────────────────────────────────────
clientState.onStats(function(s)
    lvlLabel.Text = string.format("Lv %d   (%d/%d)", s.level, s.xp, s.xpNext)
    local frac = if s.xpNext > 0 then math.clamp(s.xp / s.xpNext, 0, 1) else 0
    xpFill.Size = UDim2.new(frac, 0, 1, 0)
    if s.maxHp and s.maxHp > 0 then
        hpFill.Size = UDim2.new(math.clamp(s.hp / s.maxHp, 0, 1), 0, 1, 0)
        hpLabel.Text = string.format("%d / %d", s.hp, s.maxHp)
    end
end)

blink.LevelUp.On(function(offer)
    local choices = offer.cards
    -- header by source (0 = level up, 1 = boss/elite card pack)
    if offer.source == 1 then
        cardHeader.Text = "🎴  CARD PACK"
        cardHeader.TextColor3 = Color3.fromRGB(255, 210, 120)
    else
        cardHeader.Text = "⬆  LEVEL UP!"
        cardHeader.TextColor3 = Color3.fromRGB(150, 255, 170)
    end
    for i = 1, MAX_CARDS do
        local ui = cards[i]
        local c = choices[i]
        if c then
            ui.btn.Visible = true
            ui.title.Text = c.title
            ui.desc.Text = c.desc
            -- kind: 0 stat, 2 weapon upgrade, 3 new weapon, 4 item. `weapon` = pet id OR item id.
            if c.kind == 2 or c.kind == 3 then
                local petName = (Registry.pets[c.weapon] and Registry.pets[c.weapon].name) or c.weapon
                ui.tag.Text = (if c.kind == 3 then "✦ NEW WEAPON · " else "◆ UPGRADE · ") .. petName
                ui.tag.TextColor3 = if c.kind == 3 then Color3.fromRGB(130, 255, 150) else Color3.fromRGB(210, 150, 255)
                ui.viewport.Visible = true
                ui.badge.Visible = false
                setCardModel(i, c.weapon)
            elseif c.kind == 4 then
                local it = ItemReg.items[c.weapon]
                ui.tag.Text = "◇ ITEM · " .. ((it and it.name) or c.weapon)
                ui.tag.TextColor3 = Color3.fromRGB(120, 220, 255)
                setCardModel(i, nil)
                ui.viewport.Visible = false
                ui.badge.Visible = true
                ui.badge.Text = (it and it.icon) or "◇"
                ui.badge.BackgroundColor3 = (it and it.color) or Color3.fromRGB(40, 44, 60)
            else
                ui.tag.Text = "★ PLAYER STAT"
                ui.tag.TextColor3 = Color3.fromRGB(255, 215, 120)
                setCardModel(i, nil)
                ui.viewport.Visible = false
                ui.badge.Visible = true
                ui.badge.Text = "★"
                ui.badge.BackgroundColor3 = Color3.fromRGB(60, 54, 30)
            end
        else
            ui.btn.Visible = false
            setCardModel(i, nil)
        end
    end
    cardsHolder.Visible = true
end)

-- enemy count (cheap; zombies in Mobs + UFOs), refreshed ~3 Hz. Look folders up lazily —
-- WaitForChild at load could deadlock the system loader if this runs first.

local mobsFolder: Instance? = nil
local ufoFolder: Instance? = nil
local acc = 0
local function updateCount(dt: number)
    acc += dt
    if acc < 0.3 then return end
    acc = 0
    mobsFolder = mobsFolder or workspace:FindFirstChild("Mobs")
    ufoFolder = ufoFolder or workspace:FindFirstChild("UFOs")
    local n = (mobsFolder and #mobsFolder:GetChildren() or 0) + (ufoFolder and #ufoFolder:GetChildren() or 0)
    enemyLabel.Text = "  Mobs: " .. n
end
scheduler.SYSTEM(updateCount, phases.Heartbeat)

return 0
