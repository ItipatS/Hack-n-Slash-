-- ServerScriptService/navbake_test.server.luau
-- STUDIO dev tool (step 1b verification): bake the navmesh from workspace.Map and visualize it.
-- Gated by Config.Debug.NAV_BAKE_TEST (off by default) so normal playtests aren't slowed by the bake
-- and it never runs in a published place. Flip the flag true in std/config.luau, press Play, look at
-- the green/yellow node field in workspace.NavmeshDebug, then flip it back off.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local Config = require(ReplicatedStorage.std.config)
if not RunService:IsStudio() or not Config.Debug.NAV_BAKE_TEST then return end

local NavBake  = require(ReplicatedStorage.std.NavBake)
local NavDebug = require(ReplicatedStorage.std.NavDebug)

Workspace:WaitForChild("Map") -- ensure the geometry is synced before baking

-- "won't-bake" hunt: name the exact stage that rejects specific parts. Runs even with USE_NAVMESH on
-- (it's just a few casts), so the verdict prints whether or not the full test bake below runs.
for _, name in { "Bugg1", "Bugg2" } do
    NavBake.diagnose(name)
end

-- when USE_NAVMESH is on, Nav.init already baked + rendered the live graph — don't double the heavy bake
if Config.Debug.USE_NAVMESH then return end

local region = NavBake.regionFromMap()
print(("[NavBakeTest] region center=%s size=%s"):format(tostring(region.cframe.Position), tostring(region.size)))

local navmesh = NavBake.connect(NavBake.bake({ bakeRegion = region, gridSpacing = 2 }))
print(("[NavBakeTest] baked %d nodes in %.3fs (spacing %d)")
    :format(navmesh.metadata.nodeCount, navmesh.metadata.bakeTime, navmesh.metadata.spacing))

local folder = NavDebug.Show(navmesh) -- coarse auto-strided overview (ShowEdges() / Show(navmesh,1) opt-in)
print(("[NavBakeTest] visualized — workspace.NavmeshDebug (%d tiles of %d nodes)")
    :format(#folder:GetChildren(), navmesh.metadata.nodeCount))
