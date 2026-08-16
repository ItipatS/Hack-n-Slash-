-- std/mob_motion.luau
-- Shared zombie movement math, run IDENTICALLY on server and client so the two
-- never diverge (no teleport corrections). Two helpers:
--   • edgePos  — position along a graph edge at a given elapsed time. Ramps/flat
--     follow the node line (smooth on wedges); DROP edges (one-way cliffs) fall
--     under gravity. This is graph-faithful: a zombie only ever travels along a
--     legal edge, so it can never climb a one-way-down edge.
--   • Constants — gravity, step limits, contact radius — used by both ends.
-- Positions here are GROUND LEVEL (at the waypoint Y, which sits ~0.5 above the
-- floor); the renderer adds the foot→HRP offset.
--!optimize 2
--!native
--!strict

local M = {}

M.EPS       = 1e-4
M.GRAVITY   = 90    -- studs/s^2 (fall off ledges)
M.STEP_DOWN = 3     -- an edge dropping more than this is treated as a FALL
M.STEP_UP   = 4     -- chase may climb at most this abruptly; one-way cliffs are ≥9
                    -- so this blocks every cliff-climb but still allows steps/slopes
M.CONTACT   = 2.5   -- chase stops translating this close to the target

-- Position along edge F→T at `elapsed` seconds, walking the horizontal span at
-- `speed`. Returns (groundPos, horizontalFacing, arrived).
function M.edgePos(F: Vector3, T: Vector3, elapsed: number, speed: number): (Vector3, Vector3, boolean)
    local hx, hz = T.X - F.X, T.Z - F.Z
    local horizDist = math.sqrt(hx * hx + hz * hz)
    local tHoriz = if speed > 0 and horizDist > M.EPS then horizDist / speed else 0
    local p = if tHoriz > 0 then math.min(elapsed / tHoriz, 1) else 1

    local x = F.X + hx * p
    local z = F.Z + hz * p

    local drop = F.Y - T.Y -- > 0 means going down
    local y: number
    local arrived: boolean
    if drop > M.STEP_DOWN then
        -- DROP edge: step off and fall under gravity, landing at T.Y.
        local tFall = math.sqrt(2 * drop / M.GRAVITY)
        local te = if elapsed < tFall then elapsed else tFall
        local yf = F.Y - 0.5 * M.GRAVITY * te * te
        y = if yf > T.Y then yf else T.Y
        arrived = (p >= 1) and (elapsed >= tFall)
    else
        -- ramp / flat / step-up: follow the node line
        y = F.Y + (T.Y - F.Y) * p
        arrived = p >= 1
    end

    return Vector3.new(x, y, z), Vector3.new(hx, 0, hz), arrived
end

return M
