-- ServerScriptService/systems/combat.luau
-- Server-authoritative MELEE hit resolution. The client sends "attack N" (1-5 light, 6 heavy); the
-- server does the shapecast ITSELF — a box overlap in front of the player's SERVER HumanoidRootPart
-- against the mob hitbox parts (which only exist server-side, under Chrono's storage) — and applies
-- damage + knockback. The client never decides hits; it only shows the debug box + plays the anim.
-- (Hits are the one place CLAUDE.md wants authority; lag-comp rewind against Chrono snapshots is a
-- later hardening step — for now the mobs are close-range melee so current-frame positions are fine.)
--
-- Transport: a dedicated CombatRemote for the prototype. TODO migrate to a Blink lane (Net.blink).
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std         = ReplicatedStorage.std
local world       = require(std.world)
local cts         = require(std.components)
local CombatCfg   = require(std.combatConfig)
local MobRegistry = require(std.mobRegistry)
local scheduler   = require(std.scheduler)
local phases      = require(std.phases)

local MobCfg   = require(std.mobConfig)
local upgradeStats = require(std.upgradeStats)
local serverPause  = require(std.serverPause) -- true while anyone is on the level-up screen → mobs freeze

-- per-player level-up upgrade set (folded from "upgrade" picks) → read in onAttack (damage/air/range/knock/
-- chain) + onSlamLand (slam). Absent player = fresh defaults.
local playerStats: { [Player]: upgradeStats.Stats } = {}
local function statsFor(player: Player): upgradeStats.Stats
	local s = playerStats[player]
	if not s then s = upgradeStats.defaults(); playerStats[player] = s end
	return s
end
local CHAIN_RANGE2 = 14 * 14 -- Chain Lightning: arc to un-hit mobs within this of the strike centre

-- Level-up PAUSE state. MUST be declared BEFORE the OnServerEvent handler that calls setPicking — a local
-- referenced before its declaration binds to a nil global (that was the crash + why the pause never fired).
local picking: { [Player]: boolean } = {} -- true while a player is on the level-up card screen
local pickingCount = 0
local function setPicking(player: Player, on: boolean)
	local was = picking[player] ~= nil
	picking[player] = if on then true else nil
	if on and not was then pickingCount += 1
	elseif not on and was then pickingCount = math.max(0, pickingCount - 1) end
	serverPause.paused = pickingCount > 0 -- freeze the world while anyone is choosing an upgrade
end

local Health   = cts.Health
local Knock    = cts.Knock
local Velocity = cts.Velocity
local Hitbox   = cts.Hitbox
local Grabbed  = cts.Grabbed

-- Destruction modules live under Workspace (RockModule V1.0 / VoxManager). Loaded here for the slam impact
-- (server-side → the crater + carve replicate to everyone). Guarded: the game still runs if they're absent.
local RockModule: any, VoxManager: any = nil, nil
task.spawn(function()
	local rm = workspace:WaitForChild("RockModule V1.0", 15)
	local rmMod = rm and rm:FindFirstChild("RockModule")
	if rmMod then local ok, m = pcall(require, rmMod); if ok then RockModule = m end end
	local vm = workspace:WaitForChild("VoxManager", 15)
	if vm then local ok, m = pcall(require, vm); if ok then VoxManager = m end end
	if not RockModule then warn("[combat] Workspace.RockModule V1.0.RockModule not found — slam has no crater FX") end
end)

-- one shared CombatRemote (this system OR systems/mobs, whichever loads first, creates it)
local remote: RemoteEvent
local existing = ReplicatedStorage:FindFirstChild("CombatRemote")
if existing and existing:IsA("RemoteEvent") then
	remote = existing
else
	remote = Instance.new("RemoteEvent")
	remote.Name = "CombatRemote"
	remote.Parent = ReplicatedStorage
end

-- resolve an attack number → its config row (1..5 = light chain, 6 = heavy). Single stance for now.
local STANCE = "base"
-- Resolve through the SHARED resolver in combatConfig — the same function the client uses to pick the row,
-- so the two can never disagree about what an attack number means (ground 1..5/6, air AIR_BASE+1..2/+6).
-- The client only sends a NUMBER; every damage/knock/lift value is read from OUR config, never from it.
local function getAttack(n: number)
	local row = CombatCfg.resolve(n, STANCE)
	return row
end

-- simple per-player rate gate: an attack can't resolve more often than a single swing's active window,
-- so a spammed remote can't multi-hit one swing.
local lastAttackAt: { [Player]: number } = {}
local MIN_ATTACK_GAP = 0.12

-- the box in front of the player for attack `atk`, in world space (matches ClientSystems/combat geometry).
local function attackBox(root: BasePart, atk: any): (CFrame, number, number, number)
	local box = atk.box
	local cf  = root.CFrame * CFrame.new(0, 0, -(atk.reach * 0.5 - 0.5))
	return cf, box.X / 2, box.Y / 2, (atk.reach + 1) / 2
end

-- ── Continuous SLAM sweep ──────────────────────────────────────────────────────────
-- The air-heavy slam is NOT a one-shot: while a player is slamming, the sweep runs their (tall) box down the
-- dive path each frame and GRABS every new mob it passes through — catching the whole column, not just what
-- was under them at one active frame. Grabbed mobs are dragged down by systems/mobs and scattered on landing.
local slamming: { [Player]: { atk: any, t0: number, char: Model? } } = {}

local function slamGrab(player: Player, atk: any, now: number)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return end
	local cf, hx, hy, hz = attackBox(root, atk)
	local hitIds: { number } = {}
	MobRegistry.forEach(function(e: any, part: BasePart)
		if world:get(e, Grabbed) ~= nil then return end -- already caught (by this slam or another) → skip
		local lp = cf:PointToObjectSpace(part.Position)
		if math.abs(lp.X) <= hx and math.abs(lp.Y) <= hy and math.abs(lp.Z) <= hz then
			local hp = world:get(e, Health)
			if hp then hp.hp -= atk.damage; world:set(e, Health, hp) end
			world:set(e, Grabbed, { owner = player, t0 = now }) -- dragged down; scattered on slamland
			local id = MobRegistry.chronoIdOf(e)
			if id then hitIds[#hitIds + 1] = id end
		end
	end)
	if #hitIds > 0 then remote:FireAllClients("mobhit", hitIds, CombatCfg.AIR_BASE + 6) end
end

-- release (WITHOUT scatter) every mob a player is currently dragging. Collect-then-remove (mutating a
-- queried component mid-iteration is the unsafe jecs pattern). Used when a slam ends abnormally — death/
-- respawn, disconnect, timeout — so grabbed mobs don't stay pinned in the floor or carry into a next slam.
local function releaseGrabs(player: Player)
	local caught: { any } = {}
	for e, grab in world:query(Grabbed) do
		if grab.owner == player then caught[#caught + 1] = e end
	end
	for _, e in caught do world:remove(e, Grabbed) end
end

local function slamStep()
	if not next(slamming) then return end
	local now = os.clock()
	for player, s in slamming do
		if now - s.t0 > MobCfg.SLAM_GRAB_MAX or player.Character ~= s.char then
			-- timeout (land signal never arrived), OR the character changed → the player DIED/respawned
			-- mid-slam. Drop the sweep AND release its already-grabbed mobs (else they stay pinned in the
			-- floor and could be scattered by the SAME player's NEXT slam — owner is the Player instance).
			slamming[player] = nil
			releaseGrabs(player)
		else
			slamGrab(player, s.atk, now)
		end
	end
end

local function onAttack(player: Player, n: number)
	local atk = getAttack(n)
	if not atk then return end
	local now = os.clock()

	-- SLAM: begins the continuous grab-sweep (slamStep) instead of a one-shot. Rate-gate EXEMPT — the client
	-- sends it ONCE at the top of the dive and the sweep owns the hits from there until slamland.
	if atk.selfSlam then
		slamming[player] = { atk = atk, t0 = now, char = player.Character }
		return
	end

	if now - (lastAttackAt[player] or 0) < MIN_ATTACK_GAP then return end
	lastAttackAt[player] = now

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return end

	local st = statsFor(player)
	local isAir = n > CombatCfg.AIR_BASE
	local dmg = atk.damage * st.dmgMul * (if isAir then st.airDmgMul else 1) -- Sharper Blades / Air Superiority / Devil
	local cf, hx, hy, hz = attackBox(root, atk)
	hx, hz = hx * st.rangeMul, hz * st.rangeMul -- "Wide Arcs" widens the swing box
	local hitDir = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	hitDir = if hitDir.Magnitude > 1e-3 then hitDir.Unit else Vector3.zero

	-- manual OBB overlap: transform each mob's hitbox centre into the attack box's local space and
	-- test the half-extents. (Doesn't rely on spatial-querying Camera-parented parts.)
	local hitIds: { number } = {}
	local hitFracs: { number } = {} -- parallel to hitIds → the client shows a health bar at this fraction
	local hitSet: { [any]: boolean } = {} -- entities already hit (chain lightning must not re-hit them)
	MobRegistry.forEach(function(e: any, part: BasePart)
		local lp = cf:PointToObjectSpace(part.Position)
		if math.abs(lp.X) <= hx and math.abs(lp.Y) <= hy and math.abs(lp.Z) <= hz then
			hitSet[e] = true
			local hp = world:get(e, Health)
			local frac = 1
			if hp then
				hp.hp -= dmg
				world:set(e, Health, hp) -- death is handled by systems/mobs when hp <= 0
				frac = math.max(0, hp.hp) / hp.max
			end
			world:set(e, Knock, hitDir * (atk.knock * st.knockMul)) -- Concussive Hits / Devil
			-- LAUNCHER: a non-zero `lift` throws the mob straight up. We write it into the mob's Velocity.Y;
			-- systems/mobs integrates it against MobCfg.GRAVITY and clamps back onto its ground Y, and treats
			-- an aloft mob as hitstunned (no steering) — that's what makes juggling possible.
			-- Keep lift under the net lane's ceiling (~95 studs/sec — see config.luau Net.STEP).
			local lift = atk.lift
			if lift and lift ~= 0 then
				local v = world:get(e, Velocity) or Vector3.zero
				world:set(e, Velocity, Vector3.new(v.X, lift, v.Z))
			end
			local id = MobRegistry.chronoIdOf(e)
			if id then hitIds[#hitIds + 1] = id; hitFracs[#hitFracs + 1] = frac end
		end
	end)

	-- CHAIN LIGHTNING upgrade: each level arcs to up to 2 more nearby un-hit mobs for reduced damage. No beam
	-- VFX yet (art) — they just get a hit reaction + health bar, reading as "the strike jumped to them".
	if st.chain > 0 and #hitIds > 0 then
		local extra = st.chain * 2
		local chainDmg = dmg * 0.55
		local center = cf.Position
		MobRegistry.forEach(function(e: any, part: BasePart)
			if extra <= 0 or hitSet[e] then return end
			local d = part.Position - center
			if d.X * d.X + d.Y * d.Y + d.Z * d.Z <= CHAIN_RANGE2 then
				extra -= 1
				hitSet[e] = true
				local hp = world:get(e, Health)
				local frac = 1
				if hp then hp.hp -= chainDmg; world:set(e, Health, hp); frac = math.max(0, hp.hp) / hp.max end
				local id = MobRegistry.chronoIdOf(e)
				if id then hitIds[#hitIds + 1] = id; hitFracs[#hitFracs + 1] = frac end
			end
		end)
	end

	-- tell clients which mobs got hit, WHICH attack did it (hit reaction + matching impact FX), and each
	-- one's HP fraction (→ a health bar). light → Hit1; finisher/heavy → a bigger Hit2.
	if #hitIds > 0 then
		remote:FireAllClients("mobhit", hitIds, n, hitFracs)
	end
end

-- Client says its slam just touched the ground → RELEASE every mob this player has grabbed, flinging each
-- radially OUTWARD from the landing point (the "shockwave scatter"). Collect first, then mutate: removing a
-- queried component mid-iteration is the classic unsafe jecs pattern.
local function onSlamLand(player: Player)
	-- Only a REAL, still-live slam can land: consume it atomically. Dedupes replayed packets (the second
	-- sees nil) and rejects a rogue "slamland" from a client that never slammed → no phantom crater/scatter.
	if not slamming[player] then return end
	slamming[player] = nil -- stop the sweep — the dive is over

	local char = player.Character
	local rootp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local center = rootp and rootp.Position

	local caught: { any } = {}
	for e, grab in world:query(Grabbed) do
		if grab.owner == player then caught[#caught + 1] = e end
	end
	for _, e in caught do
		local part = world:get(e, Hitbox) :: BasePart?
		if part and center then
			local d = part.Position - center
			local flat = Vector3.new(d.X, 0, d.Z)
			local dir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, 1)
			world:set(e, Knock, dir * (MobCfg.SLAM_SCATTER * statsFor(player).slamMul)) -- radial (× Seismic Slam upgrade)
		end
		world:remove(e, Grabbed)
	end

	-- IMPACT DESTRUCTION: rocks + optional voxel carve at the landing point. Server-side so it replicates to
	-- everyone; pcall'd so a module hiccup never breaks combat. RockModule.Crater raycasts down to the floor.
	if center then
		local S = CombatCfg.SLAM
		if RockModule then
			local groundCF = CFrame.new(center)
			pcall(function()
				RockModule.Crater(groundCF, S.CRATER_RADIUS, S.CRATER_ROCKS_MIN, S.CRATER_ROCKS_MAX, false)
				if S.EXPLOSION_ROCKS > 0 then RockModule.Explosion(groundCF, S.EXPLOSION_ROCKS, 0.5, 2.5, false) end
			end)
			-- RockModule's crater rocks linger ~30s — far too long for a combat hit. Fade them out after
			-- DEBRIS_TTL. NOTE: ClearDebris fades the WHOLE Debris folder, so overlapping slams clear each
			-- other's rocks early — fine for co-op/few slams; revisit if it looks off with many at once.
			task.delay(S.DEBRIS_TTL, function()
				if RockModule then pcall(function() RockModule.ClearDebris(true) end) end
			end)
		end
		if S.VOXELIZE and VoxManager then
			pcall(function()
				VoxManager:voxelizePosition(center, S.VOXEL_RADIUS, S.VOXEL_SIZE, S.VOXEL_SIZE, false, true, 1, {})
			end)
		end
	end
end

remote.OnServerEvent:Connect(function(player: Player, kind, a)
	if kind == "attack" and type(a) == "number" then
		onAttack(player, a)
	elseif kind == "slamland" then
		onSlamLand(player)
	elseif kind == "block" then
		-- block state (0/1) — stored for when mob→player attacks land (not built yet), where it
		-- mitigates damage 50% and drains the block meter. TODO: store on the player's ECS entity.
	elseif kind == "picking" then
		setPicking(player, a and true or false) -- on the level-up card screen → freeze the world
	elseif kind == "upgrade" then
		if type(a) == "string" then upgradeStats.apply(statsFor(player), a) end -- fold a level-up pick into this player's stats
	end
end)

-- a player leaving mid-slam must not strand their grabbed mobs frozen (the sim's timeout also covers this,
-- but releasing immediately is cleaner)
game:GetService("Players").PlayerRemoving:Connect(function(p)
	slamming[p] = nil
	releaseGrabs(p)
end)

-- ── Mob → player attacks (basic combo: small knock, medium FINISHER) ────────────────
-- Any mob within range of a player can hit them, but a per-player GATE rate-limits it so a swarm TAKES
-- TURNS instead of knocking you 50×/frame. Every FINISHER_EVERY-th hit is a finisher (medium knock + a
-- longer recovery). Knockback is applied server-side (the character is server-authoritative) and the client
-- is told to play a hit reaction + camera shake. NO player damage yet (no player-HP system) — this is the
-- FEEL of being shoved around by the horde. TODO: mob wind-up telegraph anim; block mitigation; player HP.
local ATTACK_RANGE2     = 6 * 6
local PLAYER_HIT_GAP    = 0.55 -- min seconds between hits landing on a player (the swarm rate-limit)
local FINISHER_RECOVERY = 1.0  -- longer pause after a finisher
local FINISHER_EVERY    = 3
local KNOCK_SMALL, KNOCK_MED, KNOCK_UP = 9, 18, 2 -- a light shove, no stun (reduced — "only a bit knockback")

local playerHit: { [Player]: { nextAt: number, combo: number } } = {}

local LUNGE_CAP = 8   -- max mobs that LUNGE (visually) per scan tick — MANY attack at once, it just looks menacing
local LUNGE_CD  = 0.9 -- per-mob lunge cooldown (so one mob doesn't lunge every tick)
local lungeAt: { [number]: number } = {} -- netId → next allowed lunge time
local lungePruneAcc = 0

local atkAcc = 0
local function mobAttackStep(dt: number)
	if serverPause.paused then return end -- world frozen for a level-up pick
	atkAcc += dt
	if atkAcc < 0.1 then return end -- ~10 Hz scan
	atkAcc = 0
	local now = os.clock()
	-- prune the lunge-cooldown table now and then (dead mobs' monotonic netIds never get overwritten)
	lungePruneAcc += 0.1
	if lungePruneAcc >= 8 then lungePruneAcc = 0; table.clear(lungeAt) end

	for _, player in game:GetService("Players"):GetPlayers() do
		local char = player.Character
		local root = char and (char.PrimaryPart or char:FindFirstChild("HumanoidRootPart")) :: BasePart?
		if not root or picking[player] then continue end -- skip players on the level-up screen
		local pos = root.Position

		-- ONE scan: gather up to LUNGE_CAP in-range mobs (off their lunge cooldown) to animate, AND track the
		-- nearest for the knockback. LUNGES are unthrottled per-player (many mobs strike at once = menacing);
		-- the KNOCKBACK is still gated (one landing per PLAYER_HIT_GAP) so the swarm can't knock-spam you.
		local lungers: { number } = {}
		local bestD2, bx, bz, found = ATTACK_RANGE2, 0, 0, false
		MobRegistry.forEach(function(e: any, part: BasePart)
			local p = part.Position
			local dx, dz = pos.X - p.X, pos.Z - p.Z
			local d2 = dx * dx + dz * dz
			if d2 < ATTACK_RANGE2 then
				local id = MobRegistry.chronoIdOf(e)
				if id then
					if #lungers < LUNGE_CAP and now >= (lungeAt[id] or 0) then
						lungeAt[id] = now + LUNGE_CD
						lungers[#lungers + 1] = id
					end
					if d2 < bestD2 then bestD2 = d2; bx = dx; bz = dz; found = true end
				end
			end
		end)

		if #lungers > 0 then remote:FireAllClients("mobattack", lungers) end -- MANY mobs lunge at once

		if found then -- knockback (gated)
			local st = playerHit[player]
			if not st then st = { nextAt = 0, combo = 0 }; playerHit[player] = st end
			if now >= st.nextAt then
				local m = math.sqrt(bx * bx + bz * bz)
				local dir = if m < 1e-3 then Vector3.new(0, 0, 1) else Vector3.new(bx / m, 0, bz / m)
				st.combo += 1
				local finisher = st.combo % FINISHER_EVERY == 0
				root.AssemblyLinearVelocity = dir * (if finisher then KNOCK_MED else KNOCK_SMALL) + Vector3.new(0, KNOCK_UP, 0)
				remote:FireClient(player, "playerhit", dir, finisher)
				st.nextAt = now + (if finisher then FINISHER_RECOVERY else PLAYER_HIT_GAP)
			end
		end
	end
end

game:GetService("Players").PlayerRemoving:Connect(function(p)
	lastAttackAt[p] = nil
	slamming[p] = nil
	playerHit[p] = nil
	setPicking(p, false) -- decrements pickingCount if they left mid-pick
	playerStats[p] = nil
end)

scheduler.SYSTEM(slamStep, phases.Heartbeat) -- continuous slam grab-sweep (only works when someone's slamming)
scheduler.SYSTEM(mobAttackStep, phases.Heartbeat) -- mob→player knockback + hit reaction
return 0
