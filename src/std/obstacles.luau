-- std/obstacles.luau
-- Movement-BLOCKING line segments (penguin's Glacier Wall). Combat ADDs walls with an expiry;
-- the horde integrator REJECTS any move that would cross one, so mobs pile up against the face.
-- Mobs don't use Roblox physics (server-simulated positions), so blocking must live in the
-- movement sim — an anchored Part could never stop them. Players are NOT blocked (you can step
-- through your own wall; the horde can't follow).
--!optimize 2
--!strict

local M = {}

type Seg = {
    x1: number, z1: number, x2: number, z2: number, untilT: number,
    minX: number, maxX: number, minZ: number, maxZ: number, -- AABB pre-reject
}
local segs: { Seg } = {}

function M.add(x1: number, z1: number, x2: number, z2: number, untilT: number)
    segs[#segs + 1] = {
        x1 = x1, z1 = z1, x2 = x2, z2 = z2, untilT = untilT,
        minX = math.min(x1, x2) - 1, maxX = math.max(x1, x2) + 1,
        minZ = math.min(z1, z2) - 1, maxZ = math.max(z1, z2) + 1,
    }
end

function M.any(): boolean
    return #segs > 0
end

-- drop expired walls — call once per movement tick (cheap; the list is a handful at most)
function M.sweep(now: number)
    local write = 1
    for i = 1, #segs do
        local s = segs[i]
        if now < s.untilT then segs[write] = s; write += 1 end
    end
    for i = #segs, write, -1 do segs[i] = nil end
end

function M.clear()
    table.clear(segs)
end

local function side(ax: number, az: number, bx: number, bz: number, px: number, pz: number): number
    return (bx - ax) * (pz - az) - (bz - az) * (px - ax)
end

-- does the XZ move (fx,fz)→(tx,tz) cross any wall? Proper 2D segment-segment intersection with
-- an AABB pre-reject. With ≤ a couple of live walls this is ~free even at 1000 mobs/tick.
function M.blocked(fx: number, fz: number, tx: number, tz: number): boolean
    for i = 1, #segs do
        local s = segs[i]
        if math.max(fx, tx) < s.minX or math.min(fx, tx) > s.maxX
            or math.max(fz, tz) < s.minZ or math.min(fz, tz) > s.maxZ then
            continue
        end
        local d1 = side(s.x1, s.z1, s.x2, s.z2, fx, fz)
        local d2 = side(s.x1, s.z1, s.x2, s.z2, tx, tz)
        local d3 = side(fx, fz, tx, tz, s.x1, s.z1)
        local d4 = side(fx, fz, tx, tz, s.x2, s.z2)
        if ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0))
            and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0)) then
            return true
        end
    end
    return false
end

return M
