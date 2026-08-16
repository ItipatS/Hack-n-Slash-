-- ClientSystems/playerHit.luau
-- The player's reaction when a mob lands a hit (server fires "playerhit"(dir, finisher) — knockback is
-- applied server-side on the authoritative character). Here we just play the FEEL: a hit-reaction clip
-- (a random hit for a normal, the knockdown for a finisher) + a quick camera shake via Humanoid.CameraOffset
-- (which doesn't fight the camera system). Tracks are cached per character.
--!strict

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local remote  = ReplicatedStorage:WaitForChild("CombatRemote") :: RemoteEvent
local AnimCfg = require(ReplicatedStorage.std.animConfig)
local MobCfg  = require(ReplicatedStorage.std.mobConfig)
local FX      = require(ReplicatedStorage.std.fx) -- enemy hit sound
local FXC     = require(ReplicatedStorage.std.combatConfig).FX -- reuse the player's melee hit-sound config

local LP   = Players.LocalPlayer
local base = AnimCfg.SETS.base

local tracks: { [number]: AnimationTrack } = {} -- cache by anim id (cleared per character)
local animator: Animator? = nil

local function setup(char: Model)
	table.clear(tracks)
	local hum = char:WaitForChild("Humanoid", 5) :: Humanoid?
	animator = if hum then (hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)) else nil
end

local function trackFor(id: number): AnimationTrack?
	if id == 0 then return nil end
	if tracks[id] then return tracks[id] end
	local an = animator
	if not an then return nil end
	local a = Instance.new("Animation")
	a.AnimationId = "rbxassetid://" .. id
	local ok, t = pcall(function() return an:LoadAnimation(a) end)
	if not ok or not t then return nil end
	-- MOVEMENT priority (NOT Action): the player's attacks/rolls/jumps are Action, so they fully OVERRIDE
	-- this flinch instead of blending with it. It still shows over idle/loco.
	t.Priority = Enum.AnimationPriority.Movement
	t.Looped = false
	tracks[id] = t
	return t
end

if LP.Character then setup(LP.Character) end
LP.CharacterAdded:Connect(setup)

remote.OnClientEvent:Connect(function(kind: any, _dir: any, finisher: any)
	if kind ~= "playerhit" then return end
	local char = LP.Character
	if not char then return end

	-- hit-reaction clip: ALWAYS a quick HIT (hit1..N) — NOT the knockdown (that reads as a stun). It's a light
	-- flinch that layers over what you're doing; the finisher just shakes harder (below), not a bigger stagger.
	local id = base["hit" .. math.random(1, MobCfg.HIT_COUNT)]
	local t = trackFor(id or 0)
	if t then t:Play(0.05) end

	-- enemy hit sound — SAME resolver the player's melee hits use: FXC.HIT_SOUND + FXC.HIT_PICK filters to the
	-- MELEE (punch) variants, not the sword ones (that's why an unfiltered "Hit" was pulling sword swings).
	local root = char.PrimaryPart or char:FindFirstChild("HumanoidRootPart")
	if root then FX.sound(FXC.HIT_SOUND, (root :: BasePart).Position, FXC.HIT_PICK, 3) end

	-- camera shake: punch the CameraOffset out, settle back
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		local mag = if finisher then 2.4 else 1.2
		local off = Vector3.new((math.random() - 0.5) * 2 * mag, -math.random() * mag * 0.6, 0)
		TweenService:Create(hum, TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CameraOffset = off }):Play()
		task.delay(0.07, function()
			if hum.Parent then
				TweenService:Create(hum, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CameraOffset = Vector3.zero }):Play()
			end
		end)
	end
end)

return 0
