-- ClientSystems/uiscaler.luau
-- Auto-fits every gameplay/menu ScreenGui to the viewport (see std/uiScale). Watches PlayerGui so
-- it covers GUIs created in any order — no per-file wiring. The AIM stick is SKIPPED: it's a touch
-- target that must stay finger-sized regardless of screen.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

local UIScale = require(ReplicatedStorage:WaitForChild("std"):WaitForChild("uiScale"))

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local SKIP = { AimStick = true } -- don't shrink the on-screen aim stick (touch target)

local function consider(inst: Instance)
    if inst:IsA("ScreenGui") and not SKIP[inst.Name] then
        UIScale.attach(inst)
    end
end

for _, g in playerGui:GetChildren() do consider(g) end
playerGui.ChildAdded:Connect(consider)

return 0
