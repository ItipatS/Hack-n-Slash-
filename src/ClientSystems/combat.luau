-- ClientSystems/combat.luau
-- Local-player MELEE combat: a DMC-like combo state machine. LMB drives a 5-hit light chain, RMB a
-- heavy finisher; inputs are BUFFERED and chain within a lenient window after each attack's active
-- frames. We play the attack animation, draw the hitbox (always-on debug box), and send "attack N" to
-- the server — the SERVER does the authoritative shapecast + damage (systems/combat). Block is HOLD-key:
-- it plays the block anim + tracks a block-HP meter (mob attacks that would drain it don't exist yet, so
-- for now block is feel + meter only). All ids/frames/tunables live in std/combatConfig.
--!strict

local Players            = game:GetService("Players")
local UserInputService   = game:GetService("UserInputService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

local std       = ReplicatedStorage.std
local scheduler = require(std.scheduler)
local phases    = require(std.phases)
local Cfg       = require(std.combatConfig)
local FX        = require(std.fx) -- one-shot swing VFX + whoosh
local PlayerAnim = require(script.Parent.playerAnim) -- to fade locomotion out during a swing
local Mobs      = require(script.Parent.mobs) -- predicted impact FX + damage numbers on every mob in the box

local LP     = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("CombatRemote") :: RemoteEvent
local STANCE = "base" -- current stance (single stance for now; weapon stances later)
local LIGHT  = Cfg.stances[STANCE].light
local HEAVY  = Cfg.stances[STANCE].heavy
local AIR_LIGHT = Cfg.stances[STANCE].air.light
local AIR_HEAVY = Cfg.stances[STANCE].air.heavy
local BLOCK_ANIM = Cfg.stances[STANCE].block

-- ── Character refs ─────────────────────────────────────────────────────────────
local root: BasePart? = nil
local hum: Humanoid? = nil
local animator: Animator? = nil
local trackCache: { [any]: AnimationTrack } = {} -- attack/config row → loaded track

-- movement is locked (WalkSpeed 0) for the whole combo so locomotion doesn't fight the attack anim and
-- the player commits to the swing. Captured on the FIRST swing, restored when the combo returns to neutral.
local movementLocked = false
local savedWalkSpeed = 16

-- ── Combat state ───────────────────────────────────────────────────────────────
local attacking   = false
local attackData: any = nil
local attackNum   = 0           -- 1..5 light, 6 heavy
local attackStart = 0
local didHit      = false       -- fired the active-frame hit for the current attack yet
local slamLandSent = false      -- a slam tells the server ONCE when it touches down → radial scatter. This is
                                -- also the slam's ONE-WAY "has landed" latch (immune to isAirborne flicker —
                                -- a native ground jump after landing must NOT re-enter the diving hold).
local slamLandAt   = 0          -- when the slam first landed → its recovery is anchored HERE, not attackStart
local nextSlamAt   = 0          -- earliest clock time the next SLAM may fire (Cfg.SLAM.COOLDOWN gate)
local dbgShown    = false
local dbgHideAt   = 0           -- the debug box is SELF-TIMED (hidden at this clock time) so it's decoupled
                                -- from attack state — a slam that ends the frame it hits still shows its box
local slamFxAt    = 0           -- throttle for the slam's per-frame predicted impact sparks (down the dive)
local buffered: { kind: string, t: number }? = nil

-- block
local blocking = false
local blockHP  = Cfg.block.HP
local lastBlockHitT = -math.huge
local blockTrack: AnimationTrack? = nil

-- ── Debug hitbox box (always-on visual) ──────────────────────────────────────────
local dbg: BasePart? = nil
local function debugBox(): BasePart
	if dbg then return dbg end
	local p = Instance.new("Part")
	p.Name = "__AttackHitbox"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.Transparency = 0.65
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(255, 70, 70)
	p.Parent = workspace
	dbg = p
	return p
end

-- ── Animation ────────────────────────────────────────────────────────────────────
local function loadTrack(id: number): AnimationTrack?
	if id == 0 or not animator then return nil end
	local a = Instance.new("Animation")
	a.AnimationId = "rbxassetid://" .. id
	local ok, t = pcall(function() return (animator :: Animator):LoadAnimation(a) end)
	if not ok or not t then return nil end
	t.Priority = Enum.AnimationPriority.Action -- overrides locomotion, like the roll
	t.Looped = false -- attacks are one-shots; the slam relies on this to HOLD its last frame while diving
	return t
end

-- Preload every attack clip on character load so the FIRST swing isn't silent. Two steps because
-- LoadAnimation alone doesn't guarantee the asset is DOWNLOADED: (1) build the tracks now so trackCache is
-- warm, (2) ContentProvider:PreloadAsync forces the download. Yields, so it runs in a spawned task.
local ContentProvider = game:GetService("ContentProvider")
local function preloadAttacks()
	if not animator then return end
	local toPreload: { Animation } = {}
	local seen: { [number]: boolean } = {}
	local function warm(data: any)
		if not (data and data.anim and data.anim ~= 0) then return end
		if not trackCache[data] then
			local t = loadTrack(data.anim)
			if t then trackCache[data] = t end
		end
		if not seen[data.anim] then
			seen[data.anim] = true
			local a = Instance.new("Animation")
			a.AnimationId = "rbxassetid://" .. data.anim
			toPreload[#toPreload + 1] = a
		end
	end
	for _, d in LIGHT do warm(d) end
	warm(HEAVY)
	for _, d in AIR_LIGHT do warm(d) end
	warm(AIR_HEAVY)
	if BLOCK_ANIM and BLOCK_ANIM ~= 0 and not seen[BLOCK_ANIM] then
		local a = Instance.new("Animation"); a.AnimationId = "rbxassetid://" .. BLOCK_ANIM
		toPreload[#toPreload + 1] = a
	end
	if #toPreload > 0 then
		task.spawn(function()
			pcall(function() ContentProvider:PreloadAsync(toPreload) end)
			for _, a in toPreload do a:Destroy() end
		end)
	end
end

local function playAttackAnim(data: any)
	local t = trackCache[data]
	if not t then
		t = loadTrack(data.anim)
		if t then trackCache[data] = t end
	end
	if t then t:Play(0.05) end
end

-- ── Attack flow ────────────────────────────────────────────────────────────────
local function startAttack(num: number, data: any)
	if attackData and trackCache[attackData] and trackCache[attackData].IsPlaying then
		trackCache[attackData]:Stop(0.05)
	end
	if hum and not movementLocked then
		savedWalkSpeed = hum.WalkSpeed
		hum.WalkSpeed = savedWalkSpeed * Cfg.ATTACK_MOVE_FACTOR -- slow drift, not a dead stop
		movementLocked = true
	end
	PlayerAnim.setBusy(true) -- fade locomotion/idle out so ONLY the attack clip plays (no wide blend)
	local nowc = os.clock()
	if Cfg.DEBUG_COMBO then
		local gap = if attackStart > 0 then nowc - attackStart else 0
		print(("[combat] hit %d  (+%.2fs since prev hit)"):format(num, gap))
	end
	attacking   = true
	attackData  = data
	attackNum   = num
	attackStart = nowc
	didHit      = false
	slamLandSent = false
	slamLandAt  = 0
	dbgShown    = false
	if num > Cfg.AIR_BASE then PlayerAnim.resetAirTime() end -- an air attack refreshes hang time (gravity ramp)
	-- AIR HEAVY (SLAM): dive immediately AND start the server's continuous grab-sweep NOW, from the TOP of
	-- the dive, so it catches everything on the way down instead of a single active-frame hit. Swing FX once;
	-- the payoff is the landing crater (server onSlamLand). didHit=true suppresses the normal fireHit below.
	if data.selfSlam and root then
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(v.X, -data.selfSlam, v.Z)
		remote:FireServer("attack", num)
		local FXC = Cfg.FX
		FX.sound(FXC.SWING_SOUND, root.Position, FXC.SWING_PICK)
		FX.burst(FXC.SWING_HEAVY.name, root.CFrame, FXC.SWING_HEAVY.scale, FXC.TTL, FXC.EMIT_BURST)
		didHit = true
	elseif data.float and PlayerAnim.isAirborne() then
		-- AIR LIGHT "+air time": ASK playerAnim to hold us up through the active window — it owns the
		-- player's airborne Y (single owner, no tug-of-war with its gravity ramp) and decays the favour by
		-- how long we've already been up, so float-chaining self-limits.
		PlayerAnim.airFloat(data.float, data.active.e)
	end
	playAttackAnim(data)
end

-- restore control WITHOUT ending the attack state: unlock movement + let locomotion take over. Called
-- when the active frames end so the recovery tail no longer freezes the player (they can walk-cancel it).
-- Idempotent — the WalkSpeed restore is gated by movementLocked.
local function releaseMovement()
	if hum and movementLocked then
		-- restore to playerAnim's LIVE base speed, not the value captured at swing start: a sprint toggle
		-- during the (now unstompable) attack would otherwise leave a stale walk/run speed.
		hum.WalkSpeed = PlayerAnim.baseWalkSpeed()
		movementLocked = false
	end
	PlayerAnim.setBusy(false)
end

local function endAttack()
	if attackData and trackCache[attackData] and trackCache[attackData].IsPlaying then
		trackCache[attackData]:Stop(0.1)
	end
	releaseMovement()
	attacking  = false
	attackData = nil
	attackNum  = 0
	if dbg then dbg.Transparency = 1 end
	dbgShown = false
end

-- start the NEXT attack from a buffered input. Which CHAIN you're on is decided by where you are RIGHT NOW:
-- airborne → the short air combo (2 lights + slam), grounded → the 5-hit ground chain. The number we pass
-- encodes both (Cfg.AIR_BASE offset), so the server resolves the same row with no extra wire arg.
local function startNext(b: { kind: string, t: number })
	if PlayerAnim.isAirborne() then
		if b.kind == "heavy" then
			if os.clock() < nextSlamAt then return end -- slam on cooldown → drop the input (no re-slam spam)
			nextSlamAt = os.clock() + Cfg.SLAM.COOLDOWN
			startAttack(Cfg.AIR_BASE + 6, AIR_HEAVY) -- the downslam
		else
			-- only CONTINUE an air chain if the current attack is already an air light — you can't carry a
			-- ground chain's index into the air (jumping mid-combo starts the air combo fresh at 1).
			local i = if attackNum > Cfg.AIR_BASE then attackNum - Cfg.AIR_BASE else 0
			local nextI = if i >= 1 and i < #AIR_LIGHT then i + 1 else 1
			startAttack(Cfg.AIR_BASE + nextI, AIR_LIGHT[nextI])
		end
	elseif b.kind == "heavy" then
		startAttack(6, HEAVY)
	else
		local nextIndex = if attackNum >= 1 and attackNum <= #LIGHT then attackNum + 1 else 1
		if nextIndex > #LIGHT then nextIndex = 1 end
		startAttack(nextIndex, LIGHT[nextIndex])
	end
end

-- active-frame hit: draw the hitbox + tell the server to resolve it (once per attack)
local function fireHit()
	local r = root
	if not r then return end
	-- hitbox spans from ~0.5 studs BEHIND the player out to `reach` ahead (so mobs hugging you are hit,
	-- not just ones at arm's length). Width/height from box.X/box.Y; DEPTH from reach (box.Z unused).
	local box = attackData.box
	local reach = attackData.reach
	local cf  = r.CFrame * CFrame.new(0, 0, -(reach * 0.5 - 0.5))
	if Cfg.DEBUG_SHAPECAST then
		local d = debugBox()
		d.Size = Vector3.new(box.X, box.Y, reach + 1)
		d.CFrame = cf
		d.Transparency = 0.65
		dbgShown = true
		dbgHideAt = os.clock() + 0.18 -- self-timed; see update()
	end

	-- swing FX: a random melee whoosh at the player, the arc VFX out at the hitbox. The finisher + the
	-- heavy get the beefier "Heavy" kit; hits 1-4 get "Light".
	local FXC = Cfg.FX
	local heavy = Cfg.isHeavy(attackNum)
	local kit = if heavy then FXC.SWING_HEAVY else FXC.SWING_LIGHT
	FX.sound(FXC.SWING_SOUND, r.Position, FXC.SWING_PICK)
	FX.burst(kit.name, cf, kit.scale, FXC.TTL, FXC.EMIT_BURST)

	-- IMPACT FX + DAMAGE NUMBERS right now, client-predicted against the same box (no server roundtrip —
	-- purely visual). Geometry MUST match the server's OBB in systems/combat or the sparks/numbers won't line
	-- up. AIR attacks pop NO damage numbers (air combat reads as juggle/knockback, not a damage readout) → nil.
	local dmg = if attackNum > Cfg.AIR_BASE then nil else attackData.damage
	Mobs.playImpacts(cf, box.X / 2, box.Y / 2, (reach + 1) / 2, heavy, dmg)

	remote:FireServer("attack", attackNum)
end

-- ── Per-frame tick ───────────────────────────────────────────────────────────────
local function update(dt: number)
	local now = os.clock()

	-- debug hitbox is self-timed (drawn in fireHit): hide it on its own clock, independent of the attack
	-- state, so an attack that ends the instant it hits (the slam) still shows its box.
	if dbgShown and dbg and now >= dbgHideAt then
		dbg.Transparency = 1
		dbgShown = false
	end

	if attacking and attackData then
		local t = now - attackStart
		local act = attackData.active

		-- Fire the active hit ONCE. A SLAM's whole payoff is the impact, so if it reaches the ground before
		-- its active frame, landing ALSO triggers the hit.
		local landed = attackNum > Cfg.AIR_BASE and not PlayerAnim.isAirborne()
		if not didHit and (t >= act.s or (attackData.selfSlam and landed)) then
			didHit = true
			fireHit()
		end

		-- the slam LANDED (or a failsafe force-land): latch it ONCE and tell the server to scatter (onSlamLand).
		-- The latch (not the live `landed`) drives everything below, so a native jump right after touchdown
		-- can't re-enter the dive and stick `busy` forever. Force-land: a dive that never resolves (deep pit /
		-- no landing state) is bounded by SLAM.MAX_DIVE so the player can't soft-lock.
		if attackData.selfSlam and not slamLandSent and (landed or t >= Cfg.SLAM.MAX_DIVE) then
			slamLandSent = true
			slamLandAt = now
			remote:FireServer("slamland")
		end

		-- SLAM presentation while diving: hold the LAST FRAME + spark the dive path.
		if attackData.selfSlam and not slamLandSent then
			-- HOLD LAST FRAME (Looped=false): freeze near the end. ROBUST to frame drops — if a slow frame
			-- (FPS < ~33, the horde regime) let the non-looped clip finish + auto-stop, replay and clamp to
			-- the last frame in THIS PreRender pass (runs before render → no flicker), then freeze. A track
			-- frozen via AdjustSpeed(0) still reports IsPlaying==true, so it's never spuriously re-Played.
			local st = trackCache[attackData]
			if st and st.Length > 0 then
				if not st.IsPlaying then
					st:Play(0)
					st.TimePosition = math.max(0, st.Length - 0.01)
					st:AdjustSpeed(0)
				elseif st.Speed ~= 0 and st.TimePosition >= st.Length - 0.05 then
					st:AdjustSpeed(0)
				end
			end
			-- CLIENT-PREDICTED impact sparks + debug box swept down the dive path (the server owns the actual
			-- grab; this is purely visual). Throttled so it's periodic sparks, not one-per-frame spam.
			local r = root
			if r and now >= slamFxAt then
				slamFxAt = now + 0.08
				local box, reach = attackData.box, attackData.reach
				local cf = r.CFrame * CFrame.new(0, 0, -(reach * 0.5 - 0.5))
				Mobs.playImpacts(cf, box.X / 2, box.Y / 2, (reach + 1) / 2, true)
				if Cfg.DEBUG_SHAPECAST then
					local d = debugBox()
					d.Size = Vector3.new(box.X, box.Y, reach + 1)
					d.CFrame = cf
					d.Transparency = 0.65
					dbgShown = true
					dbgHideAt = now + 0.18
				end
			end
		elseif attackData.selfSlam and slamLandSent then
			local st = trackCache[attackData]
			if st and st.Speed == 0 then st:AdjustSpeed(1) end -- unfreeze so endAttack can fade it out cleanly
		end

		-- The whole swing — windup, active, recovery — is COMMITTED and only your own combo input advances
		-- it. Walking does NOT cancel and mashing does nothing (both would let you "walk+punch" spam past
		-- the pacing). The ONLY early-out is the paced combo chain:
		--  • A next hit is QUEUED (a press landed DURING this hit): hold until RECOVERY_CANCEL of the
		--    recovery has elapsed, THEN cancel into the next hit — cadence = act.e + recovery*RECOVERY_CANCEL.
		--  • NOTHING queued: play the full recovery out, then return to neutral.
		-- (External interrupts — an enemy/other-player special — will break an attack through a SEPARATE
		-- path later; that's the only thing that should ever cut a committed swing short.)
		if t >= act.e then
			-- LANDING an air attack forces it COMMITTED — it plays its recovery out. This is the AIR
			-- DEBOUNCE: before, landing early-returned past this whole block, so the slam (which dives and
			-- lands instantly) had ZERO recovery and neutral re-fired every frame → infinite spam. You also
			-- can't air-chain once you're grounded (the air combo is over).
			local committed = Cfg.isCommitted(attackNum) or landed
			local wantChain = not committed and buffered ~= nil and (buffered :: any).t >= attackStart
			if wantChain then
				if t >= act.e + attackData.recovery * Cfg.RECOVERY_CANCEL then
					local b = buffered :: any; buffered = nil
					startNext(b)
				end
				-- else: hold (still committed to this swing) until the cancel point
			elseif attackData.selfSlam then
				-- a SLAM ends only AFTER it has landed (the one-way latch), and its recovery is anchored to the
				-- LANDING — never the wall-clock from attackStart. So it can't end mid-air (slamland always
				-- fires), a native jump after touchdown can't re-open it, and a long dive still gets a full,
				-- consistent post-land recovery rather than ending the instant it lands.
				if slamLandSent and now >= slamLandAt + attackData.recovery then
					endAttack()
				end
			elseif t >= act.e + attackData.recovery then
				endAttack()
			end
		end
	else
		-- neutral: a very recent buffered press starts a swing
		if buffered then
			if now - buffered.t <= Cfg.BUFFER then
				local b = buffered; buffered = nil
				startNext(b)
			else
				buffered = nil
			end
		end
	end

	-- block meter recharge (drains only when hit while blocking — not built yet)
	if not blocking and now - lastBlockHitT > Cfg.block.RECHARGE_DELAY then
		blockHP = math.min(Cfg.block.HP, blockHP + Cfg.block.RECHARGE * dt)
	end
end

-- ── Input ────────────────────────────────────────────────────────────────────────
local function press(kind: string)
	-- Blocking is a COMMITTED STANCE — you can't swing out of it, you must RELEASE first. Dropping the
	-- input entirely (rather than buffering it) is deliberate: a buffered swing would fire the instant you
	-- let go, which reads as the guard "storing" attacks.
	if blocking then return end
	buffered = { kind = kind, t = os.clock() }
end

local function setBlock(on: boolean)
	if on and blockHP <= 0 then return end -- guard broken → can't block until it recharges
	if on and attacking then return end    -- mid-swing is committed; the guard can't cancel it (same rule
	                                       -- as walking/mashing — see the recovery model in update())
	if on == blocking then return end
	blocking = on
	if on then
		local bt = blockTrack
		if not bt and BLOCK_ANIM and BLOCK_ANIM ~= 0 then
			bt = loadTrack(BLOCK_ANIM)
			blockTrack = bt
		end
		if bt then bt:Play(0.08) end
		-- turtle shuffle, not a dead stop (consistent with ATTACK_MOVE_FACTOR). playerAnim gates roll +
		-- sprint and fades loco off its own `blocking` flag, so the block pose owns the body.
		if hum then hum.WalkSpeed = PlayerAnim.baseWalkSpeed() * Cfg.block.MOVE_FACTOR end
		PlayerAnim.setBlocking(true)
	else
		if blockTrack and blockTrack.IsPlaying then blockTrack:Stop(0.1) end
		PlayerAnim.setBlocking(false)
		-- restore from playerAnim's live base speed (a sprint toggle mid-guard would stale a cached value)
		if hum and not movementLocked then hum.WalkSpeed = PlayerAnim.baseWalkSpeed() end
	end
	remote:FireServer("block", if on then 1 else 0)
end

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Cfg.INPUT.LIGHT then
		press("light")
	elseif input.UserInputType == Cfg.INPUT.HEAVY then
		press("heavy")
	elseif input.KeyCode == Cfg.block.key or input.KeyCode == Cfg.block.button then
		setBlock(true)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Cfg.block.key or input.KeyCode == Cfg.block.button then
		setBlock(false)
	end
end)

-- ── Character lifecycle ──────────────────────────────────────────────────────────
local function onCharacter(char: Model)
	table.clear(trackCache)
	blockTrack = nil
	endAttack()
	-- a fresh character never inherits a raised guard (the tracks died with the old rig). Clear it on BOTH
	-- sides or playerAnim keeps loco faded out and the player respawns unable to move or roll.
	blocking = false
	PlayerAnim.setBlocking(false)
	root = char:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
	animator = hum and (hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5)) :: Animator?
	preloadAttacks() -- warm every attack clip so the first swing plays (was silent — no preload)
end

LP.CharacterAdded:Connect(onCharacter)
if LP.Character then task.spawn(onCharacter, LP.Character) end

scheduler.SYSTEM(update, phases.PreRender)
return 0
