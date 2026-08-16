-- ClientSystems/aimstick.luau
-- On-screen AIM thumbstick for touch devices. On mobile the camera is dragged with the
-- right side of the screen, so there's no spare "look" axis to aim with — this gives a
-- dedicated stick (bottom-right) whose direction becomes the world-space aim. The default
-- left movement stick is untouched.
--
-- Output goes into std/aimState; syncPet.luau reads it, streams it to the server (Aim) and
-- faces the pets. Camera-relative: stick-up = away from the camera, stick-right = camera right.
--
-- Visible only while alive (shown on CharacterAdded, hidden on Humanoid.Died) so it never
-- overlaps the main menu or the game-over screen.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local Config    = require(std:WaitForChild("config"))
local AimState  = require(std:WaitForChild("aimState"))
local clientPlay = require(std:WaitForChild("clientPlay"))

local CC = Config.Controls

-- Only build the stick when the control scheme calls for it.
local mode = CC.AIM_STICK
local enabled = mode == "always"
    or (mode == "auto" and UserInputService.TouchEnabled and not UserInputService.MouseEnabled)
if not enabled then return 0 end

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local RADIUS   = CC.AIM_STICK_RADIUS
local KNOB     = CC.AIM_STICK_KNOB
local MARGIN   = CC.AIM_STICK_MARGIN
local DEADZONE = CC.AIM_STICK_DEADZONE

-- ── UI ──────────────────────────────────────────────────────────────────────────
local gui = Instance.new("ScreenGui")
gui.Name = "AimStick"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false -- shown once the character spawns
gui.Parent = playerGui

-- The ring is an ACTIVE ImageButton (not a Frame): a touch that BEGINS over an active GUI button is
-- flagged game-processed, so Roblox's default touch camera ignores that finger — dragging the stick
-- no longer pans the camera, while the rest of the screen still pans. We capture the touch here and
-- then track its drag via UserInputService (which keeps firing once the finger leaves the button).
local ring = Instance.new("ImageButton")
ring.Name = "Ring"
ring.AnchorPoint = Vector2.new(0.5, 0.5)
ring.Position = UDim2.new(1, -MARGIN, 1, -MARGIN)
ring.Size = UDim2.new(0, RADIUS * 2, 0, RADIUS * 2)
ring.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
ring.BackgroundTransparency = 0.5
ring.BorderSizePixel = 0
ring.Image = ""              -- visual is the colored circle (BackgroundColor + UICorner), not an image
ring.AutoButtonColor = false -- no press flash
ring.Active = true           -- sink the touch from the camera
ring.Selectable = false
ring.Parent = gui
local ringCorner = Instance.new("UICorner")
ringCorner.CornerRadius = UDim.new(1, 0)
ringCorner.Parent = ring
local ringStroke = Instance.new("UIStroke")
ringStroke.Thickness = 2
ringStroke.Color = Color3.fromRGB(150, 220, 255)
ringStroke.Transparency = 0.4
ringStroke.Parent = ring

local label = Instance.new("TextLabel")
label.BackgroundTransparency = 1
label.Size = UDim2.new(1, 0, 0, 16)
label.Position = UDim2.new(0, 0, 0, -20)
label.Font = Enum.Font.GothamBold
label.TextSize = 12
label.TextColor3 = Color3.fromRGB(150, 220, 255)
label.Text = "AIM"
label.Parent = ring

local knob = Instance.new("Frame")
knob.Name = "Knob"
knob.AnchorPoint = Vector2.new(0.5, 0.5)
knob.Position = UDim2.new(0.5, 0, 0.5, 0)
knob.Size = UDim2.new(0, KNOB * 2, 0, KNOB * 2)
knob.BackgroundColor3 = Color3.fromRGB(150, 220, 255)
knob.BackgroundTransparency = 0.1
knob.BorderSizePixel = 0
knob.ZIndex = 2
knob.Parent = ring
local knobCorner = Instance.new("UICorner")
knobCorner.CornerRadius = UDim.new(1, 0)
knobCorner.Parent = knob

-- ── Input → normalized stick vector ──────────────────────────────────────────────
local activeInput: InputObject? = nil
local sx, sy = 0, 0 -- normalized stick offset (-1..1); sy>0 = pulled DOWN on screen

local function ringCenter(): Vector2
    return ring.AbsolutePosition + ring.AbsoluteSize / 2
end

local function setKnob(dx: number, dy: number) -- px offset from centre
    knob.Position = UDim2.new(0.5, dx, 0.5, dy)
end

local function updateFrom(pos: Vector3)
    local c = ringCenter()
    local dx, dy = pos.X - c.X, pos.Y - c.Y
    local len = math.sqrt(dx * dx + dy * dy)
    if len > RADIUS then dx, dy = dx / len * RADIUS, dy / len * RADIUS; len = RADIUS end
    setKnob(dx, dy)
    sx, sy = dx / RADIUS, dy / RADIUS
    if (len / RADIUS) < DEADZONE then sx, sy = 0, 0 end
end

local function isCandidate(input: InputObject): boolean
    return input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseButton1
end

-- Capture on the BUTTON (sinks the touch from the camera). The whole square button area counts as
-- the stick (gives fat-finger slack), so no manual hit-test is needed.
ring.InputBegan:Connect(function(input)
    if not gui.Enabled or activeInput or not isCandidate(input) then return end
    activeInput = input
    updateFrom(input.Position)
end)

-- Drag tracking stays on UserInputService: it keeps firing for the captured touch even after the
-- finger slides off the button (GuiObject.InputChanged would stop at the button's edge).
UserInputService.InputChanged:Connect(function(input)
    if input == activeInput then updateFrom(input.Position) end
end)

UserInputService.InputEnded:Connect(function(input)
    if input == activeInput then
        activeInput = nil
        sx, sy = 0, 0
        setKnob(0, 0) -- recentre the knob; aim HOLDS its last direction (auto-fire keeps going)
    end
end)

-- ── Per-frame: map the stick to a camera-relative world aim ───────────────────────
local function flat(v: Vector3): Vector3
    local f = Vector3.new(v.X, 0, v.Z)
    return if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, -1)
end

local function step()
    if sx == 0 and sy == 0 then return end -- no input → keep the last aim
    local cam = workspace.CurrentCamera
    if not cam then return end
    local fwd = flat(cam.CFrame.LookVector)   -- stick-up   → away from camera
    local right = flat(cam.CFrame.RightVector) -- stick-right → camera right
    local dir = right * sx + fwd * (-sy)       -- screen-down (sy>0) is toward camera
    AimState.set(dir)
end
scheduler.SYSTEM(step, phases.Heartbeat)

-- ── Visibility: during a live run only (not the menu / lobby body / spectate) ───────
clientPlay.onChanged(function(s) gui.Enabled = s == "playing" end)

return 0
