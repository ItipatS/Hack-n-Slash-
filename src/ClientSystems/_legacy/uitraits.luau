-- ClientSystems/uitraits.luau
-- Boots the imported framework UI trait system (std/ui): registers the default tag→trait factories
-- (HoverTween / ClickTween / ClickSound) and starts the CollectionService TagWatcher. Then auto-
-- "juices" buttons — a hover grow + click pulse — by giving each a UIScale and the Hover/Click tags,
-- so the whole UI gets game-feel without per-button wiring.
--
-- Coexistence with the resolution auto-scaler (std/uiScale via ClientSystems/uiscaler): that scaler
-- puts a UIScale on TOP-LEVEL ScreenGui widgets. We SKIP any button that already has a UIScale, so
-- the prominent top-level buttons keep clean resolution scaling and nested buttons (cards, list rows,
-- close ✕, etc.) get the juice on their own fresh UIScale. The AIM stick is skipped (it's a control).
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

local ui = ReplicatedStorage:WaitForChild("std"):WaitForChild("ui")
local DefaultTraits = require(ui:WaitForChild("DefaultTraits"))
local TagWatcher    = require(ui:WaitForChild("TagWatcher"))

DefaultTraits.Register()
TagWatcher.Initialize()

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local SKIP_GUI = { AimStick = true } -- the aim joystick is a control, not a juicy button

local function juice(inst: Instance)
    if not inst:IsA("GuiButton") then return end
    local screen = inst:FindFirstAncestorWhichIsA("ScreenGui")
    if screen and SKIP_GUI[screen.Name] then return end -- aim stick = control, no juice
    if inst:HasTag("ClickSound") then return end -- already juiced

    -- SOUND on every button (no UIScale needed, no conflict with resolution scaling)
    inst:AddTag("HoverSound") -- SoundService.Generics.Hover
    inst:AddTag("ClickSound") -- SoundService.Generics.Click

    -- TWEEN only when the button has no UIScale yet — top-level buttons already carry the
    -- resolution scaler's UIScale, and the tween would hijack it. Nested buttons get fresh juice.
    if not inst:FindFirstChildOfClass("UIScale") then
        local us = Instance.new("UIScale")
        us.Parent = inst
        inst:AddTag("HoverTween") -- factories registered by DefaultTraits; TagWatcher attaches them
        inst:AddTag("ClickTween")
    end
end

for _, d in playerGui:GetDescendants() do juice(d) end
playerGui.DescendantAdded:Connect(juice)

return 0
