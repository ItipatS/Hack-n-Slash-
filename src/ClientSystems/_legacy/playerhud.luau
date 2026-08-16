-- ClientSystems/playerhud.luau
-- Two gameplay HUD pieces (visible only while "playing"):
--   • STATS panel (top-right): the full derived stat sheet (StatSheet) + live HP (Stats) — HP w/
--     regen behind, ATK, haste, crit + crit dmg, speed, pickup, EXP mult, Tix drop rate.
--   • WEAPON SLOTS (left, vertical): the run loadout (Weapons) as spinning 3D thumbnails, the MAIN
--     (MainWeapon) flagged with ★ + a gold border.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")

local std        = ReplicatedStorage.std
local clientState = require(std:WaitForChild("clientState"))
local Registry   = require(std:WaitForChild("petRegistry"))
local ItemReg    = require(std:WaitForChild("itemRegistry"))
local clientPlay = require(std:WaitForChild("clientPlay"))

local Animals = ReplicatedStorage:WaitForChild("Animals")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "PlayerHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

clientPlay.onChanged(function(s) gui.Enabled = s == "playing" end)
gui.Enabled = clientPlay.get() == "playing"

-- ══ STATS panel (top-right) ════════════════════════════════════════════════════════
local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(1, 0)
panel.Position = UDim2.new(1, -12, 0, 12)
panel.Size = UDim2.new(0, 198, 0, 0)
panel.AutomaticSize = Enum.AutomaticSize.Y
panel.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
panel.BackgroundTransparency = 0.25
panel.BorderSizePixel = 0
panel.Parent = gui
Instance.new("UICorner").Parent = panel
local pPad = Instance.new("UIPadding")
pPad.PaddingTop = UDim.new(0, 8); pPad.PaddingBottom = UDim.new(0, 8)
pPad.PaddingLeft = UDim.new(0, 10); pPad.PaddingRight = UDim.new(0, 10)
pPad.Parent = panel
local pLayout = Instance.new("UIListLayout")
pLayout.SortOrder = Enum.SortOrder.LayoutOrder
pLayout.Padding = UDim.new(0, 3)
pLayout.Parent = panel

local function statRow(order: number): TextLabel
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = UDim2.new(1, 0, 0, 18)
    l.Font = Enum.Font.GothamMedium
    l.TextSize = 14
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextColor3 = Color3.fromRGB(225, 228, 238)
    l.LayoutOrder = order
    l.Text = ""
    l.Parent = panel
    return l
end

local hdr = statRow(0)
hdr.Text = "STATS"
hdr.Font = Enum.Font.GothamBold
hdr.TextSize = 15
hdr.TextColor3 = Color3.fromRGB(255, 225, 150)

local rHp      = statRow(1)
local rAtk     = statRow(2)
local rHaste   = statRow(3)
local rCrit    = statRow(4)
local rSpeed   = statRow(5)
local rPickup  = statRow(6)
local rAtkSize = statRow(7)
local rKnock   = statRow(8)
local rSkillCd = statRow(9)
local rExp     = statRow(10)
local rTix     = statRow(11)

-- ITEMS column (left, BESIDE the weapon slots): one badge per owned item (icon + level)
local itemsHolder = Instance.new("Frame")
itemsHolder.AnchorPoint = Vector2.new(0, 0.5)
itemsHolder.Position = UDim2.new(0, 70, 0.5, 0) -- just right of the weapon column (x=8, w≈56)
itemsHolder.Size = UDim2.new(0, 52, 0, 0)
itemsHolder.AutomaticSize = Enum.AutomaticSize.Y
itemsHolder.BackgroundTransparency = 1
itemsHolder.Parent = gui
local iLayout = Instance.new("UIListLayout")
iLayout.SortOrder = Enum.SortOrder.LayoutOrder
iLayout.Padding = UDim.new(0, 6)
iLayout.Parent = itemsHolder

type ItemBadge = { frame: Frame, icon: TextLabel, lvl: TextLabel }
local itemBadges: { ItemBadge } = {}
local function makeItemBadge(order: number): ItemBadge
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 52, 0, 52)
    frame.BackgroundColor3 = Color3.fromRGB(40, 44, 60)
    frame.BorderSizePixel = 0
    frame.LayoutOrder = order
    frame.Parent = itemsHolder
    Instance.new("UICorner").Parent = frame
    local icon = Instance.new("TextLabel")
    icon.BackgroundTransparency = 1
    icon.Size = UDim2.new(1, 0, 1, 0)
    icon.Font = Enum.Font.GothamBold
    icon.TextSize = 28
    icon.Text = ""
    icon.Parent = frame
    local lvl = Instance.new("TextLabel")
    lvl.AnchorPoint = Vector2.new(1, 1)
    lvl.Position = UDim2.new(1, -2, 1, -1)
    lvl.Size = UDim2.new(0, 24, 0, 16)
    lvl.BackgroundTransparency = 1
    lvl.Font = Enum.Font.GothamBlack
    lvl.TextSize = 14
    lvl.TextColor3 = Color3.fromRGB(255, 245, 180)
    lvl.TextStrokeTransparency = 0.3
    lvl.TextXAlignment = Enum.TextXAlignment.Right
    lvl.Text = ""
    lvl.ZIndex = 2
    lvl.Parent = frame
    return { frame = frame, icon = icon, lvl = lvl }
end

-- latest values (HP comes from Stats; the rest from StatSheet)
local hp, maxHp, regen = 100, 100, 0
local function renderStats()
    rHp.Text = string.format("❤ HP  %d / %d   ↻ %.2f/s", hp, maxHp, regen)
end

clientState.onStats(function(s)
    hp = s.hp
    if s.maxHp and s.maxHp > 0 then maxHp = s.maxHp end
    renderStats()
end)

clientState.onSheet(function(s)
    maxHp = s.maxHp
    regen = s.hpRegen
    renderStats()
    rAtk.Text     = string.format("⚔ ATK  ×%.2f", s.atk)
    rHaste.Text   = string.format("⚡ Haste  +%d%%", math.floor((s.haste - 1) * 100 + 0.5))
    rCrit.Text    = string.format("✷ Crit  %d%%  (×%.1f)", math.floor(s.crit * 100 + 0.5), s.critDmg)
    rSpeed.Text   = string.format("👟 Speed  %d", math.floor(s.walkSpeed + 0.5))
    rPickup.Text  = string.format("🧲 Pickup  ×%.2f", s.pickup)
    rAtkSize.Text = string.format("⬚ Atk Size  ×%.2f", s.atkSize)
    rKnock.Text   = string.format("➤ Knock  ×%.2f", s.knock)
    rSkillCd.Text = string.format("⌛ Skill CD  ×%.2f", s.skillCd)
    rExp.Text     = string.format("✦ EXP  ×%.2f", s.expMult)
    rTix.Text     = string.format("🪙 Tix  ×%.2f", s.tixRate)
end)
renderStats()

-- owned items → left-side badge column (icon + level), beside the weapon slots
clientState.onItems(function(list)
    for i, entry in list do
        local b = itemBadges[i]
        if not b then b = makeItemBadge(i); itemBadges[i] = b end
        local it = ItemReg.items[entry.id]
        b.icon.Text = (it and it.icon) or "◇"
        b.frame.BackgroundColor3 = (it and it.color) or Color3.fromRGB(40, 44, 60)
        b.lvl.Text = "L" .. entry.level
        b.frame.Visible = true
    end
    for i = #list + 1, #itemBadges do itemBadges[i].frame.Visible = false end
end)

-- ══ WEAPON SLOTS (left, vertical) ══════════════════════════════════════════════════
local slotsHolder = Instance.new("Frame")
slotsHolder.AnchorPoint = Vector2.new(0, 0.5)
slotsHolder.Position = UDim2.new(0, 8, 0.5, 0)
slotsHolder.Size = UDim2.new(0, 56, 0, 0)
slotsHolder.AutomaticSize = Enum.AutomaticSize.Y
slotsHolder.BackgroundTransparency = 1
slotsHolder.Parent = gui
local sLayout = Instance.new("UIListLayout")
sLayout.SortOrder = Enum.SortOrder.LayoutOrder
sLayout.Padding = UDim.new(0, 6)
sLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
sLayout.Parent = slotsHolder

type Slot = { frame: Frame, viewport: ViewportFrame, cam: Camera, stroke: UIStroke, star: TextLabel, id: string }
local slots: { Slot } = {}
local slotModels: { [number]: BasePart } = {}

local function makeSlot(order: number): Slot
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 52, 0, 52)
    frame.BackgroundColor3 = Color3.fromRGB(26, 28, 38)
    frame.BorderSizePixel = 0
    frame.LayoutOrder = order
    frame.Parent = slotsHolder
    Instance.new("UICorner").Parent = frame
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 2
    stroke.Color = Color3.fromRGB(70, 75, 95)
    stroke.Parent = frame

    local viewport = Instance.new("ViewportFrame")
    viewport.Size = UDim2.new(1, -4, 1, -4)
    viewport.Position = UDim2.new(0, 2, 0, 2)
    viewport.BackgroundColor3 = Color3.fromRGB(14, 16, 24)
    viewport.BorderSizePixel = 0
    viewport.Ambient = Color3.fromRGB(190, 195, 205)
    viewport.LightColor = Color3.fromRGB(255, 255, 255)
    viewport.LightDirection = Vector3.new(-1, -1.2, -0.6)
    viewport.Parent = frame
    Instance.new("UICorner").Parent = viewport
    local cam = Instance.new("Camera")
    cam.FieldOfView = 40
    viewport.CurrentCamera = cam
    cam.Parent = viewport

    local star = Instance.new("TextLabel")
    star.AnchorPoint = Vector2.new(1, 0)
    star.Position = UDim2.new(1, -1, 0, -1)
    star.Size = UDim2.new(0, 16, 0, 16)
    star.BackgroundTransparency = 1
    star.Font = Enum.Font.GothamBold
    star.TextSize = 15
    star.TextColor3 = Color3.fromRGB(255, 215, 90)
    star.Text = "★"
    star.Visible = false
    star.ZIndex = 3
    star.Parent = frame

    return { frame = frame, viewport = viewport, cam = cam, stroke = stroke, star = star, id = "" }
end

local function setSlotModel(i: number, petId: string)
    local old = slotModels[i]
    if old then old:Destroy(); slotModels[i] = nil end
    local src = Animals:FindFirstChild(Registry.meshName(petId))
    if src and src:IsA("BasePart") then
        local p = src:Clone()
        p.Anchored = true
        p.CanCollide = false
        p.CFrame = CFrame.new(0, 0, 0)
        p.Parent = slots[i].viewport
        slotModels[i] = p
    end
end

local equipped: { string } = {}
local mainSlot = 1

local function refreshMain()
    for i, slot in slots do
        local isMain = i == mainSlot
        slot.star.Visible = isMain
        slot.stroke.Color = if isMain then Color3.fromRGB(255, 205, 80) else Color3.fromRGB(70, 75, 95)
        slot.stroke.Thickness = if isMain then 3 else 2
    end
end

local function rebuild()
    -- grow the slot pool to match the loadout; hide extras
    for i = 1, #equipped do
        if not slots[i] then slots[i] = makeSlot(i) end
        local slot = slots[i]
        slot.frame.Visible = true
        if slot.id ~= equipped[i] then
            slot.id = equipped[i]
            setSlotModel(i, equipped[i])
        end
    end
    for i = #equipped + 1, #slots do
        slots[i].frame.Visible = false
        slots[i].id = ""
        if slotModels[i] then slotModels[i]:Destroy(); slotModels[i] = nil end
    end
    refreshMain()
end

clientState.onWeapons(function(ids)
    equipped = ids
    rebuild()
end)
clientState.onMain(function(slot)
    mainSlot = slot
    refreshMain()
end)

-- slow-spin every slot thumbnail (shared angle)
local angle = 0
RunService.Heartbeat:Connect(function(dt)
    if not gui.Enabled then return end
    angle += dt * 0.8
    for i, m in slotModels do
        local dist = m.Size.Magnitude + 1.2
        local eye = Vector3.new(math.cos(angle) * dist, m.Size.Y * 0.3, math.sin(angle) * dist)
        slots[i].cam.CFrame = CFrame.lookAt(eye, Vector3.new(0, 0, 0))
    end
end)

return 0
