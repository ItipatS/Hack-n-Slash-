-- ClientSystems/weaponpanel.luau
-- PET TAB — a MENU-ONLY screen (open with B or the on-screen "PETS" button). Lists EVERY pet; the
-- right pane shows a spinning 3D model + stats + skill + upgrade path. For OWNED pets you pick your
-- single MAIN (★ = the pet you start the run with + its skill/ult). LOCKED pets show a Tix BUY button
-- (the shop). Pets unlock via elite/boss drops + this shop. In a run, extra weapons (slots 2+) are
-- gained from UNLOCKED-pet level-up cards + boss/elite drops. Server rejects main/buy changes mid-run.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")

local std      = ReplicatedStorage.std
local blink    = require(std:WaitForChild("ClientNet"))
local Registry = require(std:WaitForChild("petRegistry"))
local clientPlay = require(std:WaitForChild("clientPlay"))
local clientState = require(std:WaitForChild("clientState"))
local Panels   = require(std:WaitForChild("panels"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Animals = ReplicatedStorage:WaitForChild("Animals")

local gui = Instance.new("ScreenGui")
gui.Name = "WeaponPanel"
gui.ResetOnSpawn = false
gui.DisplayOrder = 30 -- ABOVE the main menu (20) so the panel opens in FRONT of it
gui.Parent = playerGui

-- ── On-screen open button (menu row, left of centre — see itemtab for the right side) ──
local openBtn = Instance.new("TextButton")
openBtn.AnchorPoint = Vector2.new(1, 0.5)
openBtn.Position = UDim2.new(0.5, -8, 0.525, 0)
openBtn.Size = UDim2.new(0, 168, 0, 46)
openBtn.BackgroundColor3 = Color3.fromRGB(68, 103, 247)
openBtn.BorderSizePixel = 0
openBtn.Font = Enum.Font.GothamBold
openBtn.TextSize = 19
openBtn.TextColor3 = Color3.new(1, 1, 1)
openBtn.Text = "🐾 PETS  [B]"
openBtn.Parent = gui
Instance.new("UICorner").Parent = openBtn

-- ── Panel ─────────────────────────────────────────────────────────────────────────
local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.5, 0)
frame.Size = UDim2.new(0, 880, 0, 590)
frame.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
frame.BackgroundTransparency = 0.02
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
title.Size = UDim2.new(1, -220, 0, 34)
title.Font = Enum.Font.GothamBold
title.TextSize = 22
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.new(1, 1, 1)
title.Text = "PET TAB   ·   pick your MAIN  (★ = skill/ult)  ·  buy with Tix"
title.Parent = frame

local squadLbl = Instance.new("TextLabel")
squadLbl.AnchorPoint = Vector2.new(1, 0)
squadLbl.Position = UDim2.new(1, -62, 0, 16)
squadLbl.Size = UDim2.new(0, 150, 0, 30)
squadLbl.BackgroundTransparency = 1
squadLbl.Font = Enum.Font.GothamBold
squadLbl.TextSize = 16
squadLbl.TextXAlignment = Enum.TextXAlignment.Right
squadLbl.TextColor3 = Color3.fromRGB(150, 220, 255)
squadLbl.Text = "Squad 1/4"
squadLbl.Parent = frame

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

-- left: scrolling pet list (every pet)
local list = Instance.new("ScrollingFrame")
list.Position = UDim2.new(0, 18, 0, 62)
list.Size = UDim2.new(0, 300, 1, -78)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 6
list.CanvasSize = UDim2.new()
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = frame
local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 8)
layout.Parent = list

-- right: detail pane
local detail = Instance.new("Frame")
detail.Position = UDim2.new(0, 332, 0, 62)
detail.Size = UDim2.new(1, -350, 1, -78)
detail.BackgroundColor3 = Color3.fromRGB(18, 20, 27)
detail.BorderSizePixel = 0
detail.Parent = frame
Instance.new("UICorner").Parent = detail

local viewport = Instance.new("ViewportFrame")
viewport.Position = UDim2.new(0, 14, 0, 14)
viewport.Size = UDim2.new(1, -28, 0, 200)
viewport.BackgroundColor3 = Color3.fromRGB(12, 14, 20)
viewport.BorderSizePixel = 0
viewport.Ambient = Color3.fromRGB(190, 195, 205)
viewport.LightColor = Color3.fromRGB(255, 255, 255)
viewport.LightDirection = Vector3.new(-1, -1.2, -0.6)
viewport.Parent = detail
Instance.new("UICorner").Parent = viewport
local vpCam = Instance.new("Camera")
vpCam.FieldOfView = 45
viewport.CurrentCamera = vpCam
vpCam.Parent = viewport

local info = Instance.new("ScrollingFrame")
info.Position = UDim2.new(0, 14, 0, 222)
info.Size = UDim2.new(1, -28, 1, -222 - 108) -- reserve 108px for the action buttons
info.BackgroundTransparency = 1
info.BorderSizePixel = 0
info.ScrollBarThickness = 6
info.CanvasSize = UDim2.new()
info.AutomaticCanvasSize = Enum.AutomaticSize.Y
info.Parent = detail
local dLayout = Instance.new("UIListLayout")
dLayout.SortOrder = Enum.SortOrder.LayoutOrder
dLayout.Padding = UDim.new(0, 6)
dLayout.Parent = info

local function dLabel(font: Enum.Font, size: number, color: Color3, order: number): TextLabel
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = UDim2.new(1, -6, 0, size + 4)
    l.AutomaticSize = Enum.AutomaticSize.Y
    l.Font = font
    l.TextSize = size
    l.TextWrapped = true
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextColor3 = color
    l.LayoutOrder = order
    l.Text = ""
    l.Parent = info
    return l
end

local dName  = dLabel(Enum.Font.GothamBold, 26, Color3.fromRGB(200, 235, 255), 1)
local dKind  = dLabel(Enum.Font.GothamMedium, 16, Color3.fromRGB(160, 170, 190), 2)
local dStats = dLabel(Enum.Font.Gotham, 16, Color3.fromRGB(225, 225, 235), 3)
local dSkill = dLabel(Enum.Font.GothamMedium, 16, Color3.fromRGB(255, 220, 140), 4)
local dPerksHdr = dLabel(Enum.Font.GothamBold, 14, Color3.fromRGB(210, 150, 255), 5)
local dPerks = dLabel(Enum.Font.Gotham, 14, Color3.fromRGB(210, 210, 225), 6)

-- two action buttons pinned at the bottom of the detail pane
local function actionButton(yFromBottom: number): TextButton
    local b = Instance.new("TextButton")
    b.AnchorPoint = Vector2.new(0, 1)
    b.Position = UDim2.new(0, 14, 1, -yFromBottom)
    b.Size = UDim2.new(1, -28, 0, 42)
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamBold
    b.TextSize = 18
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Text = ""
    b.Parent = detail
    Instance.new("UICorner").Parent = b
    return b
end
local mainBtn = actionButton(60) -- upper (set as main)
local actBtn  = actionButton(12) -- lower (add/remove squad OR buy)

-- ── Viewport spinning model ─────────────────────────────────────────────────────────
local vpModel: BasePart? = nil
local function setViewportPet(id: string)
    if vpModel then vpModel:Destroy() end
    vpModel = nil
    local src = Animals:FindFirstChild(Registry.meshName(id))
    if src and src:IsA("BasePart") then
        local p = src:Clone()
        p.Anchored = true; p.CanCollide = false
        p.CFrame = CFrame.new(0, 0, 0)
        p.Parent = viewport
        vpModel = p
    end
end
local vpAngle = 0
RunService.Heartbeat:Connect(function(dt)
    local m = vpModel
    if not frame.Visible or not m then return end
    vpAngle += dt * 0.7
    local dist = m.Size.Magnitude + 1.6
    vpCam.CFrame = CFrame.lookAt(Vector3.new(math.cos(vpAngle) * dist, m.Size.Y * 0.35, math.sin(vpAngle) * dist), Vector3.new(0, 0, 0))
end)

-- ── State ─────────────────────────────────────────────────────────────────────────
local owned: { [string]: boolean } = {}  -- collection (from Unlocked)
local mainId: string? = nil              -- the chosen main pet (from Weapons[1])
local tix = 0                            -- balance (from TixCount) for the shop
local rows: { [string]: TextButton } = {}
local selected: string? = nil

local function statLines(id: string): string
    local p = Registry.pets[id]
    if not p then return "" end
    local b = p.base
    local lines = { string.format("Damage: %d", b.dmg), string.format("Cooldown: %.2fs", b.fireCd) }
    if p.kind == "projectile" then
        lines[#lines + 1] = string.format("Pierce: %d", b.pierce)
        if b.shots and b.shots > 1 then lines[#lines + 1] = string.format("Shots: %d", b.shots) end
    else
        lines[#lines + 1] = string.format("Radius/Reach: %.0f", b.radius)
    end
    lines[#lines + 1] = string.format("Knockback: %d", b.knock)
    return table.concat(lines, "    ")
end

local function perksText(id: string): string
    local p = Registry.pets[id]
    if not p or not p.tree then return "" end
    local out = {}
    for lvl = 2, 10 do
        local up = p.tree[lvl]
        if up then out[#out + 1] = string.format("Lv%d — %s", lvl, up.desc) end
    end
    return table.concat(out, "\n")
end

local refresh -- fwd

local function select(id: string)
    selected = id
    local p = Registry.pets[id]
    if p then
        dName.Text = p.name
        dKind.Text = p.kind:upper() .. " · " .. (p.blurb or "")
        dStats.Text = statLines(id)
        dSkill.Text = if p.skill then ("★ Skill — " .. p.skill.name .. ": " .. p.skill.desc) else "★ Skill — none"
        dPerksHdr.Text = "Upgrade path (Lv 2-10)"
        dPerks.Text = perksText(id)
    end
    setViewportPet(id)
    info.CanvasPosition = Vector2.zero
    refresh()
end

local function statusTag(id: string): string
    if id == mainId then return "★" elseif owned[id] then return "•" else return "🔒" end
end

function refresh()
    squadLbl.Text = string.format("⛁ %d Tix", tix)
    for id, btn in rows do
        local nm = (Registry.pets[id] and Registry.pets[id].name) or id
        btn.Text = statusTag(id) .. "  " .. nm
        btn.BackgroundColor3 = if id == selected then Color3.fromRGB(70, 80, 110)
            elseif id == mainId then Color3.fromRGB(95, 80, 35)
            elseif owned[id] then Color3.fromRGB(45, 48, 60)
            else Color3.fromRGB(40, 40, 46)
        btn.TextColor3 = if owned[id] then Color3.new(1, 1, 1) else Color3.fromRGB(150, 150, 160)
    end
    -- one action button: locked → Buy; owned → Set as main (or "your main" if already)
    mainBtn.Visible = false
    local id = selected
    if not id then actBtn.Visible = false; return end
    actBtn.Visible = true
    if not owned[id] then
        local price = (Registry.pets[id] and Registry.pets[id].price) or 0
        local afford = tix >= price
        actBtn.Text = string.format("🔒 Buy — %d Tix", price)
        actBtn.Active = afford
        actBtn.AutoButtonColor = afford
        actBtn.BackgroundColor3 = if afford then Color3.fromRGB(80, 150, 90) else Color3.fromRGB(70, 60, 50)
    elseif id == mainId then
        actBtn.Text = "★ Your main (skill/ult)"
        actBtn.Active = false
        actBtn.AutoButtonColor = false
        actBtn.BackgroundColor3 = Color3.fromRGB(90, 75, 35)
    else
        actBtn.Text = "▶  Set as main"
        actBtn.Active = true
        actBtn.AutoButtonColor = true
        actBtn.BackgroundColor3 = Color3.fromRGB(150, 120, 50)
    end
end

actBtn.Activated:Connect(function()
    local id = selected
    if not id or not actBtn.Active then return end
    if not owned[id] then
        blink.BuyPet.Fire(id) -- shop: server validates Tix + unlocks
    else
        blink.SetMain.Fire(id) -- pick this owned pet as the run main
    end
end)

-- ── Build the (full) pet list ───────────────────────────────────────────────────────
local function rebuild()
    for _, btn in rows do btn:Destroy() end
    table.clear(rows)
    for i, id in Registry.order do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, -6, 0, 46)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamMedium
        btn.TextSize = 18
        btn.TextXAlignment = Enum.TextXAlignment.Left
        btn.LayoutOrder = i
        btn.Parent = list
        Instance.new("UICorner").Parent = btn
        local pad = Instance.new("UIPadding")
        pad.PaddingLeft = UDim.new(0, 14)
        pad.Parent = btn
        btn.Activated:Connect(function() select(id) end)
        rows[id] = btn
    end
    if not (selected and rows[selected]) then selected = Registry.order[1] end
    if selected then select(selected) else refresh() end
end

clientState.onOwned(function(ids)
    table.clear(owned)
    for _, id in ids do owned[id] = true end
    if next(rows) == nil then rebuild() else refresh() end
end)
clientState.onWeapons(function(ids)
    mainId = ids[1] -- slot 1 is the chosen main
    refresh()
end)
clientState.onTix(function(n)
    tix = n
    refresh()
end)

rebuild()

-- ── Open/close (menu-only; mutually exclusive with the Items tab via std/panels) ──────
local function setOpen(open: boolean)
    frame.Visible = open
    Panels.set("pets", open)
end
local function updateOpenBtn()
    local cur = Panels.get()
    openBtn.Visible = (clientPlay.get() == "menu") and (cur == nil or cur == "pets")
end
openBtn.Activated:Connect(function() setOpen(not frame.Visible) end)
closeBtn.Activated:Connect(function() setOpen(false) end)

Panels.onChanged(function(cur)
    if cur ~= "pets" and frame.Visible then frame.Visible = false end -- another tab opened → close ours
    updateOpenBtn()
end)
clientPlay.onChanged(function(s)
    if s ~= "menu" and frame.Visible then setOpen(false) end
    updateOpenBtn()
end)

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe or clientPlay.get() ~= "menu" then return end
    if input.KeyCode == Enum.KeyCode.B then setOpen(not frame.Visible) end
end)

return 0
