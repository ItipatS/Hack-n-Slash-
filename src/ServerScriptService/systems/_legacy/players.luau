local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local std = ReplicatedStorage.std
local ref = require(std.ref)

local cts = require(std.components)
local world = require(std.world)
local PlayerState = require(std.playerState)
local Player = cts.Player
local Character = cts.Character

local conn = {}

-- Death is server-authoritative and FINAL until the round ends (combat.luau hooks Humanoid.Died).
-- So Roblox must NOT auto-respawn — a fall/void death would otherwise reset the body out from
-- under the spectate screen. We load EVERY body ourselves: a frozen lobby body on join, then
-- un-freeze it into play on Play (combat.warpIn).
Players.CharacterAutoLoads = false

-- A pre-Play body is spawned at the NORMAL spawn so StreamingEnabled targets the arena, THEN moved
-- to a hidden LOBBY just under the map centre — close enough to stay in streaming range (so the
-- arena still renders) but out of sight. Parking it thousands of studs out (the old bug) streamed
-- the whole arena OUT for that client → nothing rendered. The body is ANCHORED + inert: combat, the
-- horde, and the drop systems all gate on PlayerState.playing (false until Play). Loading it on join
-- (rather than no character) keeps the client warm. Play (warpIn) teleports it back to the spawn.
local function mapCentre(): Vector3
    local map = workspace:FindFirstChild("Map") -- server has the full DataModel at boot; nil = pivot prototype place
    local minv, maxv, n = Vector3.new(1e9, 1e9, 1e9), Vector3.new(-1e9, -1e9, -1e9), 0
    if map then
        for _, d in map:GetDescendants() do
            if d:IsA("BasePart") then n += 1; minv = minv:Min(d.Position); maxv = maxv:Max(d.Position) end
        end
    end
    return if n > 0 then (minv + maxv) * 0.5 else Vector3.new(0, 40, 0)
end
local LOBBY = CFrame.new(mapCentre() - Vector3.new(0, 120, 0)) -- under the map floor, still in range
local arenaSpawn: CFrame? = nil -- the real spawn (captured from the first load) → warpIn target

local function freeze(rig: Model)
    local hrp = rig:FindFirstChild("HumanoidRootPart") or rig:WaitForChild("HumanoidRootPart", 5)
    if not hrp then return end
    if not arenaSpawn then arenaSpawn = rig:GetPivot() end -- remember the normal spawn spot
    rig:PivotTo(LOBBY)                                     -- move the idle body out of sight
    ;(hrp :: BasePart).Anchored = true
end

local function playersAdded(player: Player)
    local e = ref(player.UserId)
    world:set(e, Player, player)
    local characterAdd = player.CharacterAdded
    conn[e] = characterAdd:Connect(function(rig)
        while rig.Parent ~= workspace do
            task.wait()
        end
        world:set(e, Character, rig)
        -- Not playing (menu/lobby) → freeze in place at the spawn (stays in streaming range, so the
        -- arena renders). Playing (Play un-froze them) → leave them mobile.
        if not PlayerState.get(player).playing then freeze(rig) end
    end)
    -- give them a frozen lobby body now → warm client, in streaming range, Play just un-freezes it
    task.spawn(function() player:LoadCharacter() end)
end

local function playersRemoved(player: Player)
    local e = ref(player.UserId)
    world:clear(e)
    local connection = conn[e]
    if connection then connection:Disconnect(); conn[e] = nil end
end

local M = {}

-- PLAY: bring the player into play. Teleport the frozen lobby body from the hidden lobby back to
-- the arena spawn and UN-FREEZE it — no LoadCharacter hitch. Only if there's no living body (e.g.
-- right after a death before a re-spawn) do we load a fresh one. Caller sets PlayerState.playing =
-- true first so the CharacterAdded handler above won't re-freeze it.
function M.warpIn(player: Player)
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if char and hum and (hum :: Humanoid).Health > 0 then
        -- PivotTo while still anchored (server-owned) so the spawn is set authoritatively, THEN
        -- un-anchor to hand control to the client — avoids a physics race at the handoff.
        char:PivotTo(arenaSpawn or CFrame.new(0, 5, 0))
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp then (hrp :: BasePart).Anchored = false end
    else
        task.spawn(function() player:LoadCharacterAsync() end)
    end
end

-- Round end: make sure every player has a fresh frozen lobby body again (replaces dead/missing
-- bodies). Invisible — at round end the camera is the scriptable menu/spectate view, so the
-- re-spawn never flickers; it just cleans the dead body off the field and readies the next Play.
function M.refreshLobby(player: Player)
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not (char and hum and (hum :: Humanoid).Health > 0) then
        task.spawn(function() player:LoadCharacter() end)
    end
end

local scheduler = require(std.scheduler)
local phases = require(std.phases)
scheduler.SYSTEM(playersAdded, phases.PlayerAdded)
scheduler.SYSTEM(playersRemoved, phases.PlayerRemoved)

-- PlayerAdded race guard (CLAUDE.md): in team-test / fast joins a player can already be
-- connected before this runs, so PlayerAdded never fires for them.
for _, p in Players:GetPlayers() do
    playersAdded(p)
end

return M
