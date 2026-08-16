-- ClientSystems/syncPet.luau
-- Renders one pet per equipped weapon, on a ring around the owner, all rotating to the cursor
-- aim. The local player's weapon list arrives via the Weapons event (each id → its animal
-- mesh); remote players just get a single axolotl. Also streams the local aim to the server.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))
local Pet       = require(std:WaitForChild("pet"))
local Config    = require(std:WaitForChild("config"))
local AimState  = require(std:WaitForChild("aimState"))
local Registry  = require(std:WaitForChild("petRegistry"))
local clientState = require(std:WaitForChild("clientState"))

local player = Players.LocalPlayer
local mouse  = player:GetMouse()

-- Where does aim come from? Touch → the on-screen stick (aimstick.luau writes AimState);
-- otherwise the mouse cursor. Mirrors the same check aimstick.luau uses to build itself.
local mode = Config.Controls.AIM_STICK
local USE_STICK = mode == "always"
    or (mode == "auto" and UserInputService.TouchEnabled and not UserInputService.MouseEnabled)

local folder = Instance.new("Folder")
folder.Name = "Pets"
folder.Parent = workspace

local Animals = ReplicatedStorage:WaitForChild("Animals")

-- pet body by id: the Animals mesh if it exists, else a CUBE in the pet's registry color — every
-- modelless pet is still tellable apart at a glance (and never the old anonymous pink ball)
local function makePart(id: string): BasePart
    local src = Animals:FindFirstChild(Registry.meshName(id))
    local p: BasePart
    if src and src:IsA("BasePart") then
        p = src:Clone()
    else
        local def = Registry.pets[id]
        p = Instance.new("Part")
        p.Size = Vector3.new(2, 2, 2)
        p.Color = (def and def.base.color) or Color3.fromRGB(255, 150, 200)
    end
    p.Anchored = true
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.CastShadow = false
    return p
end

-- floating "Name Lv.X" tag above a pet body
local function addLabel(pt: BasePart, id: string, level: number)
    local def = Registry.pets[id]
    local bb = Instance.new("BillboardGui")
    bb.Name = "PetTag"
    bb.Size = UDim2.fromOffset(120, 22)
    bb.StudsOffsetWorldSpace = Vector3.new(0, pt.Size.Y * 0.5 + 1.4, 0)
    bb.AlwaysOnTop = true
    bb.MaxDistance = 120
    local txt = Instance.new("TextLabel")
    txt.BackgroundTransparency = 1
    txt.Size = UDim2.fromScale(1, 1)
    txt.Font = Enum.Font.GothamBold
    txt.TextScaled = true
    txt.TextColor3 = Color3.new(1, 1, 1)
    txt.TextStrokeTransparency = 0.4
    txt.Text = ((def and def.name) or id) .. " Lv." .. level
    txt.Parent = bb
    bb.Parent = pt
end

-- local player's pets (one per weapon, aligned to localWeapons; levels feed the billboard tag)
local localWeapons: { { id: string, level: number } } = { { id = "axolotl", level = 1 } }
local localPets: { BasePart } = {}

local function rebuildLocalPets()
    for _, pt in localPets do pt:Destroy() end
    table.clear(localPets)
    for i, w in localWeapons do
        local pt = makePart(w.id)
        addLabel(pt, w.id, w.level)
        pt.Parent = folder
        localPets[i] = pt
    end
end
rebuildLocalPets()

clientState.onWeaponsFull(function(list)
    localWeapons = list
    rebuildLocalPets()
end)

local otherPets: { [Player]: BasePart } = {}

local BOB_FREQ, BOB_AMP, ROLL_AMP = 12, 0.5, 0.25
local sendAcc, SEND_DT = 0, 0.05

local function step(dt: number)
    local now = workspace:GetServerTimeNow()

    -- local player: aim + one pet per weapon on the ring
    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        for _, pt in localPets do if pt.Parent ~= folder then pt.Parent = folder end end -- show on spawn
        local facing
        if USE_STICK then
            facing = AimState.get() -- world-space aim from the mobile thumbstick
        else
            -- player → cursor target (3D): carries vertical pitch so the unicorn beam aims up/down (and
            -- at flying UFOs). Flat weapons use only its XZ on the server, which is now character-relative
            -- (aim AT the cursor target) rather than the camera ray — a wash-to-better for them.
            local hitDir = mouse.Hit.Position - (root :: BasePart).Position
            facing = if hitDir.Magnitude > 1e-3 then hitDir.Unit else Vector3.new(0, 0, -1)
        end
        sendAcc += dt
        if sendAcc >= SEND_DT then sendAcc = 0; blink.Aim.Fire(facing) end

        local vel = (root :: BasePart).AssemblyLinearVelocity
        local moving = (vel.X * vel.X + vel.Z * vel.Z) > 4
        local bob = if moving then math.sin(now * BOB_FREQ) * BOB_AMP else 0
        local roll = if moving then math.sin(now * BOB_FREQ) * ROLL_AMP else 0

        local n = #localPets
        for i, pt in localPets do
            local pos = Pet.slotPos((root :: BasePart).Position, i - 1, n) + Vector3.new(0, bob, 0)
            pt.CFrame = CFrame.lookAt(pos, pos + facing) * CFrame.Angles(0, 0, roll)
        end
    else
        -- no character (menu / dead): hide local pets so they don't float in the menu camera shot
        for _, pt in localPets do if pt.Parent then pt.Parent = nil end end
    end

    -- remote players: a single pet
    for _, plr in Players:GetPlayers() do
        if plr == player then continue end
        local c = plr.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")
        if not r then continue end
        local pt = otherPets[plr]
        if not pt then pt = makePart("axolotl"); pt.Parent = folder; otherPets[plr] = pt end
        local lv = (r :: BasePart).CFrame.LookVector
        local f = if lv.Magnitude > 1e-3 then lv.Unit else Vector3.new(0, 0, -1)
        local pos = Pet.pos((r :: BasePart).Position)
        pt.CFrame = CFrame.lookAt(pos, pos + f)
    end
end

Players.PlayerRemoving:Connect(function(plr)
    local pt = otherPets[plr]
    if pt then pt:Destroy(); otherPets[plr] = nil end
end)

scheduler.SYSTEM(step, phases.Heartbeat)
return 0
