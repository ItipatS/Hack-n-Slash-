-- ServerScriptService/systems/mobs.luau
-- Server MOB pipeline. Each mob = an ECS entity + a bare anchored hitbox part (its collision/hit
-- presence) living under ServerStorage, so Roblox NEVER replicates it — clients build their own rigs.
--
-- REPLICATION: our OWN Blink dense-slot lane (NOT Chrono — Chrono's 16 bytes/mob at flat 20Hz doesn't
-- scale to 500+ enemies). Positions stream WITHOUT a per-mob id: i8 fixed-point deltas written in SLOT
-- order (client maps slot→mob from the Spawn payload) + a periodic absolute f32 snapshot to clear drift.
-- Wire constants shared with the client via std/config.luau `Net`. ~3 bytes/mob vs Chrono's 16.
--   • Spawn (reliable)              → client acquires a rig, learns id + slot
--   • UpdateTransformDelta (unrel.) → i8 slot-ordered position deltas, the bulk of the bandwidth
--   • UpdateTransformFull (reliable)→ absolute f32 snapshot (drift/slot-churn correction) + warp fallback
--   • Death (reliable)             → client releases the rig, frees the slot map
--   • CombatRemote "mobdeath"      → cosmetic flung corpse (kept on the CombatRemote; skipped on silent clear)
--
-- Movement is DIRECT reactive steering (CLAUDE.md: no navmesh): nearest-player chase + positional
-- separation + anti-orbit + settle. Facing is NOT computed here — the client derives it from the streamed
-- motion (we stream position only).
--
-- GROUND/WALL (raw-map first pass — MobCfg.GROUND_CAST / WALL_CAST): a moving mob RE-CASTS the floor only
-- after crossing GROUND_RECAST_D studs (idle = 0 casts; CLAUDE.md: never cast at sim rate) and eases its Y
-- onto it (steps up ledges ≤ STEP_HEIGHT, falls off drops via the normal gravity path). Before integrating
-- it BLOCKCASTS its footprint along the move and slides along anything steeper than WALL_STEEP. All casts
-- share ONE RaycastParams that excludes players + rock/voxel debris (rebuilt on the player set). This hits
-- RAW geometry — the eventual simplified collision shell is the scaling answer; see mobConfig.
--!optimize 2
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage     = game:GetService("ServerStorage")
local Players           = game:GetService("Players")

local blink = require(ServerScriptService.ServerNet)

local std         = ReplicatedStorage.std
local world       = require(std.world)
local cts         = require(std.components)
local scheduler   = require(std.scheduler)
local phases      = require(std.phases)
local SpatialHash = require(std.spatialhash)
local MobCfg      = require(std.mobConfig)
local MobRegistry = require(std.mobRegistry)
local Config      = require(std.config)
local serverPause = require(std.serverPause) -- freeze movement + waves while a player is on the level-up screen

local Mob       = cts.Mob
local Health    = cts.Health
local Hitbox    = cts.Hitbox
local Velocity  = cts.Velocity
local Knock      = cts.Knock
local Character  = cts.Character
local Player     = cts.Player
local Slot       = cts.Slot
local Grabbed    = cts.Grabbed

local KNOCK_DECAY = MobCfg.KNOCK_DECAY -- knockback impulse decay rate (1/sec); total throw ≈ knock/this
local MOB_TYPE    = "MOB"
local LAND_EPS    = 0.05 -- studs above its ground Y before a mob counts as ALOFT (launched)

-- The Y each mob rests at. Seeded by the spawn ground-cast; with GROUND_CAST on it's RE-CAST as the mob
-- moves (gated by GROUND_RECAST_D below) so it follows terrain. A launched mob falls back to this on landing.
local groundYOf: { [any]: number } = {}
-- XZ where each mob last re-cast its floor — the gate for the next re-cast (moved > GROUND_RECAST_D). Only Y
-- is ignored; we store the whole Vector3 for cheap squared-distance. Cleared on despawn.
local lastCastXZ: { [any]: Vector3 } = {}
-- wave/demo counters: liveCount = spawned − despawned; killCount = normal deaths (not silent clears). Pushed
-- to the wave HUD. (liveCount is authoritative "alive" — cheaper than iterating the query each broadcast.)
local liveCount, killCount = 0, 0

-- collision constants (derived from mobConfig; hoisted out of the hot loop)
local HALF_H      = MobCfg.HITBOX_SIZE.Y * 0.5
local STEP_H      = MobCfg.STEP_HEIGHT
local CLIMB_REACH = MobCfg.CLIMB_REACH
local KILL_Y      = MobCfg.KILL_Y
local GRD_RECAST2 = MobCfg.GROUND_RECAST_D * MobCfg.GROUND_RECAST_D
local GRD_DOWN    = Vector3.new(0, -(CLIMB_REACH + MobCfg.GROUND_DOWN), 0) -- down-ray from feet+CLIMB_REACH
local WALL_BOX    = Vector3.new(MobCfg.HITBOX_SIZE.X, math.max(0.5, MobCfg.HITBOX_SIZE.Y - STEP_H), MobCfg.HITBOX_SIZE.Z) -- footprint probe: torso band above the step zone
local WALL_STEEP  = MobCfg.WALL_STEEP
local WALL_MIN2   = MobCfg.WALL_MIN_MOVE * MobCfg.WALL_MIN_MOVE

-- net constants (shared with the client via std/config.luau)
local Net        = Config.Net
local STEP       = Net.STEP
local INV_STEP   = 1 / Net.STEP
local WARP       = Net.WARP_THRESH
local CHUNK      = Net.CHUNK
local NET_TICK   = Net.NET_TICK
local FULL_EVERY = Net.FULL_EVERY

-- shared CombatRemote (systems/combat OR this system, whichever loads first, creates it) — carries the
-- cosmetic mobdeath corpse (fling) + the mobhit reactions. Position streaming is Blink, not here.
local remote: RemoteEvent
local existing = ReplicatedStorage:FindFirstChild("CombatRemote")
if existing and existing:IsA("RemoteEvent") then
	remote = existing
else
	remote = Instance.new("RemoteEvent")
	remote.Name = "CombatRemote"
	remote.Parent = ReplicatedStorage
end

-- ── Hitbox container: a server-only folder. Parts here never replicate (clients build their own rigs)
-- but still give us a real, queryable-by-us CFrame for the sim + the combat OBB. Anchored (kinematic —
-- no solver), CanCollide/CanQuery off.
local hitboxFolder = Instance.new("Folder")
hitboxFolder.Name = "MobHitboxes"
hitboxFolder.Parent = ServerStorage

-- ONE shared RaycastParams for every world cast (spawn ground snap + sim ground/wall). Hitboxes live in
-- ServerStorage (never in workspace), so we only need to exclude the OTHER dynamic non-terrain in workspace:
-- player characters (mobs shouldn't stand on / wall-off a player) and RockModule's rock/voxel debris. It's
-- rebuilt whenever the player set changes + on a ~1s cadence (the debris folders appear at runtime).
local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Exclude
worldParams.IgnoreWater = true
worldParams.RespectCanCollide = true -- only SOLID geometry is floor/wall — not CanCollide=false decor/foliage
                                     -- /props (which aren't in the excluded debris folders). Revisit if the
                                     -- future collision shell is authored CanCollide=false (it won't be).
local DEBRIS_FOLDERS = { "RockDebris", "Debris", "VoxelCache", "MobCorpses" }
local function rebuildFilter()
	local exclude: { Instance } = {}
	for _, pl in Players:GetPlayers() do
		if pl.Character then exclude[#exclude + 1] = pl.Character end
	end
	for _, name in DEBRIS_FOLDERS do
		local f = workspace:FindFirstChild(name)
		if f then exclude[#exclude + 1] = f end
	end
	worldParams.FilterDescendantsInstances = exclude
end
rebuildFilter()
Players.PlayerAdded:Connect(function(pl)
	pl.CharacterAdded:Connect(rebuildFilter)
	rebuildFilter()
end)
Players.PlayerRemoving:Connect(rebuildFilter)
for _, pl in Players:GetPlayers() do pl.CharacterAdded:Connect(rebuildFilter) end

local function groundY(x: number, z: number): number
	local from = Vector3.new(x, MobCfg.SPAWN_ORIGIN.Y + 200, z)
	local hit = workspace:Raycast(from, Vector3.new(0, -1000, 0), worldParams)
	return (hit and hit.Position.Y or MobCfg.SPAWN_ORIGIN.Y) + MobCfg.FOOT_OFFSET
end

-- ── Dense replication slot allocator (reuse freed slots lowest-first → the live range stays dense so
-- the delta stream has no gaps) + a monotonic u32 net id (the Spawn/Death/mobhit key; the SLOT is only the
-- position-stream index). A separate net id avoids reusing an id while a client might still hold the old rig.
local freeSlots: { number } = {}
local nextSlot = 0
local function allocSlot(): number
	local n = #freeSlots
	if n > 0 then local s = freeSlots[n]; freeSlots[n] = nil; return s end
	local s = nextSlot; nextSlot += 1; return s
end

local nextNetId = 1

-- batch spawns fired at end of the spawn burst
local spawnBatch: { blink.MobSpawn } = {}
local function flushSpawn()
	if #spawnBatch > 0 then blink.Spawn.FireAll(spawnBatch); table.clear(spawnBatch) end
end

local function spawnMob(pos: Vector3)
	local part = Instance.new("Part")
	part.Name         = "MobHitbox"
	part.Size         = MobCfg.HITBOX_SIZE
	part.Anchored     = true
	part.CanCollide   = false
	part.CanQuery     = false
	part.Transparency = 1
	part.CFrame       = CFrame.new(pos)
	part.Parent       = hitboxFolder

	local e = world:entity()
	local slot = allocSlot()
	local netId = nextNetId; nextNetId += 1
	world:add(e, Mob)
	world:set(e, Hitbox, part)
	world:set(e, Velocity, Vector3.zero)
	world:set(e, Health, { hp = MobCfg.HP, max = MobCfg.HP })
	world:set(e, Slot, slot)
	groundYOf[e] = pos.Y -- spawn Y already includes the ground cast + FOOT_OFFSET; launches fall back to it
	lastCastXZ[e] = pos  -- floor already resolved at this XZ → next re-cast waits for GROUND_RECAST_D of travel
	liveCount += 1
	MobRegistry.register(netId, part, e) -- netId ↔ part ↔ entity (combat resolves an OBB hit → this entity)

	spawnBatch[#spawnBatch + 1] = { id = netId, slot = slot, pos = pos, size = 1, type = MOB_TYPE, tier = 0 }
end

-- despawn: tell clients to drop the rig, recycle the slot, delete the ECS entity + hitbox part.
--   • normal death  → CombatRemote "mobdeath"(netId, cf, fling): client releases the rig AND spawns the
--                     cosmetic flung corpse (one signal for the whole death flourish).
--   • silent clear  → Blink Death({netId}): client just releases the rig (no corpse).
local function despawnMob(e: any, silent: boolean?)
	local part = world:get(e, Hitbox) :: BasePart?
	local netId = MobRegistry.chronoIdOf(e)
	local slot = world:get(e, Slot)

	if silent then
		if netId then blink.Death.FireAll({ netId }) end
	elseif netId then
		killCount += 1 -- a real death (not a silent clear) → counts toward the wave-demo kill score
		local k = world:get(e, Knock)
		local dir = if k and (k.X ~= 0 or k.Z ~= 0) then k.Unit else Vector3.zero
		remote:FireAllClients("mobdeath", netId, part and part.CFrame or CFrame.new(), dir * MobCfg.DEATH_FLING)
	end
	liveCount -= 1

	if netId then MobRegistry.unregister(netId, part) end
	if slot then freeSlots[#freeSlots + 1] = slot end
	if part then part:Destroy() end
	groundYOf[e] = nil
	lastCastXZ[e] = nil
	world:delete(e)
end

-- ── Sim ───────────────────────────────────────────────────────────────────────────
local mobQuery  = world:query(Hitbox, Velocity):with(Mob):cached()
local charQuery = world:query(Character, Player):cached()

local hash  = SpatialHash.new(6)
local out:   { number } = {}
local posOf: { [number]: Vector3 } = {}
local pPos:  { Vector3 } = {}

local SEP_R2       = MobCfg.SEP_RADIUS * MobCfg.SEP_RADIUS
local CONTACT2     = MobCfg.CONTACT * MobCfg.CONTACT
local ORBIT_BAND2  = MobCfg.ORBIT_BAND * MobCfg.ORBIT_BAND
local SETTLE_BAND2 = (MobCfg.CONTACT + MobCfg.SETTLE_PAD) ^ 2
local BLOCK_R2     = MobCfg.BLOCK_RADIUS * MobCfg.BLOCK_RADIUS
local BLOCK_CONE   = MobCfg.BLOCK_CONE

local function gatherPlayers()
	table.clear(pPos)
	for _e, char in charQuery do
		local root = (char :: Model).PrimaryPart
		if root then
			pPos[#pPos + 1] = root.Position
		end
	end
end

local acc = 0
local filterAcc = 0
local function simStep(dt: number)
	if serverPause.paused then return end -- level-up pick: freeze the horde (don't accumulate → no catch-up jump)
	acc += dt
	if acc < MobCfg.MOVE_TICK then return end
	local step = acc
	acc = 0

	-- refresh the cast filter ~1×/sec so runtime-created debris folders (RockModule) get excluded, and any
	-- player-set change the events missed is caught. Cheap (few players + 4 FindFirstChild).
	filterAcc += step
	if filterAcc >= 1 then filterAcc = 0; rebuildFilter() end

	-- SAFETY: release slam-grabs whose land signal never came (combat's onSlamLand is the normal path).
	-- Collect THEN remove — mutating a queried component mid-iteration is the unsafe jecs pattern.
	local stale: { any }? = nil
	for e, grab in world:query(Grabbed) do
		if (os.clock() - grab.t0) > MobCfg.SLAM_GRAB_MAX then
			stale = stale or {}
			stale[#stale + 1] = e
		end
	end
	if stale then for _, e in stale do world:remove(e, Grabbed) end end

	gatherPlayers()

	hash:beginFrame()
	table.clear(posOf)
	for e, part in mobQuery do
		local p = part.Position
		posOf[e] = p
		hash:insert(e, p.X, p.Y, p.Z)
	end

	local haveTarget = #pPos > 0
	local fell: { any }? = nil -- mobs that dropped below KILL_Y this tick (collect-then-despawn; never mid-query)
	for e, part, vel in mobQuery do
		local pos = posOf[e]
		local gy = groundYOf[e] or pos.Y
		local vy = vel.Y

		-- GRABBED by a slam → dragged straight down, held until the player lands (combat scatters it).
		local grabbed = world:get(e, Grabbed) ~= nil

		-- GROUND RE-CAST (gated): once this mob has travelled GROUND_RECAST_D from its last cast, drop a ray
		-- from feet+STEP_H down to find the current floor and update its rest Y. Idle mobs never cross the
		-- gate → 0 casts. Skipped while grabbed (on slam rails). The ray STARTING above the feet is what lets
		-- a mob step UP onto a low ledge; a floor found BELOW just lowers gy, so the aloft test below flips
		-- true and the mob falls to it via gravity (no teleport).
		if MobCfg.GROUND_CAST and not grabbed then
			local lc = lastCastXZ[e]
			local dxc, dzc = pos.X - lc.X, pos.Z - lc.Z
			if dxc * dxc + dzc * dzc >= GRD_RECAST2 then
				lastCastXZ[e] = pos
				local from = Vector3.new(pos.X, pos.Y - HALF_H + CLIMB_REACH, pos.Z)
				local hit = workspace:Raycast(from, GRD_DOWN, worldParams)
				if hit then
					gy = hit.Position.Y + MobCfg.FOOT_OFFSET; groundYOf[e] = gy
				else
					-- NO floor within GROUND_DOWN → a real void (deeper than any map drop). Sentinel gy so the
					-- aloft test below flips true and the mob FALLS (gravity) instead of hovering at the rim;
					-- KILL_Y recycles it when it's clearly gone. (A found floor BELOW just lowers gy → same
					-- gravity path, so normal ledge drops fall correctly too.)
					gy = -math.huge; groundYOf[e] = gy
				end
			end
		end

		-- ALOFT = launched by a `lift` attack (or grabbed) and not landed yet. A mob in the air is in
		-- HITSTUN: it does NOT steer, separate, anti-orbit or settle — otherwise it would helicopter toward
		-- you mid-juggle instead of arcing. Only gravity + its (decaying) horizontal knock apply.
		local aloft = grabbed or vy ~= 0 or pos.Y > gy + LAND_EPS

		local moveX, moveZ = 0, 0
		if not aloft then
			-- nearest player (XZ)
			local tx, tz, bestD2 = pos.X, pos.Z, math.huge
			if haveTarget then
				for _, pp in pPos do
					local dx, dz = pp.X - pos.X, pp.Z - pos.Z
					local d2 = dx * dx + dz * dz
					if d2 < bestD2 then bestD2 = d2; tx = pp.X; tz = pp.Z end
				end
			end

			-- steer toward the player unless already in contact range (unit vector)
			local steerX, steerZ = 0, 0
			if haveTarget and bestD2 > CONTACT2 then
				steerX, steerZ = tx - pos.X, tz - pos.Z
				local m = math.sqrt(steerX * steerX + steerZ * steerZ)
				if m > 1e-4 then steerX, steerZ = steerX / m, steerZ / m end
			end

			-- separation from neighbours (accumulated, weighted by closeness) + ARRIVAL blocking check.
			-- `blocked` = some neighbour is AHEAD of me (toward the player) AND closer to the player → I've
			-- reached the back of the crowd, so I stop steering inward (below) and just hold + separate. The
			-- closest mob has no one closer→ahead, so it's never blocked → the front always presses.
			local sepX, sepZ = 0, 0
			local blocked = false
			local cnt = hash:queryInto(pos.X, pos.Y, pos.Z, out)
			for j = 1, cnt do
				local k = out[j]
				if k ~= e then
					local qp = posOf[k]
					if qp then
						local dx, dz = pos.X - qp.X, pos.Z - qp.Z
						local d2 = dx * dx + dz * dz
						if d2 > 1e-4 and d2 < SEP_R2 then
							local d = math.sqrt(d2)
							local w = (MobCfg.SEP_RADIUS - d) / MobCfg.SEP_RADIUS
							sepX += dx / d * w
							sepZ += dz / d * w
						end
						-- arrival: is this neighbour between me and the player? (closer to the player + within my
						-- forward cone). steerX/Z is my unit dir to the player, so toNeighbour·steer = |toN|·cosθ.
						if not blocked and haveTarget and d2 > 1e-4 and d2 < BLOCK_R2 then
							local nx2, nz2 = tx - qp.X, tz - qp.Z
							if nx2 * nx2 + nz2 * nz2 < bestD2 then -- neighbour is closer to the player than me
								local tkx, tkz = qp.X - pos.X, qp.Z - pos.Z -- toward the neighbour
								if tkx * steerX + tkz * steerZ > BLOCK_CONE * math.sqrt(d2) then blocked = true end
							end
						end
					end
				end
			end

			-- ARRIVAL + SURROUND: a blocked mob doesn't just STOP (that queues them into a wedge behind the
			-- front) — it flows TANGENTIALLY around the player toward the OPEN arc, so the crowd spreads and
			-- surrounds. The open direction is separation's component perpendicular to the player-radial (points
			-- at the less-crowded side); it fades to 0 when the arc is even, so mobs settle instead of spinning.
			if blocked then
				steerX, steerZ = 0, 0
				if haveTarget and bestD2 > 1e-4 then
					local inv = 1 / math.sqrt(bestD2)
					local rx, rz = (pos.X - tx) * inv, (pos.Z - tz) * inv -- radial-out unit (player → mob)
					local dot = sepX * rx + sepZ * rz
					local tanX, tanZ = sepX - dot * rx, sepZ - dot * rz    -- separation minus its radial part
					local tm = math.sqrt(tanX * tanX + tanZ * tanZ)
					if tm > 1e-3 then
						steerX, steerZ = (tanX / tm) * MobCfg.BLOCK_FLOW, (tanZ / tm) * MobCfg.BLOCK_FLOW
					else
						-- directly behind another mob (no lateral crowd to flow toward) → this is the SINGLE-FILE
						-- QUEUE case. Peel to a fixed side (stable per mob via e%2) — the tangent to the radial —
						-- so lines break into arcs and wrap AROUND the player instead of stacking in front.
						local side = if e % 2 == 0 then 1 else -1
						steerX, steerZ = -rz * side * MobCfg.BLOCK_FLOW, rx * side * MobCfg.BLOCK_FLOW
					end
				end
			end

			-- MOVE = steer velocity + a CLAMPED separation push (positional relaxation — keeps mobs spaced)
			moveX = steerX * MobCfg.SPEED
			moveZ = steerZ * MobCfg.SPEED
			local sepMag = math.sqrt(sepX * sepX + sepZ * sepZ)
			if sepMag > 1e-4 then
				local s = math.min(sepMag, MobCfg.SEP_CLAMP) / sepMag * MobCfg.SEP_PUSH
				moveX += sepX * s
				moveZ += sepZ * s
			end

			-- anti-orbit: strip the tangential (circling) component so the PRESSING (unblocked) ring goes
			-- straight in. Skipped for BLOCKED mobs — their tangential motion is the intentional SURROUND flow.
			if not blocked and haveTarget and bestD2 < ORBIT_BAND2 and bestD2 > 1e-4 then
				local rl = math.sqrt(bestD2)
				local rx, rz = (tx - pos.X) / rl, (tz - pos.Z) / rl
				local radial = moveX * rx + moveZ * rz
				moveX -= (moveX - radial * rx) * MobCfg.ORBIT_DAMP
				moveZ -= (moveZ - radial * rz) * MobCfg.ORBIT_DAMP
			end

			-- settle: in melee range, cut movement so mobs plant instead of shuffling
			if haveTarget and bestD2 < SETTLE_BAND2 then
				moveX *= MobCfg.SETTLE
				moveZ *= MobCfg.SETTLE
			end

			-- WALL: shapecast the footprint (a torso-band box, above the step zone so ledges aren't walls)
			-- along the intended move. Hit a STEEP face (normal.Y < WALL_STEEP) → slide by removing the
			-- into-wall component of the move; walkable ramps pass through (the ground recast climbs them).
			-- Only grounded mobs (this branch), so a launched/knocked mob can still pass a wall — acceptable
			-- first-pass limit (see mobConfig). One slide iteration → corners can nick.
			if MobCfg.WALL_CAST and (moveX ~= 0 or moveZ ~= 0) then
				local dx, dz = moveX * step, moveZ * step
				-- skip near-stationary mobs (the settled melee ring): they can't traverse anything, and they
				-- are the densest cluster — casting them all every tick is the big raw-geometry cost.
				if dx * dx + dz * dz >= WALL_MIN2 then
					local boxCF = CFrame.new(pos.X, pos.Y + STEP_H * 0.5, pos.Z)
					local whit = workspace:Blockcast(boxCF, WALL_BOX, Vector3.new(dx, 0, dz), worldParams)
					if whit and whit.Normal.Y < WALL_STEEP then
						local nX, nZ = whit.Normal.X, whit.Normal.Z
						local nm = math.sqrt(nX * nX + nZ * nZ)
						if nm > 1e-3 then
							nX, nZ = nX / nm, nZ / nm
							local into = moveX * nX + moveZ * nZ
							if into < 0 then -- moving INTO the wall → cancel that component (slide along it)
								moveX -= into * nX
								moveZ -= into * nZ
							end
						else
							moveX, moveZ = 0, 0 -- degenerate (near-flat normal) → just stop
						end
					end
				end
			end
		end

		-- integrate XZ
		local nx = pos.X + moveX * step
		local nz = pos.Z + moveZ * step

		-- knockback impulse (combat sets this on hit; decays to zero). Applies aloft too — it's the
		-- horizontal half of a launch arc.
		local k = world:get(e, Knock)
		if k and (k.X ~= 0 or k.Z ~= 0) then
			nx += k.X * step
			nz += k.Z * step
			local nk = k * math.exp(-KNOCK_DECAY * step)
			if nk.X * nk.X + nk.Z * nk.Z < 1 then nk = Vector3.zero end
			world:set(e, Knock, nk)
		end

		-- VERTICAL: kinematic gravity (no solver — CLAUDE.md), clamped back onto this mob's ground on landing.
		-- A GRABBED mob is dragged DOWN at a fixed speed (not gravity) and PINNED at ground — it stays there,
		-- still grabbed, until combat's onSlamLand scatters it (removing Grabbed → normal physics resumes).
		local ny = pos.Y
		if grabbed then
			vy = -MobCfg.SLAM_DRAG
			ny = pos.Y + vy * step
			if ny <= gy then ny = gy; vy = 0 end
		elseif aloft then
			vy -= MobCfg.GRAVITY * step
			ny = pos.Y + vy * step
			if ny <= gy then ny = gy; vy = 0 end -- landed → grounded again next tick, steering resumes
		else
			-- GROUNDED: ease Y toward the (re-cast) ground so stepping onto a ledge is a soft rise, not a
			-- teleport. gy is never far BELOW here (a drop makes `aloft` true above → the gravity path), so
			-- this only ever nudges up onto steps ≤ STEP_HEIGHT or holds flat.
			local dy = gy - pos.Y
			if dy > 0.01 or dy < -0.01 then ny = pos.Y + dy * math.min(1, MobCfg.GROUND_SNAP * step) else ny = gy end
		end

		-- position only (no rotation — yaw isn't streamed; the client derives facing from motion). SKIP the
		-- writes for a mob that didn't actually move: idle mobs then cost 0 allocs + 0 writes (matching the
		-- idle=0-casts intent). The stream diffs against part.Position, so a held position is simply a zero
		-- delta that isn't sent. Velocity is still set on the moving→stopped edge (vel.* ~= 0) to zero it once.
		local moved = nx ~= pos.X or ny ~= pos.Y or nz ~= pos.Z
		if moved then part.CFrame = CFrame.new(nx, ny, nz) end
		if moved or vy ~= 0 or vel.X ~= 0 or vel.Z ~= 0 then
			world:set(e, Velocity, Vector3.new((nx - pos.X) / step, vy, (nz - pos.Z) / step))
		end

		-- kill-plane: a mob that fell past KILL_Y (void with no floor within GROUND_DOWN) is recycled
		if ny < KILL_Y then
			fell = fell or {}
			fell[#fell + 1] = e
		end
	end

	-- silent despawn of the void-fallen (before the death pass re-queries; no corpse for a fall)
	if fell then for _, e in fell do despawnMob(e, true) end end

	-- death pass: combat drains Health; collect the dead THEN despawn (never delete mid-query)
	local dead: { any }? = nil
	for e in world:query(Health):with(Mob) do
		local hp = world:get(e, Health)
		if hp and hp.hp <= 0 then
			dead = dead or {}
			dead[#dead + 1] = e
		end
	end
	if dead then
		for _, e in dead do despawnMob(e) end
	end
end

-- ── Streaming (dense-slot + i8 deltas) ─────────────────────────────────────────────
local streamQuery = world:query(Hitbox, Slot):with(Mob):cached()

local lastSent:   { [number]: Vector3 } = {}  -- slot → the position the client has integrated (diff base)
local slotOwner:  { [number]: number } = {}   -- slot → entity in it now (re-base a reused slot)
local scratchPos: { [number]: Vector3 } = {}
local scratchEnt: { [number]: number } = {}
local warpFull:  { { id: number, dp: Vector3 } } = {}
local fullBatch: { { id: number, dp: Vector3 } } = {}

-- DEBUG_NET counters: the PAYLOAD bytes we actually pack (excludes Roblox/Blink framing, so the true
-- figure is a little higher — plenty to verify the order of magnitude / the ~26 KB/s @ 500 target).
local dbgMobs, dbgDeltaB, dbgFullB, dbgAcc = 0, 0, 0, 0

local function sendDeltas()
	table.clear(scratchPos)
	table.clear(scratchEnt)
	table.clear(warpFull)

	local maxSlot, nMobs = -1, 0
	for e, part, slot in streamQuery do
		scratchPos[slot] = part.Position
		scratchEnt[slot] = e
		nMobs += 1
		if slot > maxSlot then maxSlot = slot end
	end
	dbgMobs = nMobs
	if maxSlot < 0 then return end

	for base = 0, maxSlot, CHUNK do
		local hi = math.min(base + CHUNK - 1, maxSlot)
		local deltas = table.create((hi - base + 1) * 3)
		local di = 0
		for slot = base, hi do
			local pos = scratchPos[slot]
			if pos then
				-- a recycled slot with a new occupant: re-base so we don't emit a bogus jump
				if slotOwner[slot] ~= scratchEnt[slot] then
					slotOwner[slot] = scratchEnt[slot]
					lastSent[slot] = pos
				end
				local last = lastSent[slot]
				local dx, dy, dz = pos.X - last.X, pos.Y - last.Y, pos.Z - last.Z
				if dx > WARP or dx < -WARP or dy > WARP or dy < -WARP or dz > WARP or dz < -WARP then
					-- teleport i8 can't carry → send an absolute, zero the delta
					warpFull[#warpFull + 1] = { id = MobRegistry.chronoIdOf(scratchEnt[slot]) :: number, dp = pos }
					lastSent[slot] = pos
					deltas[di + 1] = 0; deltas[di + 2] = 0; deltas[di + 3] = 0
				else
					local qx = math.clamp(math.round(dx * INV_STEP), -127, 127)
					local qy = math.clamp(math.round(dy * INV_STEP), -127, 127)
					local qz = math.clamp(math.round(dz * INV_STEP), -127, 127)
					deltas[di + 1] = qx; deltas[di + 2] = qy; deltas[di + 3] = qz
					-- advance by the QUANTIZED amount so the sub-step residual carries forward (no drift)
					lastSent[slot] = Vector3.new(last.X + qx * STEP, last.Y + qy * STEP, last.Z + qz * STEP)
				end
			else
				deltas[di + 1] = 0; deltas[di + 2] = 0; deltas[di + 3] = 0 -- transient slot gap
			end
			di += 3
		end
		blink.UpdateTransformDelta.FireAll({ base = base, deltas = deltas })
		dbgDeltaB += #deltas + 4 -- n×i8 + base(u16) + array length prefix
	end

	if #warpFull > 0 then
		dbgFullB += #warpFull * 16 + 2 -- each: id(u32) + dp(vector<f32>)
		blink.UpdateTransformFull.FireAll(warpFull); table.clear(warpFull)
	end
end

-- periodic absolute snapshot (reliable) → clears accumulated drift + any slot-churn mismatch
local function sendFull()
	table.clear(fullBatch)
	local sent = 0
	for e, part, slot in streamQuery do
		local pos = part.Position
		local netId = MobRegistry.chronoIdOf(e)
		if netId then
			lastSent[slot] = pos -- rebase so deltas resume from the corrected position
			slotOwner[slot] = e
			fullBatch[#fullBatch + 1] = { id = netId, dp = pos }
			sent += 1
			if #fullBatch >= 128 then blink.UpdateTransformFull.FireAll(fullBatch); table.clear(fullBatch) end
		end
	end
	if #fullBatch > 0 then blink.UpdateTransformFull.FireAll(fullBatch); table.clear(fullBatch) end
	dbgFullB += sent * 16 + 2
end

local netAcc, fullAcc = 0, 0
local function netStep(dt: number)
	netAcc += dt
	fullAcc += dt

	-- seam #1: what the mob lane ACTUALLY costs. `per client` is the payload one client receives; the
	-- server uploads that × the player count (FireAll broadcasts the same bytes to everyone).
	if MobCfg.DEBUG_NET then
		dbgAcc += dt
		if dbgAcc >= 1 then
			local perClient = (dbgDeltaB + dbgFullB) / dbgAcc
			local nPlayers = #Players:GetPlayers()
			print(("[mobs/net] %d mobs | delta %d B/s | full %d B/s | TOTAL %.1f KB/s per client (x%d players = %.1f KB/s up)")
				:format(dbgMobs, dbgDeltaB // dbgAcc, dbgFullB // dbgAcc, perClient / 1024, nPlayers, perClient * nPlayers / 1024))
			dbgDeltaB, dbgFullB, dbgAcc = 0, 0, 0
		end
	end

	if netAcc < NET_TICK then return end
	netAcc = 0
	sendDeltas()
	if fullAcc >= FULL_EVERY then
		fullAcc = 0
		sendFull()
	end
end

-- ── Late-joiner replay: send the current mob set to a player that just joined ───────
local function sendAllMobsTo(player: Player)
	local payload: { blink.MobSpawn } = {}
	for e, part, slot in streamQuery do
		local netId = MobRegistry.chronoIdOf(e)
		if netId then
			payload[#payload + 1] = { id = netId, slot = slot, pos = part.Position, size = 1, type = MOB_TYPE, tier = 0 }
		end
	end
	if #payload > 0 then blink.Spawn.Fire(player, payload) end
end

-- ── Boot: spawn the test pack (delayed so clients have their Blink handlers up) ──────
task.delay(MobCfg.SPAWN_DELAY, function()
	local origin = MobCfg.SPAWN_ORIGIN
	for i = 1, MobCfg.TEST_COUNT do
		local a = (i / MobCfg.TEST_COUNT) * math.pi * 2
		local x = origin.X + math.cos(a) * MobCfg.SPAWN_RADIUS
		local z = origin.Z + math.sin(a) * MobCfg.SPAWN_RADIUS
		spawnMob(Vector3.new(x, groundY(x, z), z))
	end
	flushSpawn()
	print(("[mobs] spawned %d test mobs (custom Blink lane)"):format(MobCfg.TEST_COUNT))
end)

-- despawn every mob (dev-panel clear — silent, no corpses)
local function clearAll()
	local dead: { any } = {}
	for e in world:query(Health):with(Mob) do
		dead[#dead + 1] = e
	end
	for _, e in dead do despawnMob(e, true) end
end

-- ── Wave director (survival loop; see mobConfig.WAVE) ────────────────────────────────
-- spawning → fighting → breather → next (bigger) wave. Spawns AROUND a player, streams the same Blink lane,
-- and pushes wave/kills/alive/timer to the client HUD over CombatRemote. Toggled from the dev panel.
local WAVE = MobCfg.WAVE
local waveRunning = false
local wave, wavePhase = 0, "idle" -- "idle" | "spawning" | "fighting" | "breather"
local toSpawn, spawnAcc, fightTimer, breatherTimer, bcastAcc = 0, 0, 0, 0, 0
local waveOrigin = MobCfg.SPAWN_ORIGIN

local function anyPlayerPos(): Vector3
	for _e, char in charQuery do
		local root = (char :: Model).PrimaryPart
		if root then return root.Position end
	end
	return MobCfg.SPAWN_ORIGIN
end

-- scatter `count` mobs randomly around `origin` on the wave ring (not a rigid ring — successive batches fill in)
local function spawnScatter(count: number, origin: Vector3)
	for _ = 1, count do
		local a = math.random() * math.pi * 2
		local r = WAVE.RADIUS * (0.8 + math.random() * 0.4)
		local x = origin.X + math.cos(a) * r
		local z = origin.Z + math.sin(a) * r
		spawnMob(Vector3.new(x, groundY(x, z), z))
	end
	flushSpawn()
end

local function broadcastWave()
	remote:FireAllClients("wave", {
		wave = wave,
		phase = wavePhase,
		alive = liveCount,
		kills = killCount,
		timer = if wavePhase == "breather" then math.max(0, breatherTimer) else 0,
	})
end

local function startWave()
	wave += 1
	toSpawn = math.min(WAVE.MAX, WAVE.BASE + (wave - 1) * WAVE.GROW)
	spawnAcc = 0
	wavePhase = "spawning"
	waveOrigin = anyPlayerPos()
	broadcastWave()
	print(("[waves] wave %d — %d mobs"):format(wave, toSpawn))
end

local function waveStep(dt: number)
	if not waveRunning or serverPause.paused then return end -- frozen during a level-up pick
	bcastAcc += dt
	if wavePhase == "spawning" then
		spawnAcc += dt
		if spawnAcc >= WAVE.SPAWN_EVERY then
			spawnAcc = 0
			local n = math.min(WAVE.SPAWN_BATCH, toSpawn)
			spawnScatter(n, waveOrigin)
			toSpawn -= n
			if toSpawn <= 0 then wavePhase = "fighting"; fightTimer = 0; broadcastWave() end
		end
	elseif wavePhase == "fighting" then
		fightTimer += dt
		if liveCount <= 0 or fightTimer >= WAVE.MAX_WAVE_TIME then
			wavePhase = "breather"; breatherTimer = WAVE.BREATHER; broadcastWave()
		end
	else -- breather
		breatherTimer -= dt
		if breatherTimer <= 0 then startWave() end
	end
	if bcastAcc >= WAVE.BCAST then bcastAcc = 0; broadcastWave() end
end

local function startWaves()
	clearAll() -- fresh field
	killCount, wave = 0, 0
	waveRunning = true
	startWave()
end

local function stopWaves()
	waveRunning = false
	wavePhase = "idle"
	clearAll()
	broadcastWave()
	print("[waves] stopped")
end

-- dev panel (ClientSystems/devPanel) → spawn a pack around the requester / clear the field
remote.OnServerEvent:Connect(function(player: Player, kind, arg)
	if kind == "spawnmobs" then
		local count = math.clamp(tonumber(arg) or 10, 1, 2000)
		local char = player.Character
		local rootp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local origin = if rootp then rootp.Position else MobCfg.SPAWN_ORIGIN
		for i = 1, count do
			local a = (i / count) * math.pi * 2
			local r = MobCfg.SPAWN_RADIUS * 0.6
			local x = origin.X + math.cos(a) * r
			local z = origin.Z + math.sin(a) * r
			spawnMob(Vector3.new(x, groundY(x, z), z))
		end
		flushSpawn()
		print(("[mobs] dev-panel spawned %d"):format(count))
	elseif kind == "clearmobs" then
		clearAll() -- just wipe the field; use the Waves toggle to actually stop the director
		print("[mobs] dev-panel cleared all")
	elseif kind == "waves" then
		if waveRunning then stopWaves() else startWaves() end
	end
end)

scheduler.SYSTEM(simStep, phases.PreSimulation)
scheduler.SYSTEM(waveStep, phases.Heartbeat)
scheduler.SYSTEM(netStep, phases.NetworkDelta)
scheduler.SYSTEM(sendAllMobsTo, phases.PlayerAdded)
for _, p in Players:GetPlayers() do sendAllMobsTo(p) end
return 0
