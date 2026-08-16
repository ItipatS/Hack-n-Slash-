-- std/animConfig.luau
-- Player character animation SETS + locomotion tunables. ONE place to paste animation asset ids
-- and tune the blend feel; the controller (ClientSystems/playerAnim.luau) reads only this.
--
-- SETS: "base" is the unarmed set. A weapon set (e.g. "sword") lists ONLY the keys it overrides —
-- any missing key falls back to base, so "same walk but the right arm holds a sword" is a set with
-- just the retargeted clips. (True partial-body layering — an upper-body-only clip played at a
-- higher priority OVER the base walk — also works: author the clip with only the arm joints keyed
-- and add it as an override; Roblox blends unkeyed joints from the lower-priority track.)
--
-- Directional fallback: a missing walkB/walkL/walkR falls back to walkF (same for run), so the
-- system is testable with just idle + walkF before the full 4-direction set is authored.
--!strict

local M = {}

-- ── Animation sets (paste rbxassetid numbers; 0 = not authored yet → fallback/skip) ──
M.SETS = {
	base = {
		idle  = 99289553350843,
		idlelowhp = 89599887905518,

		walkF = 134367956171277,
		walkB = 114956870217834,
		walkL = 132442889451041,
		walkR = 136555137096716,

		runF  = 119329370025903,
		runB  = 129858129440253,
		runL  = 80059937570755,
		runR  = 103067569774866,

		fall = 96075630626781,
		jump  = 108787061027484,
		land  = 136744043727623,
		roll  = 136118658045851,

		dashF = 103618037192254,
		dashB = 110479971252070,
		dashL = 110865628503064,
		dashR = 76650127591817,

		hit1 = 77290380281869,
		hit2 = 100236295327214,
		hit3 = 125923142840284,
		hit4 = 76590911520161,
		hit5 = 115787742377907,

		knockdown = 112693767619598,
		knockdownloop = 72948573873223,

	},

	-- sword = { idle = 0, walkF = 0, ... }, -- weapon override set: only the keys that change
} :: { [string]: { [string]: number } }

M.DEFAULT_SET = "base" -- fallback set if a weapon set is missing a key

-- ── Locomotion feel ─────────────────────────────────────────────────────────────
M.WALK_SPEED   = 10   -- Humanoid.WalkSpeed while walking
M.RUN_SPEED    = 20   -- Humanoid.WalkSpeed while sprint is held
M.WALK_REF     = 10   -- studs/sec the WALK clips were authored at (playback scales vs this → no foot-slide)
M.RUN_REF      = 14   -- studs/sec the RUN clips were authored at (playback = speed/this; LOWER = faster
                      -- legs). Was 20 → the stride cadence is slower than the 20 run speed so it slid;
                      -- tune until the feet plant at RUN_SPEED.
M.RUN_START    = 12   -- speed where walk→run blending begins
M.RUN_FULL     = 18   -- speed where the blend is 100% run
M.IDLE_BELOW   = 1.0  -- speeds under this are idle (kills micro-drift wiggle)
M.BLEND_RATE   = 12   -- 1/sec — how fast track weights ease toward their targets
M.LAND_MIN_AIR = 0.2  -- seconds airborne before the land clip plays (skip curb-hops)
M.ROLL_CD      = 1.2  -- seconds between rolls (measured from the roll START). Bumped 0.8→1.2 — 0.8 let you
                      -- roll again almost the instant the dash ended, which read as spammable.
M.ROLL_SPEED   = 36   -- studs/sec dash speed during a roll (walk 10 / run 20 → a roll clearly lunges)
M.ROLL_TIME    = 0.5  -- fallback roll duration if the roll clip has no length yet (else clip length)

-- ── Jump ────────────────────────────────────────────────────────────────────────
-- The FIRST jump stays Roblox's own (Humanoid.JumpPower); extra MID-AIR jumps are ours. MAX_JUMPS counts
-- BOTH — 2 = ground jump + one air jump, 1 = double jump off. Walking off a ledge without jumping still
-- costs one, so you get a single air jump out of it rather than two.
M.MAX_JUMPS      = 2
M.AIR_JUMP_POWER = 50   -- upward velocity for a mid-air jump (Humanoid.JumpPower defaults to 50)
M.AIR_JUMP_MOMENTUM = 18 -- a double jump REDIRECTS your horizontal speed to this, along the stick/WASD dir
                         -- (0 = pure vertical hop). No input → your existing horizontal is kept.

-- ── Air feel (the self-limiting half of the air-combo design) ───────────────────
-- Air combos have to be FAST or calculated, not infinite. Two mechanisms, both driven by AIR TIME (how
-- long you've been off the ground — a double jump deliberately does NOT reset it):
--   • PROGRESSIVE GRAVITY — extra downward accel that ramps the longer you're up. Early air is floaty,
--     late air drops like a rock.
--   • FLOAT FADE — an air attack buys hang time (combatConfig `float`), but the BENEFIT fades to nothing
--     over AIR_FLOAT_FADE seconds of air time, so you can't chain-float forever.
M.AIR_GRAV_RAMP  = 60   -- extra studs/s² of gravity added per SECOND airborne
M.AIR_GRAV_MAX   = 180  -- cap on that extra (Roblox's base gravity is 196.2, so this ~doubles it)
M.AIR_FLOAT_FADE = 1.2  -- seconds of air time over which an attack's float benefit decays to zero

-- ── Air dash (roll while airborne) ──────────────────────────────────────────────
-- ONE per airborne period ("once per any kind of jump") — refunded on landing, same as the air jumps.
M.AIR_DASH_SPEED = 40   -- horizontal dash speed
M.AIR_DASH_TIME  = 0.28 -- seconds the dash holds (Y is pinned to 0 → a FLAT dash, not a dive)

-- ── SFX ─────────────────────────────────────────────────────────────────────────
-- Names are resolved RECURSIVELY under SoundService by std/fx, so `SoundService.Movement.Jump` is found
-- by just "Jump". A FOLDER of variants also works — fx picks one at random. Missing name → one warn, no error.
M.SFX = {
	JUMP = "Jump",
	ROLL = "Roll",
}

-- ── Facing ──────────────────────────────────────────────────────────────────────
-- "camera"   → character yaw locks to the camera (shift-lock feel; strafe/backpedal anims show)
-- "aim"      → character faces std/aimState's direction (mouse/stick writers must feed it)
-- "movement" → Roblox default AutoRotate (faces where it walks; mostly forward anims play)
M.FACE_MODE = "camera" :: "camera" | "aim" | "movement"
M.FACE_RATE = 14 -- 1/sec — yaw ease toward the target facing
M.ROLL_FACE_RATE = 30 -- 1/sec — snappier ease into the roll's movement direction

-- ── Camera (ClientSystems/playerCamera.luau — custom over-the-right-shoulder lock) ──
M.CAM = {
	SHOULDER   = Vector3.new(2.2, 2.2, 0), -- offset from the HRP: right, up (the "over the shoulder")
	DIST       = 9,                        -- studs behind the shoulder pivot
	DIST_MIN   = 3,
	DIST_MAX   = 16,
	ZOOM_STEP  = 1.2,                      -- studs per mouse-wheel notch
	SENS       = 0.0045,                   -- rad per px of mouse movement (× system sensitivity)
	PITCH_MIN  = math.rad(-70),
	PITCH_MAX  = math.rad(60),
	FREE_KEY   = Enum.KeyCode.LeftAlt,     -- HOLD to free the mouse (menus/UI); release re-locks
	OCCLUDE_PAD = 0.35,                    -- pull-in from a wall the camera ray hits
}

-- ── Input ───────────────────────────────────────────────────────────────────────
M.SPRINT_KEY  = Enum.KeyCode.LeftShift
M.ROLL_KEY    = Enum.KeyCode.C
M.ROLL_BUTTON = Enum.KeyCode.ButtonB -- gamepad
M.SPRINT_BUTTON = Enum.KeyCode.ButtonL3
M.BLOCK_BUTTON = Enum.KeyCode.F

M.LIGHT_ATTACK_BUTTON = Enum.KeyCode.MouseLeftButton
M.HEAVY_ATTACK_BUTTON = Enum.KeyCode.MouseRightButton

return M
