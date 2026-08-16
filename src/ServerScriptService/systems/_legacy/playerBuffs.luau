-- ServerScriptService/systems/playerBuffs.luau
-- Schedules the player buff/modifier resolve. Runs in AIStateMachine — BEFORE AIMovement (ufo reads
-- PlayerMods for its damage) and Combat (combat's damage loop reads it) — so both see this frame's
-- resolved modifiers. All logic lives in std/playerBuffs; this only drives the tick.
--!optimize 2
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local std = ReplicatedStorage.std

local scheduler   = require(std.scheduler)
local phases      = require(std.phases)
local PlayerBuffs = require(std.playerBuffs)

scheduler.SYSTEM(function()
    PlayerBuffs.tick(workspace:GetServerTimeNow())
end, phases.AIStateMachine)

return 0
