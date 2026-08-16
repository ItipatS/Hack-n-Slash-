-- ClientSystems/fpscounter.luau
-- Tiny perf overlay (top-left): FPS, frame time, network ping, and the live rendered mob
-- count. Mobile has no built-in FPS readout (Shift+F5 / the microprofiler are PC-keyboard
-- only), so this is how you read performance on a real phone during a stress test.
-- Gated by Config.Debug.SHOW_FPS — turn it off for a real build.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")

local std    = ReplicatedStorage.std
local Config = require(std:WaitForChild("config"))

if not Config.Debug.SHOW_FPS then return 0 end

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "FpsOverlay"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 50 -- above gameplay HUD, below nothing important
gui.Parent = playerGui

local label = Instance.new("TextLabel")
label.AnchorPoint = Vector2.new(0, 0)
label.Position = UDim2.new(0, 8, 0.6, 8)
label.Size = UDim2.new(0, 200, 0, 64)
label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
label.BackgroundTransparency = 0.45
label.BorderSizePixel = 0
label.Font = Enum.Font.Code
label.TextSize = 16
label.TextColor3 = Color3.fromRGB(120, 255, 140)
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.Text = "FPS --"
label.Parent = gui
Instance.new("UICorner").Parent = label
local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0, 8)
pad.PaddingTop = UDim.new(0, 6)
pad.Parent = label

local mobsFolder = workspace:FindFirstChild("Mobs")
local ufoFolder  = workspace:FindFirstChild("UFOs")

-- Smooth FPS over a short window so the number doesn't strobe every frame.
local frames, elapsed = 0, 0
local fps, ms = 0, 0
local UPDATE = 0.25

RunService.RenderStepped:Connect(function(dt: number)
    frames += 1
    elapsed += dt
    if elapsed < UPDATE then return end
    fps = frames / elapsed
    ms = (elapsed / frames) * 1000
    frames, elapsed = 0, 0

    if not mobsFolder or mobsFolder.Parent == nil then
        mobsFolder = workspace:FindFirstChild("Mobs")
    end
    if not ufoFolder or ufoFolder.Parent == nil then
        ufoFolder = workspace:FindFirstChild("UFOs")
    end
    local mobs = if mobsFolder then #mobsFolder:GetChildren() else 0
    local ufos = if ufoFolder then #ufoFolder:GetChildren() else 0
    local ping = math.floor(player:GetNetworkPing() * 1000 + 0.5)

    -- green > 50 fps, amber 30-50, red below
    label.TextColor3 = if fps >= 50 then Color3.fromRGB(120, 255, 140)
        elseif fps >= 30 then Color3.fromRGB(255, 215, 110)
        else Color3.fromRGB(255, 110, 110)

    label.Text = string.format("FPS %d  (%.1f ms)\nPing %d ms\nMobs %d  UFO %d", math.floor(fps + 0.5), ms, ping, mobs, ufos)
end)

return 0
