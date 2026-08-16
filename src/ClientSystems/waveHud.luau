-- ClientSystems/waveHud.luau
-- Wave / survival HUD (top-centre). Driven by the server wave director over CombatRemote ("wave" events):
-- current wave, phase (incoming / N remaining / breather countdown), and the running kill score. Hidden
-- until a run is started from the dev panel.
--!strict

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remote = ReplicatedStorage:WaitForChild("CombatRemote") :: RemoteEvent
local LP  = Players.LocalPlayer
local gui = LP:WaitForChild("PlayerGui")

local screen = Instance.new("ScreenGui")
screen.Name = "WaveHud"
screen.ResetOnSpawn = false
screen.DisplayOrder = 25
screen.Parent = gui

local holder = Instance.new("Frame")
holder.Size = UDim2.fromOffset(280, 78)
holder.AnchorPoint = Vector2.new(0.5, 0)
holder.Position = UDim2.new(0.5, 0, 0, 12)
holder.BackgroundTransparency = 1
holder.Visible = false
holder.Parent = screen

local function label(sizeY: number, y: number, font: Enum.Font, ts: number, col: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, 0, 0, sizeY)
	l.Position = UDim2.fromOffset(0, y)
	l.BackgroundTransparency = 1
	l.Font = font
	l.TextSize = ts
	l.TextColor3 = col
	l.TextStrokeTransparency = 0.5
	l.Text = ""
	l.Parent = holder
	return l
end

local waveL  = label(34, 0,  Enum.Font.GothamBlack, 30, Color3.fromRGB(242, 245, 250))
local subL   = label(18, 34, Enum.Font.GothamBold,  14, Color3.fromRGB(180, 190, 205))
local killsL = label(18, 52, Enum.Font.GothamBold,  15, Color3.fromRGB(255, 120, 120))

remote.OnClientEvent:Connect(function(kind: any, data: any)
	if kind ~= "wave" or type(data) ~= "table" then return end
	if data.phase == "idle" then holder.Visible = false; return end
	holder.Visible = true
	waveL.Text = "WAVE " .. tostring(data.wave)
	if data.phase == "spawning" then
		subL.Text = "incoming\u{2026}"
	elseif data.phase == "breather" then
		subL.Text = string.format("next wave in %d\u{2026}", math.ceil(data.timer or 0))
	else
		subL.Text = string.format("%d remaining", data.alive or 0)
	end
	killsL.Text = "\u{2620} " .. tostring(data.kills or 0) .. " killed"
end)

return 0
