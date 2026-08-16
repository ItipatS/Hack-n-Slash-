-- ReplicatedStorage/std/NodeGrid.luau
-- Spatial grid for O(1) average nearest-node lookup.
-- Auto-computes bounds from Waypoints at startup.
--!optimize 2
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local pathData = require(ReplicatedStorage.PathData)

local Waypoints: { [number]: { Vector3 } } = pathData.Waypoints

-- ── 1. Auto-compute world bounds ─────────────────────────────────────────────
local minX, minZ =  math.huge,  math.huge
local maxX, maxZ = -math.huge, -math.huge

for _, entry in Waypoints do
    local p = entry[1] :: Vector3
    if p.X < minX then minX = p.X end
    if p.X > maxX then maxX = p.X end
    if p.Z < minZ then minZ = p.Z end
    if p.Z > maxZ then maxZ = p.Z end
end

-- Pad by one cell so edge nodes never fall outside the grid
local CELL_SIZE = 60  -- ~2× node spacing, gives ~4 nodes/cell on average

minX -= CELL_SIZE
minZ -= CELL_SIZE
maxX += CELL_SIZE
maxZ += CELL_SIZE

local COLS = math.ceil((maxX - minX) / CELL_SIZE)
local ROWS = math.ceil((maxZ - minZ) / CELL_SIZE)

-- ── 2. Build grid ─────────────────────────────────────────────────────────────
-- grid[col][row] = { nodeID, ... }
local grid: { [number]: { [number]: { number } } } = {}

local function cellOf(x: number, z: number): (number, number)
    local col = math.clamp(math.floor((x - minX) / CELL_SIZE) + 1, 1, COLS)
    local row = math.clamp(math.floor((z - minZ) / CELL_SIZE) + 1, 1, ROWS)
    return col, row
end

for id, entry in Waypoints do
    local p = entry[1] :: Vector3
    local col, row = cellOf(p.X, p.Z)
    if not grid[col] then grid[col] = {} end
    if not grid[col][row] then grid[col][row] = {} end
    local cell = grid[col][row]
    cell[#cell + 1] = id
end

-- ── 3. Nearest-node lookup ───────────────────────────────────────────────────
-- Searches cells in expanding rings until at least one candidate is found,
-- then checks one extra ring to make sure we haven't missed a closer node
-- that straddles a cell boundary.

local NodeGrid = {}

function NodeGrid.nearest(pos: Vector3): number?
    local cx, cz = cellOf(pos.X, pos.Z)

    local bestID:   number? = nil
    local bestDist2 = math.huge

    local function scanCell(col: number, row: number)
        local column = grid[col]
        if not column then return end
        local cell = column[row]
        if not cell then return end
        for _, id in cell do
            local p = Waypoints[id][1] :: Vector3
            local dx = p.X - pos.X
            local dz = p.Z - pos.Z
            local d2 = dx * dx + dz * dz
            if d2 < bestDist2 then
                bestDist2 = d2
                bestID    = id
            end
        end
    end

    -- Expand rings until we find a hit, then scan one more ring for safety
    local ring = 0
    local foundRing = -1

    while ring <= math.max(COLS, ROWS) do
        -- scan the border of the square ring
        local r = ring
        for col = math.max(1, cx - r), math.min(COLS, cx + r) do
            scanCell(col, math.max(1, cz - r))
            if r > 0 then
                scanCell(col, math.min(ROWS, cz + r))
            end
        end
        for row = math.max(1, cz - r + 1), math.min(ROWS, cz + r - 1) do
            scanCell(math.max(1, cx - r), row)
            if r > 0 then
                scanCell(math.min(COLS, cx + r), row)
            end
        end

        if bestID ~= nil then
            if foundRing < 0 then
                foundRing = ring
            elseif ring >= foundRing + 1 then
                break  -- scanned one extra ring, done
            end
        end

        ring += 1
    end

    return bestID
end

return NodeGrid
