-- ServerScriptService/systems/statuses.luau
-- Schedules the mob status-effect resolve. Runs in AIStateMachine — i.e. JUST BEFORE AIMovement — so the
-- derived SpeedMul that horde reads is fresh for this frame's integration. All the logic lives in
-- std/statuses (combat applies effects there; this only ticks expiry + the derived multiplier).
--!optimize 2
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local std = ReplicatedStorage.std

local scheduler = require(std.scheduler)
local phases    = require(std.phases)
local Statuses  = require(std.statuses)

scheduler.SYSTEM(function()
    Statuses.tick(workspace:GetServerTimeNow())
end, phases.AIStateMachine)

return 0
