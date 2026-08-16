-- ServerScriptService/main.server.luau
-- Explicit server BOOT ORDER. Each shared dependency is fully resolved before the next, so systems
-- never race a half-ready singleton. Order: packages -> navmesh -> framework -> game systems.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Each stage prints so the boot is OBSERVABLE in the Output — if it ever stalls, the last [boot] line
-- says exactly where (vs a silent freeze that looks like "nothing initialized").
local bootT0 = os.clock()
local function boot(msg: string) print(("[boot +%.1fs] %s"):format(os.clock() - bootT0, msg)) end

-- 1) PACKAGES — wait for the wally tree so anything that requires a package (profilestore, bytenet,
--    jecs, …) finds it. (Server has the tree at boot; WaitForChild is the explicit gate.)
boot("1/5 waiting for Packages …")
ReplicatedStorage:WaitForChild("Packages")
boot("1/5 Packages ready")

-- 2) NAVMESH — resolve the pathfinding graph. With USE_NAVMESH on this BAKES from workspace.Map and
--    yields; doing it here means the graph is ready before the horde (or any system) loads, so mobs
--    always have a navmesh to path on. No-op'd fast when the flag is off (uses hand-painted PathData).
boot("2/5 navmesh (bakes when USE_NAVMESH) …")
require(ReplicatedStorage.std.Nav).init()

-- 3) FRAMEWORK — initialize the imported data layer (the require runs Data._init(), which creates the
--    ProfileStore store) so a player profile load can never race the store's creation. (Data-layer
--    scope only; if the full framework is ever adopted, Framework.Initialize() would go here too.)
boot("3/6 framework data layer …")
require(ReplicatedStorage.Framework.Data)

-- 4) (was CHRONO — REMOVED.) Chrono is gone from the project entirely.
--    Two things killed it, in order:
--      • MOBS left first — Chrono's general-purpose 16 bytes/mob @ flat 20Hz didn't scale to the horde
--        target; they now ride our own Blink dense-slot i8 lane (~3 bytes/mob). See systems/mobs.
--      • PLAYERS left second — Roblox shipped Server Authority (full release, Jul 2026). Chrono existed to
--        fix REPLICATION unpredictability (mushy default 20Hz + fixed mobile interp); the engine now does
--        that natively via NextGenerationReplication, plus client prediction + rollback for free — the
--        "whole second hard project" CLAUDE.md deliberately skipped. That left Chrono with NO job.
--    It was also actively HARMFUL: its NATIVE_WITH_LOCK mode welds the character under a Camera to
--    suppress Roblox replication, which fights the server-authoritative character (symptom: can't move).
--    Enabled via Workspace.AuthorityMode = "Server" (auto-sets NextGenerationReplication,
--    PlayerScriptsUseInputActionSystem, SignalBehavior=Deferred, StreamingEnabled, UseFixedSimulation).

-- 5) SYSTEMS — dependencies are ready; start the game loop. This also requires every system module,
--    which is where the Blink remotes (ServerNet) and any server-built ReplicatedStorage instances get
--    created — so once start() returns, everything a client depends on EXISTS.
boot("5/6 starting systems …")
local start = require(ReplicatedStorage.std.start)
start(script.Parent:WaitForChild("systems"):GetChildren())

-- 5) SIGNAL CLIENTS — only now is the server fully built (remotes + instances + systems). Clients gate
--    their own init on this flag so they never race a half-built server (the client-starts-first bug:
--    a client touching a remote/instance the server hasn't created yet). A PERSISTENT instance, so a
--    late joiner sees it immediately rather than needing a re-fired event.
local ready = Instance.new("BoolValue")
ready.Name = "ServerReady"
ready.Value = true
ready.Parent = ReplicatedStorage
boot("6/6 ServerReady set → clients may init")
