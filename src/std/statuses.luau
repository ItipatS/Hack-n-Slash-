-- std/statuses.luau
-- The ONE explicit place mob buffs/debuffs live. Combat APPLIES effects through this module (never
-- world:set the raw component itself); `tick(now)` is the single owner of their lifecycle — it expires
-- finished effects and folds the active ones into a DERIVED movement multiplier (`SpeedMul`). The horde
-- integrator reads ONLY `SpeedMul` (a plain scalar), so movement code never interprets a debuff: it just
-- multiplies. A "slow" (factor<1) and a future "haste" (factor>1) flow through the exact same path.
--
-- Adding a new effect: give it (a) a component in components.luau and (b) a branch in `tick`'s aggregation.
--!optimize 2
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local std   = ReplicatedStorage.std
local world = require(std.world)
local cts   = require(std.components)

local Slow     = cts.Slow     -- raw effect {factor, untilT}
local SpeedMul = cts.SpeedMul -- derived aggregate (absent = normal speed)

local M = {}

-- Apply / refresh a movement-speed effect on a mob. factor<1 slows, >1 hastes; expires at `untilT`.
-- Re-applying just refreshes (combat calls this every hazard/beam tick for mobs still in the zone).
-- Only writes the raw effect; the derived SpeedMul is produced by tick() — the single source of truth.
function M.slow(e: number, factor: number, untilT: number)
    world:set(e, Slow, { factor = factor, untilT = untilT })
end

-- ── Per-tick resolve ──────────────────────────────────────────────────────────
-- Only walks entities that actually carry an effect (the few inside a hazard), so it's cheap at ~1k mobs.
-- jecs rule: never add/remove a queried component on an entity mid-iteration — collect, then apply.
-- M.tick never yields, so every entity the query yielded is still alive when we mutate below.
local effectQuery = world:query(Slow):cached()
local toClear: { number } = {}        -- entities whose effect ended (drop Slow + SpeedMul)
local toSet:   { number } = {}        -- flattened (entity, mult) pairs to write SpeedMul

function M.tick(now: number)
    table.clear(toClear)
    table.clear(toSet)

    for e, slow in effectQuery do
        if now >= slow.untilT then
            toClear[#toClear + 1] = e
        else
            -- aggregate: only Slow affects movement today, so the multiplier IS its factor. When a second
            -- movement effect lands, multiply the active factors here instead of assigning.
            toSet[#toSet + 1] = e
            toSet[#toSet + 1] = slow.factor
        end
    end

    for _, e in toClear do
        world:remove(e, Slow)
        if world:has(e, SpeedMul) then world:remove(e, SpeedMul) end -- may never have been set (applied+expired in one gap)
    end
    for i = 1, #toSet, 2 do
        world:set(toSet[i], SpeedMul, toSet[i + 1])
    end
end

return M
