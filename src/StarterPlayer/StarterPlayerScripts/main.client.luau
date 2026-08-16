local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- WAIT for the server to finish booting before we init ANY client system. The server creates the Blink
-- remotes + server-side instances during its boot and only then parents `ServerReady`. Without this gate
-- the client (which can start before the server) races a half-built server — a system fires/listens on a
-- remote that doesn't exist yet, or reads an instance that isn't there. Server tells us; we don't guess.
-- Poll instead of WaitForChild so a slow server boot doesn't trip the 5s "Infinite yield possible"
-- warning — the client IS meant to wait here; that's not an error.
if not ReplicatedStorage:FindFirstChild("ServerReady") then
    repeat task.wait(0.1) until ReplicatedStorage:FindFirstChild("ServerReady")
end

-- (was CHRONO — REMOVED; see main.server for the full why.) Mobs moved to our own Blink dense-slot lane,
-- then Roblox Server Authority (Jul 2026) took over player replication natively — NextGenerationReplication
-- + built-in client prediction/rollback. Chrono had no job left, and its NATIVE_WITH_LOCK character locker
-- actively fights the server-authoritative character (symptom: the character can't move).

local start = require(ReplicatedStorage.std.start)
local systems = ReplicatedStorage:WaitForChild("ClientSystems")
start(systems:GetChildren())
