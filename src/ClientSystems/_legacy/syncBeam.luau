-- ClientSystems/syncBeam.luau
-- Renders the local player's unicorn ULT beam ("Taste the Rainbow"). On UltBeam(active=1) we draw a
-- thick rainbow beam from the character along the SAME aim the client streams to the server (mouse on
-- PC, aim stick on touch), so the visual matches the server's authoritative damage. Despawns after life.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")

local std      = ReplicatedStorage.std
local blink    = require(std:WaitForChild("ClientNet"))
local Config   = require(std:WaitForChild("config"))
local AimState = require(std:WaitForChild("aimState"))

local player = Players.LocalPlayer
local mouse  = player:GetMouse()

local mode = Config.Controls.AIM_STICK
local USE_STICK = mode == "always"
    or (mode == "auto" and UserInputService.TouchEnabled and not UserInputService.MouseEnabled)

local function flat(v: Vector3): Vector3
    local f = Vector3.new(v.X, 0, v.Z)
    return if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, -1)
end

local function aimDir(hrp: BasePart): Vector3
    if USE_STICK then
        return flat(AimState.get()) -- mobile thumbstick is 2D → beam stays horizontal
    end
    -- 3D player→cursor (matches what syncPet streams + what the server damages along), so the visual
    -- tilt lines up with the authoritative hits.
    local v = mouse.Hit.Position - hrp.Position
    return if v.Magnitude > 1e-3 then v.Unit else Vector3.new(0, 0, -1)
end

local beam: BasePart? = nil
local until_ = 0
local width, length = 4, 80
local conn: RBXScriptConnection? = nil

local function stop()
    if beam then beam:Destroy(); beam = nil end
    if conn then conn:Disconnect(); conn = nil end
end

local function start()
    stop()
    local b = Instance.new("Part")
    b.Material = Enum.Material.Neon
    b.Transparency = 0.2
    b.Anchored = true; b.CanCollide = false; b.CanQuery = false; b.CanTouch = false; b.CastShadow = false
    b.Parent = workspace
    beam = b
    conn = RunService.RenderStepped:Connect(function()
        if os.clock() >= until_ then stop(); return end
        local char = player.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        local origin = (hrp :: BasePart).Position + Vector3.new(0, 1.5, 0)
        local dir = aimDir(hrp :: BasePart)
        local center = origin + dir * (length * 0.5)
        b.Size = Vector3.new(width * 2, width * 2, length)
        b.CFrame = CFrame.lookAt(center, center + dir)
        b.Color = Color3.fromHSV((os.clock() * 0.6) % 1, 0.7, 1) -- sweep the rainbow
    end)
end

blink.UltBeam.On(function(s)
    if s.active == 1 then
        width, length = s.width, s.length
        until_ = os.clock() + s.life
        start()
    else
        stop()
    end
end)

return 0
