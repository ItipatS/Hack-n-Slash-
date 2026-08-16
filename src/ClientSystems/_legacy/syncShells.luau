-- ClientSystems/syncShells.luau
-- Orbit visuals for EVERY equipped orbit-kind weapon (turtle shells, phoenix embers, future
-- orbiters). The server damages at rotating points using the synced clock (combat fireStep
-- "orbit": count = w.shots, orbitR = 7 + w.radius, baseA = now * 2.2); we rebuild the SAME
-- weapon instance from {id, level} (Registry.make + applyLevelUp — deterministic) and orbit the
-- visuals with the same clock/speed, so they line up with where the hits land. Purely cosmetic.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local clientState = require(std:WaitForChild("clientState"))
local Registry  = require(std:WaitForChild("petRegistry"))

local Animals = ReplicatedStorage:WaitForChild("Animals")
local player  = Players.LocalPlayer

local SPIN = 2.2 -- matches combat fireStep "orbit" baseA = now * 2.2

local folder = Instance.new("Folder")
folder.Name = "Orbiters"
folder.Parent = workspace

-- one entry per equipped orbit weapon: its parts + the orbit params the server uses
type Orbit = { parts: { BasePart }, count: number, orbitR: number }
local orbits: { Orbit } = {}

-- rebuild the effective weapon instance from id + level (same pure functions the server uses)
local function buildWeapon(id: string, level: number): any?
    local w = Registry.make(id)
    if not w then return nil end
    for _ = 2, level do Registry.applyLevelUp(w) end
    return w
end

local function makeOrbiter(id: string): BasePart
    local p: BasePart? = nil
    if id == "turtle" then -- turtle keeps its shell mesh
        local src = Animals:FindFirstChild(Registry.meshName("turtle"))
        if src and src:IsA("BasePart") then
            local shell = src:Clone()
            shell.Size = src.Size * 0.5
            p = shell
        end
    end
    if not p then -- generic orbiter: a glowing orb in the pet's color (phoenix = fire ember)
        local def = Registry.pets[id]
        local orb = Instance.new("Part")
        orb.Shape = Enum.PartType.Ball
        orb.Size = Vector3.new(1.8, 1.8, 1.8)
        orb.Material = Enum.Material.Neon
        orb.Color = (def and def.base.color) or Color3.fromRGB(255, 200, 120)
        orb.Transparency = 0.1
        p = orb
    end
    local part = p :: BasePart
    part.Anchored = true; part.CanCollide = false; part.CanQuery = false; part.CanTouch = false; part.CastShadow = false
    part.Parent = folder
    return part
end

local function rebuild(list: { { id: string, level: number } })
    for _, o in orbits do
        for _, pt in o.parts do pt:Destroy() end
    end
    table.clear(orbits)
    for _, entry in list do
        local def = Registry.pets[entry.id]
        if not (def and def.kind == "orbit") then continue end
        local w = buildWeapon(entry.id, entry.level)
        if not w then continue end
        local count = math.max(1, w.shots)
        local parts = {}
        for _ = 1, count do parts[#parts + 1] = makeOrbiter(entry.id) end
        orbits[#orbits + 1] = { parts = parts, count = count, orbitR = 7 + w.radius }
    end
end

clientState.onWeaponsFull(function(list)
    rebuild(list)
end)

local function step(_dt: number)
    if #orbits == 0 then return end
    local char = player.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local pos = (hrp :: BasePart).Position
    local baseA = workspace:GetServerTimeNow() * SPIN
    for _, o in orbits do
        for i, pt in o.parts do
            -- matches the server: a = baseA + (s / count) * 2π with s = 0..count-1
            local a = baseA + ((i - 1) / o.count) * (2 * math.pi)
            pt.CFrame = CFrame.new(pos.X + math.cos(a) * o.orbitR, pos.Y, pos.Z + math.sin(a) * o.orbitR)
                * CFrame.Angles(0, -a, 0)
        end
    end
end

scheduler.SYSTEM(step, phases.Heartbeat)
return 0
