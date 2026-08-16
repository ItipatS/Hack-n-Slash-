-- ClientSystems/mobs.luau
-- Client MOB rendering off our OWN Blink dense-slot lane (NOT Chrono). The server streams authoritative
-- POSITIONS only (Spawn = initial + slot, UpdateTransformDelta = i8 slot-ordered deltas, UpdateTransformFull
-- = f32 drift correction, Death = release). We interpolate toward the latest target, DERIVE facing from the
-- motion (no yaw on the wire), and render at TWO LOD tiers by distance to the local player:
--   • NEAR  (≤ mobConfig.LOD_NEAR): a full animated rig (pooled, Animator, idle/walk/run) — nice up close.
--   • FAR   (beyond):               a cheap pooled rig moved in bulk (MobRenderPool + BulkMoveTo) with a
--                                    procedural leg-swing — scales to the horde without an Animator each.
-- Hysteresis on the boundary stops churn. Hits/deaths come over CombatRemote (mobhit / mobdeath corpse).
--!optimize 2
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local Debris            = game:GetService("Debris")

local std       = ReplicatedStorage.std
local scheduler = require(std.scheduler)
local phases    = require(std.phases)
local MobCfg     = require(std.mobConfig)
local AnimCfg    = require(std.animConfig)
local CombatCfg  = require(std.combatConfig) -- impact FX names + the light/heavy classification
local FX         = require(std.fx)
local Config     = require(std.config)
local blink      = require(std.ClientNet)
local MobRenderPool = require(std.MobRenderPool)
local damageText = require(script.Parent.damageText) -- pooled floating damage numbers (spawned per hit below)
local healthBar  = require(script.Parent.healthBar)  -- pooled mob health bars (BillboardGui adorned to the rig)

local remote = ReplicatedStorage:WaitForChild("CombatRemote") :: RemoteEvent
local LP     = Players.LocalPlayer

-- module table: this system also exposes an API to ClientSystems/combat (predicted impact FX). Defaults to
-- a no-op so combat is safe even on the early-outs below (no rig asset → no mobs → nothing to hit).
local M = {}
function M.playImpacts(_cf: CFrame, _hx: number, _hy: number, _hz: number, _heavy: boolean, _damage: number?): number return 0 end
-- live counts for the demo HUD (perfHud). Default no-op until the real one is installed below (after the mob
-- table exists), so requiring this module on the early-out path still returns a callable M.
function M.getStats(): (number, number, number) return 0, 0, 0 end

local STEP        = Config.Net.STEP
local LOD_NEAR2   = MobCfg.LOD_NEAR * MobCfg.LOD_NEAR
local LOD_FAR2    = (MobCfg.LOD_NEAR + MobCfg.LOD_HYST) ^ 2

-- ── Rig root finder (community rig has NO HumanoidRootPart — just a centre part) ────
local function findRoot(rig: Model): BasePart?
	if rig.PrimaryPart then return rig.PrimaryPart end
	for _, name in { MobCfg.ROOT_NAME, "HumanoidRootPart", "Root", "root", "RootPart", "Torso", "UpperTorso" } do
		local p = rig:FindFirstChild(name)
		if p and p:IsA("BasePart") then return p end
	end
	local best: BasePart?, bestVol = nil, -1
	for _, d in rig:GetDescendants() do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > bestVol then best = d; bestVol = v end
		end
	end
	return best
end

-- ── Templates: one for the animated NEAR tier, one stripped for the cheap FAR pool ──
local assets = ReplicatedStorage:WaitForChild("Assets", 10)
local rigSrc = assets and assets:WaitForChild("Rig", 10)
if not (rigSrc and rigSrc:IsA("Model")) then
	warn("[mobs] ReplicatedStorage.Assets.Rig not found — mob rendering disabled")
	return M
end

-- shared prep: root as PrimaryPart, parts massless/non-colliding/non-query
local function prepRig(rig: Model): (Model?, BasePart?)
	local root = findRoot(rig)
	if not root then
		warn("[mobs] rig has no usable root/centre BasePart — check mobConfig.ROOT_NAME")
		return nil, nil
	end
	rig.PrimaryPart = root
	for _, d in rig:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery   = false
			d.CanTouch   = false
			d.Massless   = true
			d.Anchored   = (d == root)
		end
	end
	return rig, root
end

-- NEAR: keep the rig intact (Humanoid/Animator) but disable its Animate script (we drive animation)
local nearTemplate: Model
do
	local rig = (rigSrc :: Model):Clone()
	local animate = rig:FindFirstChild("Animate")
	if animate and animate:IsA("LuaSourceContainer") then animate.Disabled = true end
	local prepped, root = prepRig(rig)
	if not (prepped and root) then return M end
	rig.Name = "MobRigNear"
	print(("[mobs] rig root part = '%s' (custom Blink lane, LOD rendering)"):format(root.Name))
	nearTemplate = rig
end

-- FAR: strip everything non-visual (Humanoid/scripts/sounds/SpecialMesh) → a pose-only rig for the pool
local farTemplate: Model
do
	local rig = (rigSrc :: Model):Clone()
	for _, d in rig:GetDescendants() do
		if d:IsA("Humanoid") or d:IsA("BaseScript") or d:IsA("ModuleScript")
			or d:IsA("Sound") or d:IsA("SpecialMesh") then
			d:Destroy()
		end
	end
	local prepped, root = prepRig(rig)
	if not (prepped and root) then return M end
	for _, d in rig:GetDescendants() do
		if d:IsA("BasePart") then d.CastShadow = false end
	end
	rig.Name = "MobRigFar"
	farTemplate = rig
end

local MobsFolder = Instance.new("Folder")
MobsFolder.Name = "Mobs"
MobsFolder.Parent = workspace

local farPool = MobRenderPool.new(farTemplate, MobsFolder)

-- ── Near-rig pool (keeps Animators + loaded tracks alive across LOD swaps) ──────────
type NearRig = {
	rig: Model,
	root: BasePart,
	animator: Animator,
	tracks: { [string]: AnimationTrack }, -- idle / walk / run (forward — facing == motion)
	weights: { [string]: number },        -- eased blend state
	sentW: { [string]: number },          -- last weight we actually pushed to the engine (skip-unchanged)
	sentSpeed: { [string]: number },      -- last playback rate we actually pushed (skip-unchanged)
	react: AnimationTrack?, -- one-shot hit overlay
}
local nearFree: { NearRig } = {}
local NEAR_CAP = MobCfg.NEAR_CAP
-- NEAREST-N animated set: each anim tick we sort all mob distances and take the NEAR_CAP CLOSEST as the near
-- (animated) tier — so the Animator budget always lands on the mobs nearest the player, not whichever crossed
-- LOD_NEAR first. `nearIn2` = promote distance² (the NEAR_CAP-th nearest, capped at LOD_NEAR²); `nearOut2` =
-- demote distance² at a looser rank → rank hysteresis so mobs at the boundary don't thrash tiers.
local distScratch: { number } = {}
local nearIn2  = LOD_NEAR2
local nearOut2 = LOD_FAR2

local function newTrack(animator: Animator, id: number, prio: Enum.AnimationPriority, looped: boolean): AnimationTrack?
	if id == 0 then return nil end
	local a = Instance.new("Animation")
	a.AnimationId = "rbxassetid://" .. id
	local ok, t = pcall(function() return animator:LoadAnimation(a) end)
	if not ok or not t then return nil end
	t.Priority = prio
	t.Looped = looped
	return t
end

local function buildNearRig(): NearRig
	local rig = nearTemplate:Clone()
	local root = rig.PrimaryPart :: BasePart
	local hum = rig:FindFirstChildOfClass("Humanoid")
	if hum then
		-- WE own this rig's CFrame (we drive it from the stream) — never let the Humanoid steer it.
		hum.AutoRotate = false
		hum.WalkSpeed = 0
		hum.EvaluateStateMachine = false -- pure animation holder; no state machine / physics upkeep
	end
	local holder: Instance = hum or rig:FindFirstChildOfClass("AnimationController") or Instance.new("AnimationController")
	if not holder.Parent then holder.Parent = rig end
	local animator = holder:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = holder

	-- forward-only loco (facing == motion → no strafe/backpedal needed). A non-zero mobConfig.ANIM key
	-- overrides with a mob-specific clip; 0 falls back to the shared animConfig base set.
	local base = AnimCfg.SETS.base
	local function pick(key: string): number
		local id = MobCfg.ANIM[key]
		return if id and id ~= 0 then id else base[key]
	end
	local ids = { idle = pick("idle"), walk = pick("walkF"), run = pick("runF") }
	local tracks: { [string]: AnimationTrack } = {}
	for _, key in { "idle", "walk", "run" } do
		local t = newTrack(animator, ids[key], Enum.AnimationPriority.Movement, true)
		if t then t:Play(0); t:AdjustWeight(1e-3, 0); tracks[key] = t end
	end
	return { rig = rig, root = root, animator = animator, tracks = tracks, weights = {}, sentW = {}, sentSpeed = {}, react = nil }
end

local function acquireNear(cf: CFrame): NearRig
	local nr = table.remove(nearFree) or buildNearRig()
	nr.root.CFrame = cf
	nr.rig.Parent = MobsFolder
	return nr
end

local function releaseNear(nr: NearRig)
	healthBar.hide(nr.root) -- drop any bar before the rig is pooled/reused (else it follows a recycled root)
	if nr.react then nr.react:Stop(0); nr.react = nil end
	for key, t in nr.tracks do
		nr.weights[key] = 0
		t:AdjustWeight(1e-3, 0)
	end
	table.clear(nr.sentW)     -- forget what we pushed → the reused rig re-pushes on its first anim tick
	table.clear(nr.sentSpeed)
	nr.rig.Parent = nil
	nearFree[#nearFree + 1] = nr
end

-- ── Per-mob record ─────────────────────────────────────────────────────────────────
type Mob = {
	slot: number,
	target: Vector3,
	renderPos: Vector3,
	heading: Vector3,
	speed: number,
	lastAnimPos: Vector3?, -- renderPos at the last ANIM tick → speed measured over the anim interval, not per-frame
	lod: string?,        -- "near" | "far" | nil (unassigned)
	near: NearRig?,      -- set while lod == "near"
	farLegs: { Motor6D }?,
}
local mobs:       { [number]: Mob } = {}       -- netId → record
local slotToNet:  { [number]: number } = {}    -- dense position slot → netId

-- real impl (overrides the top no-op): live mob count + how many are ANIMATED (near) vs cheap (far).
-- Iterates the mob table — the HUD calls this a few times/sec, so it's cheap.
function M.getStats(): (number, number, number)
	local live, near = 0, 0
	for _, m in mobs do
		live += 1
		if m.lod == "near" then near += 1 end
	end
	return live, near, live - near
end

local function releaseMob(netId: number)
	local m = mobs[netId]
	if not m then return end
	if m.lod == "near" and m.near then releaseNear(m.near)
	elseif m.lod == "far" then farPool:release(netId) end
	-- only clear the slot map if it still points to THIS mob: the death signal (CombatRemote) and a
	-- slot-REUSING spawn (Blink) travel on different channels, so the new spawn may already own this slot.
	if slotToNet[m.slot] == netId then slotToNet[m.slot] = nil end
	mobs[netId] = nil
end

-- ── Net receivers ───────────────────────────────────────────────────────────────────
-- DEBUG_NET seam markers: `dbgSwaps` counts LOD promotions/demotions (churn → tune LOD_HYST); the one-shot
-- first-delta/first-full flags separate "the stream never arrived" from "it arrived and the renderer is stuck".
local dbgSwaps, dbgAcc = 0, 0
local dbgFirstDelta, dbgFirstFull = false, false

blink.Spawn.On(function(batch)
	local n = 0
	for _, p in batch do
		if p.type ~= "MOB" then continue end
		local pos = p.pos :: Vector3
		mobs[p.id] = {
			slot = p.slot,
			target = pos,
			renderPos = pos,
			heading = Vector3.new(0, 0, -1),
			speed = 0,
			lod = nil,
			near = nil,
			farLegs = nil,
		}
		slotToNet[p.slot] = p.id
		n += 1
	end
	if MobCfg.DEBUG_NET and n > 0 then print(("[mobs/cli] spawn recv: %d mobs"):format(n)) end
end)

-- one dense chunk: i8 deltas in slot order from chunk.base. slot = base + index/3 → map to netId
blink.UpdateTransformDelta.On(function(chunk)
	local deltas = chunk.deltas
	local n = #deltas
	local slot = chunk.base
	local i = 0
	while i < n do
		local netId = slotToNet[slot]
		if netId then
			local m = mobs[netId]
			if m then
				m.target = m.target + Vector3.new(deltas[i + 1] * STEP, deltas[i + 2] * STEP, deltas[i + 3] * STEP)
			end
		end
		i += 3
		slot += 1
	end
	if MobCfg.DEBUG_NET and not dbgFirstDelta then
		dbgFirstDelta = true
		print(("[mobs/cli] FIRST delta applied (base=%d, %d slots) — the position stream is live"):format(chunk.base, n // 3))
	end
end)

blink.UpdateTransformFull.On(function(batch)
	for _, t in batch do
		local m = mobs[t.id]
		if m then m.target = t.dp :: Vector3 end
	end
	if MobCfg.DEBUG_NET and not dbgFirstFull then
		dbgFirstFull = true
		print(("[mobs/cli] FIRST full snapshot applied (%d mobs) — drift correction is live"):format(#batch))
	end
end)

blink.Death.On(function(ids)
	for _, netId in ids do releaseMob(netId) end
end)

-- ── Hit reaction (NEAR rigs only — far mobs have no Animator) ───────────────────────
-- play a one-shot clip on a NEAR mob's rig (shares the single `react` overlay slot). Far mobs have no Animator.
local function playOneShot(m: Mob, id: number?)
	if m.lod ~= "near" or not m.near or not id or id == 0 then return end
	local nr = m.near
	local t = newTrack(nr.animator, id, Enum.AnimationPriority.Action, false)
	if not t then return end
	if nr.react and nr.react.IsPlaying then nr.react:Stop(0.05) end
	nr.react = t
	t:Play(0.05)
	local len = t.Length
	task.delay(if len > 0 then len else 0.4, function()
		if nr.react == t then nr.react = nil end
		t:Stop(0.1); t:Destroy()
	end)
end

local function playHit(m: Mob) -- reaction to being hit (random hit1..N)
	if MobCfg.HIT_COUNT <= 0 then return end
	playOneShot(m, AnimCfg.SETS.base["hit" .. math.random(1, MobCfg.HIT_COUNT)])
end

local function playMobAttack(m: Mob) -- the mob's own attack/lunge when it strikes the player
	playOneShot(m, MobCfg.ATTACK_ANIM)
end

-- ── Death corpse: a transient rig flung from the death spot, playing knockdown ─────
local corpses: { Model } = {}
local function spawnCorpse(cf: CFrame, fling: Vector3)
	while #corpses >= MobCfg.DEATH_CAP do
		local old = table.remove(corpses, 1)
		if old then old:Destroy() end
	end
	local body = farTemplate:Clone()
	local root = body.PrimaryPart :: BasePart
	body:PivotTo(cf)
	for _, d in body:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.Massless = false
			d.CanCollide = (d == root)
		end
	end
	local holder = Instance.new("AnimationController")
	holder.Parent = body
	local animator = Instance.new("Animator")
	animator.Parent = holder
	local kd = AnimCfg.SETS.base.knockdown
	if kd and kd ~= 0 then
		local t = newTrack(animator, kd, Enum.AnimationPriority.Action, false)
		if t then t:Play(0.05) end
	end
	body.Parent = workspace
	root.AssemblyLinearVelocity = fling + Vector3.new(0, MobCfg.DEATH_FLING * 0.4, 0)
	table.insert(corpses, body)
	Debris:AddItem(body, MobCfg.DEATH_TTL)
	task.delay(MobCfg.DEATH_TTL, function()
		local idx = table.find(corpses, body)
		if idx then table.remove(corpses, idx) end
	end)
end

-- server → client combat reactions
remote.OnClientEvent:Connect(function(kind, a, b, c)
	if kind == "mobhit" and type(a) == "table" then
		-- AUTHORITATIVE reaction only: the server says which mobs actually took the hit → hitstun anim + a
		-- health bar at the authoritative HP fraction (c[i]). The impact VFX/SFX are NOT here — they're
		-- client-PREDICTED in M.playImpacts the instant you swing, so replaying them would double them a
		-- roundtrip late. (c may be nil for the slam's mobhit → default frac 1 = no bar.)
		for i, netId in a do
			local m = mobs[netId]
			if m then
				playHit(m)
				if m.lod == "near" and m.near then
					healthBar.show(m.near.root, if type(c) == "table" then c[i] or 1 else 1)
				end
			end
		end
	elseif kind == "mobattack" and type(a) == "table" then
		-- the server named the mobs striking a player → each plays its lunge/attack clip (many at once)
		for _, id in a do
			local m = mobs[id]
			if m then playMobAttack(m) end
		end
	elseif kind == "mobdeath" then
		-- a = netId, b = death CFrame, c = fling velocity
		if type(a) == "number" then releaseMob(a) end
		spawnCorpse(b or CFrame.new(), c or Vector3.zero)
	end
end)

-- ── LOD assignment + far-tier leg cache ─────────────────────────────────────────────
local function findFarLegs(rig: Model): { Motor6D }
	local legs: { Motor6D } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 and string.find(d.Part1.Name, "Leg") then
			legs[#legs + 1] = d
			if #legs >= 2 then break end
		end
	end
	return legs
end

-- promote/demote a mob between the animated NEAR rig and the cheap pooled FAR rig
local function setLod(m: Mob, netId: number, lod: string, cf: CFrame)
	if m.lod == lod then return end
	-- tear down the old representation
	if m.lod == "near" and m.near then releaseNear(m.near); m.near = nil
	elseif m.lod == "far" then farPool:release(netId); m.farLegs = nil end
	-- build the new one
	if lod == "near" then
		m.near = acquireNear(cf)
	else
		local model = farPool:acquire(netId, cf, 1)
		m.farLegs = findFarLegs(model)
	end
	m.lod = lod
	dbgSwaps += 1
end

-- ── Render (Heartbeat) ──────────────────────────────────────────────────────────────
-- Split by RATE. MOTION — position lerp, facing, CFrame, the per-tier CFrame write — runs EVERY frame so
-- movement/facing stay smooth. ANIMATION CONFIG — gait AdjustWeight/AdjustSpeed, LOD decision, far leg-swing
-- — runs at ANIM_TICK (~20 Hz). Those Animator API calls were THE client hot-path (N near rigs × ~5 calls ×
-- 60 fps ≈ 150k calls/s at 500 near) and are invisible at 20 vs 60. Adjust* is ALSO skipped when the value
-- barely moved, so a steady-speed mob makes ~0 animation calls/tick. NOTE: this cuts the per-frame CALL
-- churn, NOT the Animator COUNT — if hundreds are near at once, also cap the near set (see below).
local ANIM_TICK = 1 / 20
local animAcc   = 0
local W_EPS     = 0.02 -- don't re-push a blend weight that moved less than this
local S_EPS     = 0.05 -- don't re-push a playback rate that moved less than this

local function render(dt: number)
	local a = math.min(1, MobCfg.LERP_RATE * dt)
	local hb = math.min(1, MobCfg.HEADING_RATE * dt)
	local now = os.clock()

	animAcc += dt
	local doAnim = animAcc >= ANIM_TICK
	local adt = animAcc
	if doAnim then animAcc = 0 end
	local ba = math.min(1, MobCfg.BLEND_RATE * adt) -- gait ease over the ANIM interval
	local sm = math.min(1, 10 * adt)                -- speed smoothing over the ANIM interval

	-- local player position for LOD distance
	local lchar = LP.Character
	local lroot = lchar and (lchar.PrimaryPart or lchar:FindFirstChild("HumanoidRootPart")) :: BasePart?
	local lp = lroot and lroot.Position or Vector3.zero

	-- NEAREST-N pre-pass (anim rate): sort this tick's distances → promote/demote thresholds so the animated
	-- tier is the NEAR_CAP mobs CLOSEST to the player. `nearIn2` = the NEAR_CAP-th nearest d² (≤ LOD_NEAR²);
	-- `nearOut2` = a looser rank's d² → hysteresis so boundary mobs don't swap tiers every tick.
	if doAnim and lroot then
		table.clear(distScratch)
		for _, m in mobs do
			local dx, dz = m.renderPos.X - lp.X, m.renderPos.Z - lp.Z
			distScratch[#distScratch + 1] = dx * dx + dz * dz
		end
		local nd = #distScratch
		if nd > 0 then
			table.sort(distScratch)
			local inRank = math.min(NEAR_CAP, nd)
			local outRank = math.min(nd, math.max(inRank + 1, math.floor(NEAR_CAP * 1.25)))
			nearIn2  = math.min(LOD_NEAR2, distScratch[inRank])
			nearOut2 = math.min(LOD_FAR2, distScratch[outRank])
		else
			nearIn2, nearOut2 = LOD_NEAR2, LOD_FAR2
		end
	end

	for netId, m in mobs do
		local rp = m.renderPos
		local tgt = m.target

		-- FACING is derived from the PURSUIT GAP (target - renderPos), NOT the per-frame lerp step: at
		-- chase speed the lerp step is only ~0.15 studs/frame, which sits right on MOVE_EPS2 — deriving a
		-- heading from it made the facing freeze/stutter. The gap is a stable, much larger vector.
		local fx, fz = tgt.X - rp.X, tgt.Z - rp.Z
		local g2 = fx * fx + fz * fz
		if g2 > MobCfg.MOVE_EPS2 then
			local inv = 1 / math.sqrt(g2)
			local ndx, ndz = fx * inv, fz * inv
			local h = m.heading
			local hx, hz = h.X + (ndx - h.X) * hb, h.Z + (ndz - h.Z) * hb
			local hm = math.sqrt(hx * hx + hz * hz)
			m.heading = if hm > 1e-4 then Vector3.new(hx / hm, 0, hz / hm) else Vector3.new(ndx, 0, ndz)
		end

		-- interpolate toward the streamed target — EVERY frame (smooth motion)
		local nrp = rp:Lerp(tgt, a)
		m.renderPos = nrp

		-- speed (drives gait) + LOD decision — ANIM rate only; neither needs 60 Hz.
		if doAnim then
			-- planar speed from motion over the ANIM interval (less noisy than a per-frame delta)
			local lapos = m.lastAnimPos or nrp
			local mvx, mvz = nrp.X - lapos.X, nrp.Z - lapos.Z
			local raw = math.sqrt(mvx * mvx + mvz * mvz) / math.max(adt, 1e-3)
			m.speed += (raw - m.speed) * sm
			m.lastAnimPos = nrp

			-- LOD by NEAREST-N (nearIn2/nearOut2 from the pre-pass): the NEAR_CAP closest mobs are animated, with
			-- rank hysteresis (promote at nearIn2, demote only past nearOut2) so the boundary doesn't thrash.
			-- While the local character is absent (respawn), hold the current tier — don't mass-rebuild off a
			-- bogus origin distance; a brand-new mob just defaults to the cheap FAR tier until we know better.
			local want = m.lod
			if lroot then
				local dx, dz = nrp.X - lp.X, nrp.Z - lp.Z
				local d2 = dx * dx + dz * dz
				if want == nil then
					want = if d2 <= nearIn2 then "near" else "far"
				elseif want == "near" and d2 > nearOut2 then
					want = "far"
				elseif want == "far" and d2 <= nearIn2 then
					want = "near"
				end
			elseif want == nil then
				want = "far"
			end
			if want ~= m.lod then
				local f0 = if m.heading.Magnitude > 1e-4 then m.heading else Vector3.new(0, 0, -1)
				setLod(m, netId, want, CFrame.lookAt(nrp, nrp + f0))
			end
		end

		-- CFrame + per-tier position write — EVERY frame (smooth)
		local face = if m.heading.Magnitude > 1e-4 then m.heading else Vector3.new(0, 0, -1)
		local cf = CFrame.lookAt(nrp, nrp + face)

		if m.lod == "near" and m.near then
			local nr = m.near
			nr.root.CFrame = cf -- every frame (smooth); the gait CONFIG below is ANIM-rate + skip-unchanged
			if doAnim then
				-- gait blend: speed → idle/walk/run, playback scaled (no foot-slide). Only PUSH a weight/speed
				-- when it actually moved (W_EPS/S_EPS) — a steady mob then makes zero Animator calls this tick.
				local speed = m.speed
				local moveW = math.min(1, speed / MobCfg.WALK_REF)
				local runA  = math.clamp((speed - MobCfg.RUN_START) / math.max(1e-3, MobCfg.RUN_FULL - MobCfg.RUN_START), 0, 1)
				local targets = { idle = 1 - moveW, walk = moveW * (1 - runA), run = moveW * runA }
				for key, t in nr.tracks do
					local w = (nr.weights[key] or 0)
					w += ((targets[key] or 0) - w) * ba
					nr.weights[key] = w
					local wv = math.max(w, 1e-3)
					local sw = nr.sentW[key]
					if not sw or math.abs(wv - sw) > W_EPS then
						t:AdjustWeight(wv, 0)
						nr.sentW[key] = wv
					end
					if speed > 0.1 and (key == "walk" or key == "run") then
						local rate = if key == "walk" then speed / MobCfg.WALK_REF else speed / MobCfg.RUN_REF
						local ss = nr.sentSpeed[key]
						if not ss or math.abs(rate - ss) > S_EPS then
							t:AdjustSpeed(rate)
							nr.sentSpeed[key] = rate
						end
					end
				end
			end
		elseif m.lod == "far" then
			-- cheap tier: the root moves in ONE BulkMoveTo (farPool:flush). The procedural leg swing is OFF
			-- by default (MobCfg.FAR_LEGS) — its 2 Motor6D writes/mob are individual LuaBridge crossings and
			-- were the client hot-path at scale. setCFrame just queues into the pool's table (no engine write).
			if MobCfg.FAR_LEGS and doAnim then
				local legs = m.farLegs
				if legs and m.speed > 0.4 then
					local s = math.sin(now * MobCfg.FAR_WALK_FREQ + netId * 0.7) * MobCfg.FAR_WALK_AMP
					if legs[1] then legs[1].Transform = CFrame.Angles(s, 0, 0) end
					if legs[2] then legs[2].Transform = CFrame.Angles(-s, 0, 0) end
				elseif legs then
					if legs[1] then legs[1].Transform = CFrame.identity end
					if legs[2] then legs[2].Transform = CFrame.identity end
				end
			end
			farPool:setCFrame(netId, cf)
		end
	end

	farPool:flush()

	-- seam #2: what the client is actually tracking + rendering. `live` should track the server's mob count
	-- (mismatch → a spawn/death leak); near/far shows the LOD split; a high swaps/s means mobs are dithering
	-- across the boundary → raise LOD_HYST.
	if MobCfg.DEBUG_NET then
		dbgAcc += dt
		if dbgAcc >= 1 then
			local live, near, far = 0, 0, 0
			for _, m in mobs do
				live += 1
				if m.lod == "near" then near += 1 elseif m.lod == "far" then far += 1 end
			end
			print(("[mobs/cli] live=%d near=%d far=%d | swaps=%d/s"):format(live, near, far, dbgSwaps // dbgAcc))
			dbgSwaps, dbgAcc = 0, 0
		end
	end
end

-- ── Predicted impact FX (called by ClientSystems/combat the moment YOU swing) ───────
-- PURELY VISUAL, PURELY CLIENT-SIDE, NO server confirmation: run the same box test the server runs, but
-- against our own interpolated mob positions, and pop the hit kit on EVERY mob inside it. Catching 100
-- mobs in one box should feel like 100 hits landing at once — waiting on the server's mobhit would both
-- delay it by a roundtrip and (before) only ever read as "a bit of hitstun".
-- The server still owns damage + the hitstun reaction, so a rare disagreement (interpolation lag) costs
-- only a cosmetic spark with no stun behind it — the right trade for feel.
-- `damage` (optional): if given, pop a floating damage number on each hit mob. Returns the TOTAL number of
-- mobs caught (used by the style meter's AoE bonus) — FX + numbers are capped at IMPACT_CAP, but the COUNT
-- reflects every mob in the box.
function M.playImpacts(cf: CFrame, hx: number, hy: number, hz: number, heavy: boolean, damage: number?): number
	local FXC = CombatCfg.FX
	local kit = if heavy then FXC.IMPACT_HEAVY else FXC.IMPACT_LIGHT
	local n = 0
	local soundAt: Vector3? = nil
	for _, m in mobs do
		local lp = cf:PointToObjectSpace(m.renderPos)
		if math.abs(lp.X) <= hx and math.abs(lp.Y) <= hy and math.abs(lp.Z) <= hz then
			soundAt = soundAt or m.renderPos
			n += 1
			if n <= FXC.IMPACT_CAP then -- cap the visible spam; keep counting for the style bonus
				FX.burst(kit.name, CFrame.new(m.renderPos), kit.scale, FXC.TTL, FXC.EMIT_BURST)
				if damage and damage > 0 then damageText.pop(m.renderPos, damage, heavy) end
			end
		end
	end
	-- ONE hit cue per swing (a random punch variant), not one per mob — overlapping copies just phase
	if soundAt then FX.sound(FXC.HIT_SOUND, soundAt, FXC.HIT_PICK) end
	return n
end

scheduler.SYSTEM(render, phases.Heartbeat)
return M
