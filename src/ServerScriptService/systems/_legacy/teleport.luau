-- ServerScriptService/systems/teleport.luau
-- Server-side place switching (showcase <-> real game). The menu fires SwitchPlace; the SERVER picks
-- the OTHER place from its own Config.Places and TeleportAsyncs the player. Server-side TeleportAsync is
-- the safe/robust path (vs a client TeleportService:Teleport, which is flaky cross-experience).
--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local TeleportService      = game:GetService("TeleportService")

local blink  = require(ServerScriptService.ServerNet)
local Config = require(ReplicatedStorage.std.config)

-- this place is one of the two; the switch always targets the other
local target = if Config.Places.IS_SHOWCASE then Config.Places.REAL else Config.Places.SHOWCASE

blink.SwitchPlace.On(function(plr)
    task.spawn(function() -- TeleportAsync yields
        local ok, err = pcall(function()
            TeleportService:TeleportAsync(target, { plr })
        end)
        if not ok then warn("[teleport] SwitchPlace failed:", err) end
    end)
end)

return 0
