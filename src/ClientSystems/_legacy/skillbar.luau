-- ClientSystems/skillbar.luau
-- ONE skill button for the MAIN weapon. Only the main weapon's skill is usable (the rest auto-fire
-- with no skill); the player picks the main in the pet panel. Press Q or tap to use → UseSkill.Fire
-- (mainSlot). The server runs that pet's skill on its registry cooldown (authoritative); the
-- cooldown is predicted locally for the UI.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))
local Registry  = require(std:WaitForChild("petRegistry"))
local clientPlay = require(std:WaitForChild("clientPlay"))
local clientState = require(std:WaitForChild("clientState"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local equipped: { string } = {} -- equipped weapon ids in slot order (from Weapons)
local main     = 1              -- main slot index (from MainWeapon)
local cdUntil  = 0              -- predicted cooldown end (server time)

local gui = Instance.new("ScreenGui")
gui.Name = "SkillBar"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local btn = Instance.new("TextButton")
btn.AnchorPoint = Vector2.new(0.5, 1)
btn.Position = UDim2.new(0.5, 0, 1, -52)
btn.Size = UDim2.new(0, 96, 0, 96)
btn.BackgroundColor3 = Color3.fromRGB(40, 60, 90)
btn.BorderSizePixel = 0
btn.Text = ""
btn.Visible = false
btn.Parent = gui
Instance.new("UICorner").Parent = btn

local nameLbl = Instance.new("TextLabel")
nameLbl.BackgroundTransparency = 1
nameLbl.Size = UDim2.new(1, -6, 1, 0)
nameLbl.Position = UDim2.new(0, 3, 0, 0)
nameLbl.Font = Enum.Font.GothamBold
nameLbl.TextSize = 16
nameLbl.TextWrapped = true
nameLbl.TextColor3 = Color3.new(1, 1, 1)
nameLbl.Text = ""
nameLbl.Parent = btn

local keyLbl = Instance.new("TextLabel")
keyLbl.BackgroundTransparency = 1
keyLbl.Position = UDim2.new(0, 6, 0, 4)
keyLbl.Size = UDim2.new(0, 24, 0, 18)
keyLbl.Font = Enum.Font.GothamBold
keyLbl.TextSize = 15
keyLbl.TextColor3 = Color3.fromRGB(180, 220, 255)
keyLbl.TextXAlignment = Enum.TextXAlignment.Left
keyLbl.Text = "Q"
keyLbl.Parent = btn

local cdOverlay = Instance.new("Frame")
cdOverlay.AnchorPoint = Vector2.new(0, 1)
cdOverlay.Position = UDim2.new(0, 0, 1, 0)
cdOverlay.Size = UDim2.new(1, 0, 0, 0)
cdOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
cdOverlay.BackgroundTransparency = 0.45
cdOverlay.BorderSizePixel = 0
cdOverlay.ZIndex = 2
cdOverlay.Parent = btn
Instance.new("UICorner").Parent = cdOverlay

local cdText = Instance.new("TextLabel")
cdText.BackgroundTransparency = 1
cdText.Size = UDim2.new(1, 0, 1, 0)
cdText.ZIndex = 3
cdText.Font = Enum.Font.GothamBold
cdText.TextSize = 24
cdText.TextColor3 = Color3.new(1, 1, 1)
cdText.Text = ""
cdText.Parent = btn

local function mainSkill(): { name: string, desc: string, cooldown: number }?
    local id = equipped[main]
    local pet = id and Registry.pets[id]
    return pet and pet.skill or nil
end

local function refresh()
    local sk = mainSkill()
    if sk then
        btn.Visible = true
        nameLbl.Text = sk.name
    else
        btn.Visible = false
    end
end

local function tryUse()
    local sk = mainSkill()
    if not sk then return end
    local now = workspace:GetServerTimeNow()
    if now < cdUntil then return end
    cdUntil = now + sk.cooldown
    blink.UseSkill.Fire(main)
end

btn.Activated:Connect(tryUse)
clientState.onWeapons(function(ids) equipped = ids; refresh() end)
clientState.onMain(function(m) main = m; refresh() end)

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.Q then tryUse() end
end)

local function update()
    -- only show the skill button during a live run, not at the menu / while spectating
    btn.Visible = clientPlay.isPlaying() and (mainSkill() ~= nil)
    if not btn.Visible then return end
    local sk = mainSkill()
    local cd = sk and sk.cooldown or 1
    local rem = cdUntil - workspace:GetServerTimeNow()
    if rem > 0 then
        cdOverlay.Size = UDim2.new(1, 0, math.clamp(rem / cd, 0, 1), 0)
        cdText.Text = string.format("%.1f", rem)
    else
        cdOverlay.Size = UDim2.new(1, 0, 0, 0)
        cdText.Text = ""
    end
end

scheduler.SYSTEM(update, phases.Heartbeat)
return 0
