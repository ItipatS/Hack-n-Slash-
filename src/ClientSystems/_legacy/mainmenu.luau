-- ClientSystems/mainmenu.luau
-- Start screen. The world is idle until you press PLAY (waves don't spawn server-side until the
-- first Play — see SpawnMob.running), so you're safe at the menu. PLAY fires the Restart event:
-- the server JOINS you into the live round if one is running, else starts a fresh one. The menu
-- also RE-SHOWS when a round ends (RoundOver) so a ghost who was spectating can Play the next one.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")

local std   = ReplicatedStorage.std
local blink = require(std:WaitForChild("ClientNet"))
local clientPlay = require(std:WaitForChild("clientPlay"))
local clientState = require(std:WaitForChild("clientState"))
local Config = require(std:WaitForChild("config"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "MainMenu"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 20 -- above the GameOver screen (10)
gui.Enabled = true
gui.Parent = playerGui

local dim = Instance.new("Frame")
dim.Size = UDim2.new(1, 0, 1, 0)
dim.BackgroundColor3 = Color3.fromRGB(8, 10, 16)
dim.BackgroundTransparency = 0.4 -- semi-transparent so the orbiting map shows behind the menu
dim.BorderSizePixel = 0
dim.Parent = gui

local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.new(0.5, 0, 0.32, 0)
title.Size = UDim2.new(0, 700, 0, 80)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack
title.TextSize = 60
title.TextColor3 = Color3.fromRGB(150, 255, 170)
title.TextStrokeTransparency = 0.5
title.Text = "WHATEVER HORDE"
title.Parent = gui

local subtitle = Instance.new("TextLabel")
subtitle.AnchorPoint = Vector2.new(0.5, 0.5)
subtitle.Position = UDim2.new(0.5, 0, 0.32, 56)
subtitle.Size = UDim2.new(0, 700, 0, 30)
subtitle.BackgroundTransparency = 1
subtitle.Font = Enum.Font.Gotham
subtitle.TextSize = 20
subtitle.TextColor3 = Color3.fromRGB(190, 200, 210)
subtitle.Text = "Survive the waves. Pets fight for you."
subtitle.Parent = gui

local btn = Instance.new("TextButton")
btn.AnchorPoint = Vector2.new(0.5, 0.5)
btn.Position = UDim2.new(0.5, 0, 0.475, 0)
btn.Size = UDim2.new(0, 240, 0, 60)
btn.BackgroundColor3 = Color3.fromRGB(70, 150, 90)
btn.Font = Enum.Font.GothamBold
btn.TextSize = 26
btn.TextColor3 = Color3.new(1, 1, 1)
btn.Text = "▶  PLAY"
btn.Parent = gui
Instance.new("UICorner").Parent = btn

-- ── Switch between the showcase place and the real game (TeleportService) ─────────
-- Same codebase, two published places; config auto-detects which one we're in (Config.Places).
local switchBtn = Instance.new("TextButton")
switchBtn.AnchorPoint = Vector2.new(0.5, 0.5)
switchBtn.Position = UDim2.new(0.5, 0, 0.675, 0)
switchBtn.Size = UDim2.new(0, 320, 0, 40)
switchBtn.BackgroundColor3 = Color3.fromRGB(45, 55, 75)
switchBtn.Font = Enum.Font.GothamBold
switchBtn.TextSize = 18
switchBtn.TextColor3 = Color3.fromRGB(220, 230, 245)
switchBtn.Text = if Config.Places.IS_SHOWCASE then "🎮  Play the Real Game  →" else "🎬  See the 1000-Mob Showcase  →"
switchBtn.Parent = gui
Instance.new("UICorner").Parent = switchBtn

local switchCaption = Instance.new("TextLabel")
switchCaption.AnchorPoint = Vector2.new(0.5, 0.5)
switchCaption.Position = UDim2.new(0.5, 0, 0.625, 0)
switchCaption.Size = UDim2.new(0, 620, 0, 20)
switchCaption.BackgroundTransparency = 1
switchCaption.Font = Enum.Font.Gotham
switchCaption.TextSize = 14
switchCaption.TextColor3 = Color3.fromRGB(150, 160, 175)
switchCaption.Text = if Config.Places.IS_SHOWCASE
    then "Showcase: ~1000 server-authoritative mobs, invincible, FPS shown — no lag."
    else "Curious about scale? The showcase runs ~1000 mobs with the FPS overlay — no lag."
switchCaption.Parent = gui

local teleporting = false
switchBtn.Activated:Connect(function()
    if teleporting then return end
    teleporting = true
    switchBtn.Text = "Teleporting…"
    blink.SwitchPlace.Fire(1) -- server picks the target place + TeleportAsyncs us (safe cross-place path)
end)

-- persisted best stats (from the DataStore profile)
local best = Instance.new("TextLabel")
best.AnchorPoint = Vector2.new(0.5, 0.5)
best.Position = UDim2.new(0.5, 0, 0.75, 0)
best.Size = UDim2.new(0, 700, 0, 26)
best.BackgroundTransparency = 1
best.Font = Enum.Font.GothamBold
best.TextSize = 18
best.TextColor3 = Color3.fromRGB(255, 215, 110)
best.Text = ""
best.Parent = gui

clientState.onProfile(function(p)
    local m, s = p.bestTime // 60, p.bestTime % 60
    best.Text = string.format(
        "⛁ %d Tix      Best: Wave %d  •  Lv %d  •  %d:%02d  •  %d kills  •  %d runs",
        p.tix, p.bestWave, p.bestLevel, m, s, p.totalKills, p.runs)
end)

local controls = Instance.new("TextLabel")
controls.AnchorPoint = Vector2.new(0.5, 0.5)
controls.Position = UDim2.new(0.5, 0, 0.85, 0)
controls.Size = UDim2.new(0, 700, 0, 30)
controls.BackgroundTransparency = 1
controls.Font = Enum.Font.GothamMedium
controls.TextSize = 18
controls.TextColor3 = Color3.fromRGB(170, 180, 195)
controls.Text = if UserInputService.TouchEnabled and not UserInputService.MouseEnabled
    then "Move: left stick   •   Aim: right stick   •   Skills: on-screen buttons"
    else "Move: WASD   •   Aim: Mouse   •   Skills: Q "
controls.Parent = gui

-- ── Cinematic camera: slow orbit around the MAP MODEL while at the menu ─────────────
-- Frame from a MANUAL AABB of workspace.Map's parts (its GetBoundingBox is degenerate, and the
-- pathfinding waypoints have far outliers that framed it too wide / sky-facing).
local center, orbitR, orbitH = Vector3.new(0, 30, 0), 240, 120
local map = workspace:FindFirstChild("Map") or workspace:WaitForChild("Map", 5)
if map then
    local minv, maxv, n = Vector3.new(1e9, 1e9, 1e9), Vector3.new(-1e9, -1e9, -1e9), 0
    for _, d in map:GetDescendants() do
        if d:IsA("BasePart") then
            n += 1
            local p = d.Position
            minv, maxv = minv:Min(p), maxv:Max(p)
        end
    end
    if n > 0 then
        center = (minv + maxv) * 0.5
        local span = math.max(maxv.X - minv.X, maxv.Z - minv.Z)
        orbitR = span * 0.7 + 20  -- close in so the map fills the shot
        orbitH = span * 0.7 + 30  -- high enough for a steep ~45° downward look (map, not sky)
    end
end

local started = false
local angle = 0
local handingOver = false -- true during PLAY until the body warps in → keep orbiting over the void

-- Slow cinematic ORBIT around the map. ONE persistent Heartbeat loop; clientPlay is the single camera
-- ARBITER, so this drives the camera ONLY at the menu (or briefly during the PLAY→warp handover) and
-- can never fight gameover's spectate loop (which gates on the same state). Heartbeat (not
-- RenderStepped) keeps it running when idle; re-asserts Scriptable each frame since CurrentCamera can
-- be replaced on spawn.
RunService.Heartbeat:Connect(function(dt)
    local state = clientPlay.get()
    if not (state == "menu" or (state == "playing" and handingOver)) then return end
    angle += dt * 0.08 -- slow rotation
    local camera = workspace.CurrentCamera
    camera.CameraType = Enum.CameraType.Scriptable
    local eye = center + Vector3.new(math.cos(angle) * orbitR, orbitH, math.sin(angle) * orbitR)
    camera.CFrame = CFrame.lookAt(eye, center)
end)

-- Hand the camera to the live character. CRITICAL: bind CameraSubject explicitly — the orbit left the
-- camera Scriptable since join, so the engine never auto-bound the Humanoid; flipping to Custom alone
-- would leave it stuck at the last orbit CFrame with nothing to follow.
local function handCameraToCharacter()
    local char = player.Character
    local hum = char and (char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 3))
    local cam = workspace.CurrentCamera
    if hum then cam.CameraSubject = hum :: Humanoid end
    cam.CameraType = Enum.CameraType.Custom
end

-- Re-enter the menu (on join, and again when a round ends so a freed ghost can Play the next one).
local function showMenu()
    started = false
    handingOver = false
    gui.Enabled = true
    clientPlay.set("menu") -- loadout usable, HUD hidden; the orbit loop drives the camera off this state
end

local function play()
    if started then return end
    started = true
    gui.Enabled = false
    handingOver = true        -- keep the orbit alive through the warp-in below
    clientPlay.set("playing") -- show the gameplay HUD + skill button, lock the loadout
    blink.Restart.Fire(1) -- starts a fresh round, OR joins the one in progress (server decides)
    -- KEEP the orbit until the server warps our (parked, anchored) body into the arena — only then
    -- hand the camera to the character. Otherwise it would snap to the lobby body off in the void.
    -- Detect arrival by the root un-anchoring (warp-in) or a fresh body (the post-death reload). If we
    -- die / the round ends mid-handover, bail WITHOUT grabbing the camera (state left "playing").
    task.spawn(function()
        local startChar = player.Character
        for _ = 1, 600 do -- ~10s safety cap
            if clientPlay.get() ~= "playing" then return end -- state changed under us → don't touch the camera
            local char = player.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if (hrp and not (hrp :: BasePart).Anchored) or (char and char ~= startChar) then break end
            RunService.Heartbeat:Wait()
        end
        if clientPlay.get() ~= "playing" then return end
        handingOver = false       -- stop the orbit loop driving, THEN bind Custom to the character
        handCameraToCharacter()
    end)
end

btn.Activated:Connect(play)
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe or not gui.Enabled then return end
    if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.Space then play() end
end)

-- Round ended on the server → ghosts are freed; come back to the menu so PLAY works again.
blink.RoundOver.On(function() showMenu() end)

-- clientPlay defaults to "menu", so the persistent orbit loop above already drives the camera on join.
return 0
