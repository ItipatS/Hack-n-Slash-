-- ClientSystems/playerAnim.luau
-- Local-player DIRECTIONAL locomotion animator. Replaces the default Animate script with a
-- weight-blended 9-track locomotion set (idle + walk/run × F/B/L/R) plus air/action clips
-- (jump → looped fall → land, roll). All clips + tunables live in std/animConfig — this file
-- is the machine. Every state TRANSITION is reported to the server (blink.PlayerAction →
-- systems/players stores {state, since}) so combat can rule on roll i-frames / attack gating;
-- the animations themselves replicate to other clients automatically via the Animator.
--
-- How the blend works, per frame (PreAnimation, before Roblox samples the tracks):
--   1. Horizontal velocity → the root's LOCAL space (forward/side components).
--   2. Direction weights: f/b/l/r = the positive parts of those components, normalized. A 45°
--      diagonal is genuinely 50/50 front+side — no snapping between 4 poses.
--   3. Gait: speed blends idle→walk (0..WALK fraction) and walk→run (RUN_START..RUN_FULL), and
--      playback speed scales vs the clip's authored speed (WALK_REF/RUN_REF) so feet never slide.
--   4. Every weight eases toward its target at BLEND_RATE — direction flips are crossfades.
-- All 9 loco tracks PLAY continuously at (eased) weight; one-shots (Action priority) layer on top.
--
-- Facing is decoupled from movement (that's what makes 4-direction clips visible): FACE_MODE
-- "camera" yaw-locks the character to the camera; "aim" faces std/aimState. AutoRotate is off in
-- both; "movement" keeps the Roblox default.
--
-- Weapon overrides later: M.setOverride("sword") swaps to that set; keys it doesn't define fall
-- back to base (see animConfig). Swap is a rebuild + crossfade — cheap, happens on weapon draw.
--!strict

local Players            = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

local std       = ReplicatedStorage.std
local scheduler = require(std:WaitForChild("scheduler"))
local phases    = require(std:WaitForChild("phases"))
local Cfg       = require(std:WaitForChild("animConfig"))
local AimState  = require(std:WaitForChild("aimState"))
local States    = require(std:WaitForChild("playerStates"))
local blink     = require(std:WaitForChild("ClientNet"))
local FX        = require(std:WaitForChild("fx")) -- movement one-shots (jump / roll cues)
local RunStats  = require(std:WaitForChild("runStats")) -- level-up upgrades: speed / jump / extra air jumps

local LP = Players.LocalPlayer

-- ── Track tables ────────────────────────────────────────────────────────────────
local LOCO_KEYS   = { "idle", "walkF", "walkB", "walkL", "walkR", "runF", "runB", "runL", "runR" }
-- one-shots (Action priority): jump/land/roll + the 4 directional AIR-DASH clips
local ACTION_KEYS = { "jump", "land", "roll", "dashF", "dashB", "dashL", "dashR" }
-- a missing directional clip falls back to its FORWARD sibling (testable with 2 clips)
local DIR_FALLBACK: { [string]: string } = {
	walkB = "walkF", walkL = "walkF", walkR = "walkF",
	runB  = "runF",  runL  = "runF",  runR  = "runF",
	dashB = "dashF", dashL = "dashF", dashR = "dashF",
}

local hum: Humanoid? = nil
local root: BasePart? = nil
local animator: Animator? = nil
local tracks:  { [string]: AnimationTrack } = {}
local weights: { [string]: number } = {}      -- current eased weight per loco key
local targets: { [string]: number } = {}      -- this frame's target weight per loco key
local charConns: { RBXScriptConnection } = {}

local curSet   = "base"
local airborne = false
local airT0    = 0
local nextRoll = 0                            -- cooldown gate (roll START + ROLL_CD)
local rolling  = false                        -- true while a roll dash is active (drives velocity + loco fade)
local rollUntilT = 0                          -- roll is ACTIVE until this time (drives state + facing)
local rollDir: Vector3 = Vector3.new(0, 0, -1) -- world-space dir captured at roll start (dash + facing)
local sprinting = false
local busy = false                            -- set by combat during an attack: fades locomotion fully
                                              -- out so the Action attack clip owns the body (no blend)
local blocking = false                        -- set by combat while the guard is HELD. Blocking is a
                                              -- COMMITTED STANCE: it gates roll + sprint here (attacks are
                                              -- gated in combat) and fades loco so the block pose owns the
                                              -- body — you must release to act. See combatConfig.block.
local jumpsUsed = 0                           -- jumps spent since last touching ground (Cfg.MAX_JUMPS caps
                                              -- it; the FIRST is Roblox's own, extras are our air jumps)
local airDashUsed = false                     -- ONE air dash per airborne period; refunded on landing
local airDashing  = false                     -- true during an air dash (flat: Y pinned to 0)
local floatVy   = 0                           -- combat's requested hold velocity (see M.airFloat)
local floatUntil = 0                          -- ...held until this clock time, then gravity takes back over
local warned: { [string]: boolean } = {}      -- missing-clip warnings, once per key

-- ── Action state (reported to the server on TRANSITIONS — combat reads {state, since}) ──
local curState = -1
local function setState(s: number)
	if s == curState then return end
	curState = s
	blink.PlayerAction.Fire(s)
end

-- ── Track loading ───────────────────────────────────────────────────────────────
local function resolveId(key: string): number
	local set = Cfg.SETS[curSet]
	local id = (set and set[key]) or 0
	if id == 0 then id = Cfg.SETS.base[key] or 0 end
	if id == 0 and DIR_FALLBACK[key] then
		return resolveId(DIR_FALLBACK[key])
	end
	return id
end

local function loadTracks()
	for _, t in tracks do t:Stop(0); t:Destroy() end
	table.clear(tracks)
	table.clear(weights)
	table.clear(targets)
	local anmr = animator
	if not anmr then return end

	local function load(key: string, priority: Enum.AnimationPriority, looped: boolean)
		local id = resolveId(key)
		if id == 0 then
			if not warned[key] then
				warned[key] = true
				warn(`[playerAnim] no animation id for '{key}' (set '{curSet}') — paste it in std/animConfig`)
			end
			return
		end
		local anim = Instance.new("Animation")
		anim.AnimationId = "rbxassetid://" .. id
		local track = anmr:LoadAnimation(anim)
		track.Priority = priority
		track.Looped = looped
		tracks[key] = track
	end

	load("idle", Enum.AnimationPriority.Idle, true)
	for _, key in LOCO_KEYS do
		if key ~= "idle" then load(key, Enum.AnimationPriority.Movement, true) end
	end
	for _, key in ACTION_KEYS do load(key, Enum.AnimationPriority.Action, false) end
	load("fall", Enum.AnimationPriority.Action, true) -- LOOPED air pose (between jump and land)

	-- loco tracks run continuously; only their weights move. (Weight floor: a full 0 makes some
	-- engine versions drop the track from the blend and snap on re-entry — 1e-3 is invisible.)
	for _, key in LOCO_KEYS do
		local t = tracks[key]
		if t then
			t:Play(0)
			t:AdjustWeight(1e-3, 0)
			weights[key] = 0
			targets[key] = 0
		end
	end
end

-- one-shot: play, then fade out just before the clip end so it never snaps to the last frame
local function playOneShot(key: string, fade: number)
	local t = tracks[key]
	if not t then return end
	t:Play(fade)
	local len = t.Length
	if len > 0 then
		task.delay(math.max(0.05, len - fade), function()
			if t.IsPlaying then t:Stop(fade) end
		end)
	end
end

-- jump: play the launch clip, then crossfade into the LOOPED fall pose as it runs out (if we're
-- still airborne). A no-jump Freefall (walked off a ledge) starts fall directly via StateChanged.
local function startFall(fade: number)
	local f = tracks.fall
	if f and not f.IsPlaying then f:Play(fade) end
	setState(States.Fall)
end

local function playJump()
	-- If a native GROUND jump fires mid-attack (busy), the attack clip owns the body — don't layer the jump
	-- clip (also Action priority) over it; that's the "air anim overlapping the swing" blend setBusy prevents.
	-- The physical jump still happens; setBusy(false) at the swing's end resumes the fall pose.
	if busy then return end
	local r = root
	if r then FX.sound(Cfg.SFX.JUMP, r.Position) end
	local t = tracks.jump
	if not t then
		startFall(0.2) -- no jump clip authored → straight to the fall pose
		return
	end
	t:Play(0.1)
	local len = t.Length
	task.delay(if len > 0 then math.max(0.05, len - 0.15) else 0.4, function()
		if airborne then startFall(0.2) end
	end)
end

-- MID-AIR jump. The first jump is Roblox's (Humanoid handles it); this is every jump AFTER that, so we
-- drive it ourselves: overwrite the vertical velocity (don't add — a rising double-jump would stack into a
-- rocket, and a falling one would barely register), keep horizontal so air control carries through.
local function doAirJump()
	local h, r = hum, root
	if not (h and r) then return end
	if not airborne then return end             -- grounded → let Roblox's own jump handle it
	if rolling or blocking or busy then return end -- committed states own the body (busy = mid-attack; you
	                                            -- can't jump out of a swing, incl. stretching a diving slam)
	if jumpsUsed >= Cfg.MAX_JUMPS + RunStats.bonusJumps then return end -- "Triple Jump" upgrade adds bonusJumps
	jumpsUsed += 1

	-- DIRECTIONAL MOMENTUM: a double jump REDIRECTS you along your current input rather than just going
	-- straight up — that's what makes it usable to close on a juggled mob. No input → keep your horizontal.
	local v = r.AssemblyLinearVelocity
	local md = h.MoveDirection
	local vx, vz = v.X, v.Z
	if md.Magnitude > 0.1 then
		local flat = Vector3.new(md.X, 0, md.Z)
		if flat.Magnitude > 1e-3 then
			local d = flat.Unit
			vx, vz = d.X * Cfg.AIR_JUMP_MOMENTUM, d.Z * Cfg.AIR_JUMP_MOMENTUM
		end
	end
	r.AssemblyLinearVelocity = Vector3.new(vx, Cfg.AIR_JUMP_POWER * RunStats.jumpMul, vz) -- "Spring Step" upgrade
	floatUntil = 0 -- the jump supersedes any pending attack float

	-- The double jump reads as a FLIP, not a second launch: play the ROLL clip over the fall pose.
	-- NOTE: airT0 is deliberately NOT reset — the gravity ramp keeps climbing, so a double jump buys height
	-- but never refreshes your air time. That's the self-limiter.
	local f = tracks.fall
	if f and f.IsPlaying then f:Stop(0.05) end
	setState(States.Jump)
	if r then FX.sound(Cfg.SFX.JUMP, r.Position) end
	local t = tracks.roll
	if t then
		t:Play(0.05)
		local len = t.Length
		task.delay(if len > 0 then math.max(0.05, len - 0.1) else 0.35, function()
			if airborne then startFall(0.2) end
		end)
	else
		playJump() -- no roll clip authored → fall back to the launch clip
	end
end

-- ── Per-frame locomotion blend (PreAnimation: weights land before the animator samples) ──
local function updateBlend(dt: number)
	local r, h = root, hum
	if not (r and h) then return end

	local v = r.AssemblyLinearVelocity
	local speed = math.sqrt(v.X * v.X + v.Z * v.Z)

	for _, key in LOCO_KEYS do targets[key] = 0 end

	local grounded = States.Idle -- grounded state this frame (air/roll states are set by events)
	if airborne or rolling or busy or blocking then
		-- air / roll / attack / block: loco fades out; the (Action-priority) jump/fall/roll/attack/block
		-- pose owns the body. Without this the block stance blends against the walk and reads "wide".
	elseif speed < Cfg.IDLE_BELOW then
		targets.idle = 1
	else
		-- velocity in root-local space: forward = +dot(look), side = +dot(right)
		local cf = r.CFrame
		local look, right = cf.LookVector, cf.RightVector
		local fwd  = v.X * look.X + v.Z * look.Z
		local side = v.X * right.X + v.Z * right.Z
		local f, b = math.max(0, fwd), math.max(0, -fwd)
		local rt, lt = math.max(0, side), math.max(0, -side)
		local sum = f + b + rt + lt
		if sum > 1e-4 then
			f, b, rt, lt = f / sum, b / sum, rt / sum, lt / sum
		else
			f = 1
		end

		local moveW = math.min(1, speed / Cfg.WALK_REF)          -- idle→walk ramp-in
		local runA  = math.clamp((speed - Cfg.RUN_START) / math.max(1e-3, Cfg.RUN_FULL - Cfg.RUN_START), 0, 1)
		local walkGate, runGate = moveW * (1 - runA), moveW * runA

		targets.idle  = 1 - moveW
		targets.walkF = f * walkGate;  targets.runF = f * runGate
		targets.walkB = b * walkGate;  targets.runB = b * runGate
		targets.walkL = lt * walkGate; targets.runL = lt * runGate
		targets.walkR = rt * walkGate; targets.runR = rt * runGate
		grounded = if runA > 0.5 then States.Run else States.Walk

		-- playback speed vs authored speed → no foot-slide at any WalkSpeed
		local walkRate = speed / Cfg.WALK_REF
		local runRate  = speed / Cfg.RUN_REF
		for _, key in LOCO_KEYS do
			local t = tracks[key]
			if t and key ~= "idle" then
				t:AdjustSpeed(if key:sub(1, 3) == "run" then runRate else walkRate)
			end
		end
	end

	-- ease every weight toward its target (manual smoothing; AdjustWeight fade 0 keeps it exact)
	local a = math.min(1, Cfg.BLEND_RATE * dt)
	for _, key in LOCO_KEYS do
		local t = tracks[key]
		if t then
			local w = weights[key] + ((targets[key] or 0) - weights[key]) * a
			weights[key] = w
			t:AdjustWeight(math.max(w, 1e-3), 0)
		end
	end

	-- report the action state: roll wins while active; in the air the jump/fall events own it;
	-- on the ground it's the loco state computed above.
	if os.clock() < rollUntilT then
		setState(States.Roll)
	elseif not airborne then
		setState(grounded)
	end
end

-- ── Facing (PreRender): yaw the character toward camera/aim, independent of movement ──
local function updateFacing(dt: number)
	if Cfg.FACE_MODE == "movement" then return end
	local r, h = root, hum
	if not (r and h) then return end
	if r.Anchored then return end -- parked lobby body (players.luau) — never unpark it from here
	if h:GetState() == Enum.HumanoidStateType.Seated then return end

	local dir: Vector3
	if rolling then
		-- rolling: turn INTO the roll's movement direction (a strafe-roll shouldn't play the
		-- forward-roll clip sideways), snappier than the normal camera ease
		local lv = r.CFrame.LookVector
		local yaw = math.atan2(-lv.X, -lv.Z)
		local tYaw = math.atan2(-rollDir.X, -rollDir.Z)
		local diff = (tYaw - yaw + math.pi) % (2 * math.pi) - math.pi
		if math.abs(diff) > 1e-3 then
			yaw += diff * math.min(1, Cfg.ROLL_FACE_RATE * dt)
			r.CFrame = CFrame.new(r.Position) * CFrame.Angles(0, yaw, 0)
		end
		return
	end
	if Cfg.FACE_MODE == "aim" then
		dir = AimState.get()
	else
		local cam = workspace.CurrentCamera -- re-fetch: the camera instance is replaced on respawn
		if not cam then return end
		dir = cam.CFrame.LookVector
	end
	local dx, dz = dir.X, dir.Z
	if dx * dx + dz * dz < 1e-6 then return end

	local targetYaw = math.atan2(-dx, -dz) -- CFrame yaw convention: -Z is forward
	local lv = r.CFrame.LookVector
	local yaw = math.atan2(-lv.X, -lv.Z)
	local diff = (targetYaw - yaw + math.pi) % (2 * math.pi) - math.pi -- shortest arc
	if math.abs(diff) < 1e-3 then return end -- already facing → skip the CFrame write
	yaw += diff * math.min(1, Cfg.FACE_RATE * dt)
	r.CFrame = CFrame.new(r.Position) * CFrame.Angles(0, yaw, 0)
end

-- Air dash: play the DIRECTIONAL dash clip for `rollDir` relative to the character's facing (F/B/L/R),
-- NOT the roll clip. Speed-fit so a clip authored longer than AIR_DASH_TIME compresses into the dash window
-- instead of getting cut off mid-swing (that "too long for airborne" look). Missing dash clips fall back to
-- dashF, then to roll.
local function playDash()
	local r = root
	if not r then return end
	local look, right = r.CFrame.LookVector, r.CFrame.RightVector
	local fwd  = rollDir.X * look.X + rollDir.Z * look.Z
	local side = rollDir.X * right.X + rollDir.Z * right.Z
	local key
	if math.abs(fwd) >= math.abs(side) then
		key = if fwd >= 0 then "dashF" else "dashB"
	else
		key = if side >= 0 then "dashR" else "dashL"
	end
	local t = tracks[key] or tracks.dashF or tracks.roll
	if not t then return end
	t:Play(0.05)
	local len = t.Length
	if len > 0 then
		t:AdjustSpeed(math.max(1, len / Cfg.AIR_DASH_TIME)) -- compress if longer than the dash; never slower
		task.delay(Cfg.AIR_DASH_TIME, function()
			if t.IsPlaying then t:Stop(0.1) end
		end)
	end
end

-- ── Actions ─────────────────────────────────────────────────────────────────────
local function doRoll()
	local h, r = hum, root
	if not (h and r) then return end
	if rolling then return end
	if blocking then return end -- committed stance: release the guard before you can roll out
	if busy then return end     -- mid-ATTACK is committed too — no roll/dash-cancel out of a swing (matches
	                            -- walk/guard commitment; also stops stretching a diving slam + the two-clip glitch)
	local now = os.clock()
	-- COOLDOWN, shared by the ground roll AND the air dash. Air dash used to be gated ONLY by airDashUsed,
	-- which landing refunds — so holding Space (bunny-hop) let you air-dash on every touchdown = infinite
	-- dash spam. The time gate fixes that: even a refunded dash can't re-fire within ROLL_CD.
	if now < nextRoll then return end

	-- AIR DASH: rolling while airborne dashes instead. Still ALSO gated by ONE use per airborne period.
	if airborne then
		if airDashUsed then return end
		airDashUsed = true
		nextRoll = now + Cfg.ROLL_CD -- start the shared cooldown (the ground path sets it too)
		local md = h.MoveDirection
		local d = if md.Magnitude > 0.1 then md else r.CFrame.LookVector
		local flat = Vector3.new(d.X, 0, d.Z)
		rollDir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
		rolling    = true
		airDashing = true
		rollUntilT = now + Cfg.AIR_DASH_TIME
		floatUntil = 0 -- a dash overrides any pending attack float
		airT0 = now    -- a dash refreshes air time → the gravity ramp restarts (an active dash keeps hang)
		h.PlatformStand = true
		playDash() -- directional dash clip (F/B/L/R), not the roll
		FX.sound(Cfg.SFX.ROLL, r.Position)
		setState(States.Roll)
		return
	end

	nextRoll = now + Cfg.ROLL_CD -- ground roll starts the shared cooldown (checked at the top)

	-- roll INTO the current movement input (stick/WASD, already world-space & camera-relative);
	-- standing still → roll forward (current facing). Flatten to the XZ plane so the dash stays level.
	local md = h.MoveDirection
	local d = if md.Magnitude > 0.1 then md else r.CFrame.LookVector
	local flat = Vector3.new(d.X, 0, d.Z)
	rollDir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)

	local t = tracks.roll
	rollUntilT = now + (if t and t.Length > 0 then t.Length else Cfg.ROLL_TIME)
	rolling = true
	-- PlatformStand hands movement to us: the Humanoid controller stops steering toward
	-- MoveDirection*WalkSpeed, so our AssemblyLinearVelocity dash (updateRoll) isn't fought back
	-- down to walk speed. Gravity still applies (we preserve Y). Restored when the roll ends.
	h.PlatformStand = true
	playOneShot("roll", 0.1)
	FX.sound(Cfg.SFX.ROLL, r.Position)
	setState(States.Roll)
end

-- Drive the dash before physics (PreSimulation): hold horizontal velocity along rollDir, keep the
-- vertical component so gravity/landing still works, and end the roll when the clip runs out.
-- An AIR dash is the same machine with two differences: its own speed, and Y pinned to 0 so it reads as a
-- flat dash rather than a dive.
local function updateRoll(_dt: number)
	local r, h = root, hum
	if not (r and h) then return end
	if not rolling then return end
	if os.clock() >= rollUntilT then
		local wasAirDash = airDashing
		rolling = false
		airDashing = false
		h.PlatformStand = false
		-- an air dash that ends while still airborne returns to the fall pose (the spurious ground state
		-- from clearing PlatformStand is now ignored — see StateChanged — so nothing else re-poses us)
		if wasAirDash and airborne then startFall(0.15) end
		return
	end
	local speed = if airDashing then Cfg.AIR_DASH_SPEED else Cfg.ROLL_SPEED
	local yv = if airDashing then 0 else r.AssemblyLinearVelocity.Y
	r.AssemblyLinearVelocity = Vector3.new(rollDir.X * speed, yv, rollDir.Z * speed)
end

-- ── Airborne vertical feel — the ONE owner of the player's Y velocity while off the ground ─────────
-- Combat never writes velocity itself; it ASKS via M.airFloat(). Single owner = nothing fights, and the
-- ordering between combat (PreRender) and physics can't produce a tug-of-war.
--   • FLOAT: hold Y at combat's requested value — but BLEND toward it by a factor that decays with AIR
--     TIME. At full scale you hang; once you've been up past AIR_FLOAT_FADE the request does nothing and
--     gravity wins. This is what stops infinite float-chaining (and it works even for float = 0, because
--     we blend from your CURRENT Y rather than snapping to the target).
--   • PROGRESSIVE GRAVITY: extra downward accel that ramps with air time — long air = hard fall.
local function updateAir(dt: number)
	local r = root
	if not (r and airborne) then return end
	if rolling then return end -- an air dash owns velocity for its duration

	local now = os.clock()
	local airTime = now - airT0
	local v = r.AssemblyLinearVelocity

	if now < floatUntil then
		local scale = math.clamp(1 - airTime / Cfg.AIR_FLOAT_FADE, 0, 1)
		local target = v.Y + (floatVy - v.Y) * scale -- scale=1 → hold at floatVy; scale=0 → leave it alone
		r.AssemblyLinearVelocity = Vector3.new(v.X, target, v.Z)
	else
		local extra = math.min(Cfg.AIR_GRAV_MAX, Cfg.AIR_GRAV_RAMP * airTime)
		r.AssemblyLinearVelocity = Vector3.new(v.X, v.Y - extra * dt, v.Z)
	end
end

local function onSprint(_, state: Enum.UserInputState)
	local h = hum
	if state == Enum.UserInputState.Begin then
		sprinting = true
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		sprinting = false
	end
	-- While BLOCKING or mid-ATTACK (busy), COMBAT owns WalkSpeed — a Shift tap must NOT stomp its lock, or
	-- the player walks out of a committed swing (the `sprinting` flag is still updated above, so the correct
	-- speed is re-derived the moment the swing/guard ends). This `not busy` guard is load-bearing for the
	-- full attack lock.
	if h and not blocking and not busy then h.WalkSpeed = (if sprinting then Cfg.RUN_SPEED else Cfg.WALK_SPEED) * RunStats.speedMul end
	return Enum.ContextActionResult.Sink
end

local function onRollInput(_, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then doRoll() end
	return Enum.ContextActionResult.Pass
end

-- Jump input. We PASS it through so Roblox's own controller still does the GROUND jump exactly as before
-- (native feel, no reimplementation); we only act when already airborne, which the default jump ignores.
local function onJumpInput(_, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then doAirJump() end
	return Enum.ContextActionResult.Pass
end

ContextActionService:BindAction("HS_Sprint", onSprint, false, Cfg.SPRINT_KEY, Cfg.SPRINT_BUTTON)
ContextActionService:BindAction("HS_Roll", onRollInput, true, Cfg.ROLL_KEY, Cfg.ROLL_BUTTON) -- true → touch button on mobile
ContextActionService:SetTitle("HS_Roll", "Roll")
if Cfg.MAX_JUMPS > 1 then
	ContextActionService:BindAction("HS_AirJump", onJumpInput, false, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
end

-- ── Character lifecycle ─────────────────────────────────────────────────────────
local function onCharacter(char: Model)
	for _, c in charConns do c:Disconnect() end
	table.clear(charConns)
	airborne = false
	rolling  = false -- a fresh character never inherits a mid-roll from the last one
	airDashing = false
	blocking = false -- ...nor a raised guard (combat re-asserts it if the key is still held)
	jumpsUsed = 0
	airDashUsed = false
	floatUntil = 0

	root = char:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	local h = char:WaitForChild("Humanoid", 10) :: Humanoid?
	hum = h
	if not (root and h) then return end

	-- OUR machine, not Roblox's: disable the default Animate script and stop anything it started.
	-- WaitForChild — the default script can replicate in AFTER CharacterAdded fires; missing it
	-- here means two controllers blending against each other.
	local animate = char:FindFirstChild("Animate") or char:WaitForChild("Animate", 5)
	if animate and animate:IsA("LocalScript") then animate.Disabled = true end
	local anmr = h:FindFirstChildOfClass("Animator")
	if not anmr then
		anmr = Instance.new("Animator")
		anmr.Parent = h
	end
	animator = anmr
	for _, t in anmr:GetPlayingAnimationTracks() do t:Stop(0) end

	if Cfg.FACE_MODE ~= "movement" then h.AutoRotate = false end
	h.WalkSpeed = (if sprinting then Cfg.RUN_SPEED else Cfg.WALK_SPEED) * RunStats.speedMul

	loadTracks()

	charConns[#charConns + 1] = h.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Jumping then
			if not airborne then
				airborne = true
				airT0 = os.clock()
				jumpsUsed = 1 -- Roblox's ground jump spends the first of MAX_JUMPS
				setState(States.Jump) -- BEFORE playJump: a missing jump clip falls straight to Fall
				playJump()
			end
		elseif new == Enum.HumanoidStateType.Freefall then
			if not airborne then -- walked off a ledge (no jump) → straight into the fall pose
				airborne = true
				airT0 = os.clock()
				jumpsUsed = 1 -- stepping off a ledge still costs the ground jump → ONE air jump, not two
				startFall(0.2)
			end
		elseif new == Enum.HumanoidStateType.Landed
			or new == Enum.HumanoidStateType.Running
			or new == Enum.HumanoidStateType.RunningNoPhysics then
			-- ONLY a REAL landing (actually on a floor) refunds air abilities. Clearing an air dash's
			-- PlatformStand fires a spurious RunningNoPhysics MID-AIR; without this guard it reset
			-- airDashUsed + jumpsUsed every dash → infinite air dash AND infinite double jump. FloorMaterial
			-- is Air whenever we're genuinely airborne, so it distinguishes the two cleanly.
			if h.FloorMaterial ~= Enum.Material.Air then
				jumpsUsed = 0     -- touched ground → air jumps refunded
				airDashUsed = false -- ...and the air dash
				floatUntil = 0
				if airborne then
					airborne = false
					local j, f = tracks.jump, tracks.fall
					if j and j.IsPlaying then j:Stop(0.1) end
					if f and f.IsPlaying then f:Stop(0.1) end
					if new == Enum.HumanoidStateType.Landed and os.clock() - airT0 > Cfg.LAND_MIN_AIR then
						playOneShot("land", 0.08)
					end
				end
			end
		end
	end)
end

LP.CharacterAdded:Connect(onCharacter)
if LP.Character then task.spawn(onCharacter, LP.Character) end

scheduler.SYSTEM(updateRoll, phases.PreSimulation) -- drives the dash + ENDS the roll (clears PlatformStand)
scheduler.SYSTEM(updateAir, phases.PreSimulation)  -- float hold + progressive gravity (BEFORE physics, and
                                                   -- after updateRoll so a dash keeps ownership of velocity)
scheduler.SYSTEM(updateBlend, phases.PreAnimation)
scheduler.SYSTEM(updateFacing, phases.PreRender)

-- ── Public (weapon override sets, manual actions) ───────────────────────────────
local M = {}

-- Swap to a named override set from animConfig.SETS (nil/"base" = unarmed). Missing keys fall
-- back to base. Rebuild + the blend eases back in — one visual crossfade on weapon draw.
function M.setOverride(setName: string?)
	local name = setName or "base"
	if not Cfg.SETS[name] then
		warn(`[playerAnim] unknown animation set '{name}'`)
		return
	end
	if name == curSet then return end
	curSet = name
	table.clear(warned)
	loadTracks()
end

M.roll = doRoll

-- Combat calls this while attacking so locomotion fades out and the attack clip owns the body.
function M.setBusy(b: boolean)
	busy = b
	if b then
		-- An attack owns the body. updateBlend fades the LOCO set, but the AIR poses (jump / fall / the
		-- double-jump flip) are separate Action-priority one-shots NOT in that set — if left playing they
		-- blend against the (also Action) attack clip, which is the "air anim overlapping movement" bug.
		-- Stop them so the swing is clean. (Don't kill an ACTIVE roll/dash — it owns velocity too.)
		if tracks.jump and tracks.jump.IsPlaying then tracks.jump:Stop(0.05) end
		if tracks.fall and tracks.fall.IsPlaying then tracks.fall:Stop(0.05) end
		if not rolling and tracks.roll and tracks.roll.IsPlaying then tracks.roll:Stop(0.05) end
	elseif airborne and not rolling then
		startFall(0.1) -- attack ended mid-air → nothing else re-poses us up here, so resume the fall pose
	end
end

-- An air ATTACK or DASH refreshes your air time (combat + the air dash call this). The progressive-gravity
-- ramp and the float-fade both key off airT0, so resetting it makes an ACTIVE juggle keep its hang while
-- merely floating still falls faster over time. No-op on the ground.
function M.resetAirTime()
	if airborne then airT0 = os.clock() end
end

-- Combat calls this on guard raise/release. Blocking is a COMMITTED STANCE: this gates roll + sprint here
-- and fades loco so the block pose owns the body. Attack gating lives in combat (it owns the input buffer).
function M.setBlocking(b: boolean)
	blocking = b
end

-- The WalkSpeed the player should be at with no combat modifier applied — combat restores to this after a
-- swing/guard instead of caching a stale value that a sprint toggle may have invalidated mid-action.
function M.baseWalkSpeed(): number
	return (if sprinting then Cfg.RUN_SPEED else Cfg.WALK_SPEED) * RunStats.speedMul -- × "Swift Feet" upgrade
end

-- Are we off the ground right now? Combat reads this to pick the AIR combo over the ground chain, and to
-- cancel an air attack the moment you land. This is the same flag the air/loco blend runs on, so the
-- animation state and the combo table can never disagree about whether you're airborne.
function M.isAirborne(): boolean
	return airborne
end

-- Combat REQUESTS hang time here rather than writing velocity itself — this module is the single owner of
-- the player's Y while airborne (see updateAir). `vy` is the velocity to hold, `duration` how long from
-- now. The request is honoured on a curve that decays with AIR TIME, so a late-in-the-jump attack buys you
-- almost nothing and juggles can't be extended forever.
function M.airFloat(vy: number, duration: number)
	floatVy = vy
	floatUntil = os.clock() + duration
end

return M
