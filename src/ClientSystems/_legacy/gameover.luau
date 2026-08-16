-- ClientSystems/gameover.luau
-- Death + SPECTATE screen. The run is round-based: when YOU die you become a ghost for the rest
-- of the round (you can't rejoin — the server ignores Play from a ghost). Instead you spectate:
--   • a slow cinematic ORBIT of the battlefield by default ("watch anything"), and
--   • an option to FOLLOW a living player (tap the button / press V to cycle players → orbit).
-- You stay here until the round ends (the last living player falls) → the server broadcasts
-- RoundOver, mainmenu.luau re-shows the menu, and this screen releases the camera + hides.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")

local std   = ReplicatedStorage.std
local blink = require(std:WaitForChild("ClientNet"))
local clientPlay = require(std:WaitForChild("clientPlay"))
local Format = require(std:WaitForChild("FormatUtils"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ── Orbit framing: a manual AABB of workspace.Map (same approach as mainmenu.luau, since the
-- bounding box is degenerate and the path waypoints have far outliers). ───────────────────────
local center, orbitR, orbitH = Vector3.new(0, 30, 0), 240, 120
do
    local map = workspace:FindFirstChild("Map") or workspace:WaitForChild("Map", 5)
    if map then
        local minv, maxv, n = Vector3.new(1e9, 1e9, 1e9), Vector3.new(-1e9, -1e9, -1e9), 0
        for _, d in map:GetDescendants() do
            if d:IsA("BasePart") then
                n += 1
                minv, maxv = minv:Min(d.Position), maxv:Max(d.Position)
            end
        end
        if n > 0 then
            center = (minv + maxv) * 0.5
            local span = math.max(maxv.X - minv.X, maxv.Z - minv.Z)
            orbitR, orbitH = span * 0.7 + 20, span * 0.7 + 30
        end
    end
end

-- ── UI ──────────────────────────────────────────────────────────────────────────
local gui = Instance.new("ScreenGui")
gui.Name = "GameOver"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 10
gui.Enabled = false
gui.Parent = playerGui

-- top banner: YOU DIED + run summary (kept small so the spectated battlefield stays visible)
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0)
panel.Position = UDim2.new(0.5, 0, 0, 24)
panel.Size = UDim2.new(0, 420, 0, 96)
panel.BackgroundColor3 = Color3.fromRGB(28, 30, 40)
panel.BackgroundTransparency = 0.15
panel.BorderSizePixel = 0
panel.Parent = gui
Instance.new("UICorner").Parent = panel

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 0, 0, 12)
title.Size = UDim2.new(1, 0, 0, 34)
title.Font = Enum.Font.GothamBold
title.TextSize = 26
title.TextColor3 = Color3.fromRGB(255, 90, 90)
title.Text = "YOU DIED"
title.Parent = panel

local info = Instance.new("TextLabel")
info.BackgroundTransparency = 1
info.Position = UDim2.new(0, 0, 0, 48)
info.Size = UDim2.new(1, 0, 0, 36)
info.Font = Enum.Font.Gotham
info.TextSize = 16
info.TextColor3 = Color3.new(1, 1, 1)
info.Text = ""
info.Parent = panel

-- spectate control: cycles Orbit → each living player → Orbit
local btn = Instance.new("TextButton")
btn.Name = "SpectateBtn"
btn.AnchorPoint = Vector2.new(0.5, 0)
btn.Position = UDim2.new(0.5, 0, 0, 130)
btn.Size = UDim2.new(0, 300, 0, 40)
btn.BackgroundColor3 = Color3.fromRGB(50, 60, 80)
btn.Font = Enum.Font.GothamBold
btn.TextSize = 17
btn.TextColor3 = Color3.new(1, 1, 1)
btn.Text = "Spectating: Free cam"
btn.Parent = gui
Instance.new("UICorner").Parent = btn

local hint = Instance.new("TextLabel")
hint.AnchorPoint = Vector2.new(0.5, 0)
hint.Position = UDim2.new(0.5, 0, 0, 176)
hint.Size = UDim2.new(0, 420, 0, 24)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.GothamMedium
hint.TextSize = 14
hint.TextColor3 = Color3.fromRGB(180, 190, 205)
hint.Text = "WASD fly  •  hold right-mouse to look  •  E/Q up·down  •  V follow a player  •  waiting for the round…"
hint.Parent = gui

-- ── Spectate state ────────────────────────────────────────────────────────────────
-- A ghost flies a FREE camera (WASD + right-mouse look, E/Q up·down) over the battlefield, or can
-- lock onto a living player (button / V cycles Free → each player → Free). Starts at a high
-- overview of the arena.
local WATCH_EYE = Vector3.new(260.577, 287.051, -345.356)
local FLY_SPEED = 120
local LOOK_SENS = 0.005

local spectating = false
local followTarget: Player? = nil -- nil = free-fly cam; else over-the-shoulder follow
local specPos = WATCH_EYE
local yaw, pitch = 0, 0
local looking = false -- right-mouse held → mouse-look

-- point the free cam from `fromPos` toward `toPos` (sets specPos + yaw/pitch)
local function aimFromTo(fromPos: Vector3, toPos: Vector3)
    local look = toPos - fromPos
    specPos = fromPos
    yaw = math.atan2(-look.X, -look.Z)
    pitch = math.atan2(look.Y, math.sqrt(look.X * look.X + look.Z * look.Z))
end

local function rootOf(p: Player): BasePart?
    local char = p.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if hum and root and (hum :: Humanoid).Health > 0 then return root :: BasePart end
    return nil
end

local function aliveOthers(): { Player }
    local list = {}
    for _, p in Players:GetPlayers() do
        if p ~= player and rootOf(p) then list[#list + 1] = p end
    end
    return list
end

local function refreshLabel()
    btn.Text = if followTarget then "Following: " .. followTarget.DisplayName .. "   ▶" else "Spectating: Free cam"
end

-- advance the spectate target: Free → first alive → next alive → … → Free
local function cycleTarget()
    if not spectating then return end
    local list = aliveOthers()
    if #list == 0 then followTarget = nil; refreshLabel(); return end
    if not followTarget then
        followTarget = list[1]
    else
        local i = table.find(list, followTarget)
        followTarget = if i and i < #list then list[i + 1] else nil -- wrap past the end → free cam
    end
    refreshLabel()
end

local function stopLook()
    if not looking then return end
    looking = false
    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    UserInputService.MouseIconEnabled = true
end

btn.Activated:Connect(cycleTarget)
UserInputService.InputBegan:Connect(function(input, gpe)
    if not spectating then return end
    if input.KeyCode == Enum.KeyCode.V and not gpe then cycleTarget(); return end
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        looking = true -- hold right-mouse to look around the free cam
        UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
        UserInputService.MouseIconEnabled = false
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then stopLook() end
end)

-- ── Camera loop (drives the camera ONLY while spectating; mainmenu owns it otherwise) ─────────
-- Gate on clientPlay (the single camera arbiter), NOT the local `spectating` bool — so the moment the
-- round ends and mainmenu flips the state to "menu", this loop yields the camera even if our own
-- RoundOver handler hasn't run yet. This + mainmenu gating on the same state = exactly one owner, no
-- race when GameOver and RoundOver arrive together (the last/only player dying).
RunService.Heartbeat:Connect(function(dt)
    if clientPlay.get() ~= "spectating" then return end
    local camera = workspace.CurrentCamera
    camera.CameraType = Enum.CameraType.Scriptable

    local root = if followTarget then rootOf(followTarget) else nil
    if followTarget and not root then -- target died/left → drop back to the free cam
        followTarget = nil
        refreshLabel()
    end

    if root then
        local p = root.Position
        local eye = p + Vector3.new(0, 16, 22)
        camera.CFrame = CFrame.lookAt(eye, p + Vector3.new(0, 4, 0))
        aimFromTo(eye, p + Vector3.new(0, 4, 0)) -- keep free cam synced → seamless when you leave follow
    else
        if looking then
            local d = UserInputService:GetMouseDelta()
            yaw -= d.X * LOOK_SENS
            pitch = math.clamp(pitch - d.Y * LOOK_SENS, -1.45, 1.45)
        end
        local rot = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
        local cf = CFrame.new(specPos) * rot
        local v = Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then v += cf.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then v -= cf.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then v += cf.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then v -= cf.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.E) or UserInputService:IsKeyDown(Enum.KeyCode.Space) then v += Vector3.yAxis end
        if UserInputService:IsKeyDown(Enum.KeyCode.Q) or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then v -= Vector3.yAxis end
        if v.Magnitude > 0 then specPos += v.Unit * FLY_SPEED * dt end
        camera.CFrame = CFrame.new(specPos) * rot
    end
end)

-- ── Round events ──────────────────────────────────────────────────────────────────
blink.GameOver.On(function(msg)
    local t = math.floor(msg.time)
    info.Text = string.format("Survived  %s      •      Level %d", Format.format_to_electronic_time(t), msg.level)
    followTarget = nil
    aimFromTo(WATCH_EYE, center) -- start the free cam at the battlefield overview
    refreshLabel()
    spectating = true
    gui.Enabled = true
    clientPlay.set("spectating") -- hide the gameplay HUD + skill button while dead
end)

-- Round over → stop spectating, release the camera + mouse (mainmenu re-shows the menu).
blink.RoundOver.On(function()
    spectating = false
    gui.Enabled = false
    stopLook()
end)

return 0
