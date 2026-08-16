-- ServerScriptService/systems/players.luau
-- Hack&slash player registration — REBUILT for the pivot (the old vampire-survivors version,
-- with its lobby parking / CharacterAutoLoads dance, lives in _legacy/). This one is minimal:
--   • ECS: every player gets an entity (ref by UserId) with Player + Character components, so
--     server systems (combat, mobs) query characters the same way the old code did.
--   • ActionState: the client animator reports locomotion/action TRANSITIONS (blink.PlayerAction,
--     enum in std/playerStates). We store {state, since} — combat reads it for state rules
--     (roll i-frames, attack gating). Movement itself stays client-authoritative (CLAUDE.md):
--     we validate outcomes, never positions.
-- Requiring ServerNet here is also what CREATES the Blink remotes — at least one server system
-- must do it before ServerReady, or every client blocks waiting for them.
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players             = game:GetService("Players")

local blink = require(ServerScriptService.ServerNet)
local std   = ReplicatedStorage.std

local world     = require(std.world)
local cts       = require(std.components)
local ref       = require(std.ref)
local scheduler = require(std.scheduler)
local phases    = require(std.phases)
local States    = require(std.playerStates)

local Player      = cts.Player
local Character   = cts.Character
local ActionState = cts.ActionState

local conn: { [number]: RBXScriptConnection } = {}

-- Spawn point: a BasePart named this, anywhere in workspace (recursive — it can live inside the lobby/map
-- model). We place the character on it ourselves rather than relying on a SpawnLocation, so the lobby part
-- needs no special class. Missing part → leave the default spawn + warn.
local SPAWN_PART = "Main Spawn"

local function spawnAt(rig: Model)
	local hrp = rig:FindFirstChild("HumanoidRootPart") :: BasePart?
	local part = workspace:FindFirstChild(SPAWN_PART, true)
	if not (hrp and part and part:IsA("BasePart")) then
		if not part then warn(("[players] spawn part '%s' not found — using default spawn"):format(SPAWN_PART)) end
		return
	end
	-- stand ON the part: HRP centre ~3 studs above the part's TOP face. Keep only the part's YAW (so an
	-- accidentally-tilted spawn part doesn't spawn the player leaning), upright otherwise.
	local _, yaw = part.CFrame:ToOrientation()
	local pos = part.Position + Vector3.new(0, part.Size.Y / 2 + 3, 0)
	rig:PivotTo(CFrame.new(pos) * CFrame.Angles(0, yaw, 0))
end

local function playersAdded(player: Player)
	local e = ref(player.UserId)
	world:set(e, Player, player)
	world:set(e, ActionState, { state = States.Idle, since = workspace:GetServerTimeNow() })
	conn[e] = player.CharacterAdded:Connect(function(rig)
		while rig.Parent ~= workspace do
			task.wait()
		end
		spawnAt(rig)
		world:set(e, Character, rig)
	end)
	if player.Character then
		spawnAt(player.Character)
		world:set(e, Character, player.Character)
	end
end

local function playersRemoved(player: Player)
	local e = ref(player.UserId)
	world:clear(e)
	local c = conn[e]
	if c then c:Disconnect(); conn[e] = nil end
end

-- client animator reports a state TRANSITION. Trust the enum value but not blindly: clamp to
-- known states (a bad/modified client can't invent state 200 and trip future combat branches).
blink.PlayerAction.On(function(player, state)
	if States.Name[state] == nil then return end
	local e = ref(player.UserId)
	world:set(e, ActionState, { state = state, since = workspace:GetServerTimeNow() })
	-- attribute mirror: visible in the Studio explorer/command bar (the ECS world isn't reachable
	-- from other Luau contexts), and free to keep — it only writes on transitions
	player:SetAttribute("ActionState", States.Name[state])
end)

scheduler.SYSTEM(playersAdded, phases.PlayerAdded)
scheduler.SYSTEM(playersRemoved, phases.PlayerRemoved)

-- PlayerAdded race guard: in team-test / fast joins a player can already be connected before
-- this runs, so PlayerAdded never fires for them.
for _, p in Players:GetPlayers() do
	playersAdded(p)
end

return 0
