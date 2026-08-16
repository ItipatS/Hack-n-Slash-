-- ClientSystems/_spike_render10k.luau
-- THROWAWAY Phase-0 render-ceiling spike. Proves how many cheap anchored MeshParts we can
-- draw + re-CFrame every frame (the real cost of a 10k horde). Standalone: does NOT touch
-- the server, ECS, or syncMobs. Set ENABLED=false (or delete this file) to disable.
--
-- Live control over MCP / command bar:
--   workspace:SetAttribute("spikeTarget", 10000)   -- ramp the active part count
--   workspace:GetAttribute("spikeFPS")             -- rolling avg FPS
--   workspace:GetAttribute("spikeN")               -- parts actually being moved
--!optimize 2
--!native

-- Phase-0 gate PASSED (10k MeshParts: render is free; cost is applying transforms each
-- frame → solved by LOD-culling the moved subset). Neutralized; flip ENABLED=true to replay.
local ENABLED = false
if not ENABLED then return 0 end

local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MAX            = 15000   -- hard pool ceiling
local GROW_PER_FRAME = 1500    -- ramp in over a few frames so the grow hitch doesn't skew FPS
local SPACING        = 6       -- studs between grid homes
local START_TARGET   = 2000    -- initial active count

-- ── Visual template: a small meshed part (the Zombie Head mesh, face decal stripped),
-- representative of the MeshPart we'll pool for real. Falls back to a Ball if absent.
local function makeTemplate(): BasePart
    local zombie = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Zombie")
    local head = zombie:FindFirstChild("Head")
    local p: BasePart
    if head and head:IsA("BasePart") then
        p = head:Clone()
        for _, c in p:GetChildren() do
            if not c:IsA("DataModelMesh") then c:Destroy() end -- keep the mesh, drop face decal etc.
        end
    else
        p = Instance.new("Part")
        p.Shape = Enum.PartType.Ball
        p.Size = Vector3.new(2, 2, 2)
    end
    p.Anchored   = true
    p.CanCollide = false
    p.CanQuery   = false
    p.CanTouch   = false
    p.CastShadow = false
    p.Material   = Enum.Material.SmoothPlastic
    return p
end

local template = makeTemplate()

local folder = Instance.new("Folder")
folder.Name = "SpikeMobs"
folder.Parent = workspace

local active: { BasePart } = {} -- shown, moved each frame
local free:   { BasePart } = {} -- recycled, parked out of workspace

-- reused per-frame buffers (no allocation in steady state)
local cfs:   { CFrame } = {}    -- parallel CFrame list for BulkMoveTo
local homeX: { number } = {}    -- grid home X/Z, recomputed only when the count changes
local homeZ: { number } = {}
local lastN = -1

-- per-part phase offset so the field doesn't pulse in unison
local seed = table.create(MAX)
for i = 1, MAX do seed[i] = ((i * 0.61803398875) % 1) * 6.2831853 end

workspace:SetAttribute("spikeTarget", START_TARGET)

local fpsAcc, fpsCount, fpsTimer = 0, 0, 0
local t = 0
local moveAcc = 0

RunService.PreRender:Connect(function(dt)
    t += dt
    local target = math.clamp(workspace:GetAttribute("spikeTarget") or START_TARGET, 0, MAX)

    -- grow toward target (rate-limited), or shrink instantly
    local grown = 0
    while #active < target and grown < GROW_PER_FRAME do
        local p = table.remove(free) or template:Clone()
        p.Parent = folder
        active[#active + 1] = p
        grown += 1
    end
    while #active > target do
        local i = #active
        local p = active[i]
        active[i] = nil
        p.Parent = nil
        free[#free + 1] = p
    end

    -- move every active part via BulkMoveTo (one C call, not n property writes)
    local n = #active
    local hz = workspace:GetAttribute("spikeMoveHz") or 60 -- throttle the move rate (visual stays smooth-ish via low-Hz + many parts)
    moveAcc += dt
    local doMove = (workspace:GetAttribute("spikeMove") ~= false) and (moveAcc >= 1 / hz)
    if doMove then
    moveAcc = 0
    if n ~= lastN then
        -- recompute grid homes only when the count changed
        local side = math.max(1, math.ceil(math.sqrt(n)))
        local half = side * 0.5
        for i = 1, n do
            local gx = (i - 1) % side
            homeX[i] = (gx - half) * SPACING
            homeZ[i] = ((i - 1 - gx) / side - half) * SPACING
        end
        lastN = n
    end
    for i = 1, n do
        local s = seed[i]
        cfs[i] = CFrame.new(
            homeX[i] + math.cos(t + s) * 2,
            3 + math.sin(t * 2 + s) * 0.5,
            homeZ[i] + math.sin(t + s) * 2
        )
    end
    for i = n + 1, #cfs do cfs[i] = nil end
    if workspace:GetAttribute("spikeBulk") ~= false then -- toggle to isolate Luau build vs BulkMoveTo
        workspace:BulkMoveTo(active, cfs, Enum.BulkMoveMode.FireCFrameChanged)
    end
    end

    -- rolling FPS, published twice a second
    fpsAcc += 1 / dt
    fpsCount += 1
    fpsTimer += dt
    if fpsTimer >= 0.5 then
        workspace:SetAttribute("spikeFPS", math.floor(fpsAcc / fpsCount + 0.5))
        workspace:SetAttribute("spikeN", n)
        fpsAcc, fpsCount, fpsTimer = 0, 0, 0
    end
end)

return 0
