-- std/combatConfig.luau
-- Melee combat data (DMC-like). ONE place for attack ids, frame windows, hitbox shapes, and block
-- tunables — read by BOTH ClientSystems/combat (input + combo + anim + debug viz) and
-- ServerScriptService/systems/combat (authoritative shapecast + damage). Paste rbxassetids; 0 = none.
--
-- FRAME DATA: give me each attack's ACTIVE window (when the hitbox is live). Express it in SECONDS.
-- If you think in frames, divide by FRAME_RATE. I add the leniency (input BUFFER + a recovery-cancel
-- window, see RECOVERY_CANCEL) — it's not Street Fighter, so the combo-cancel window is generous.
--!strict

local M = {}

M.DEBUG_SHAPECAST = true  -- ALWAYS draw the attack hitbox on the client (red neon box)
M.DEBUG_COMBO     = false  -- print each hit + seconds since the previous hit (verify the real combo cadence)
M.FRAME_RATE      = 30     -- if you author active frames, seconds = frames / this
M.BUFFER          = 0.20   -- an input this early (before the attack is cancelable) is remembered, not dropped

-- COMBO CADENCE: after an attack's ACTIVE frames end, the next queued hit cancels in once this FRACTION of
-- that attack's `recovery` has elapsed. 0 = chain the instant active ends (mash-fast, blurs together);
-- 1 = must sit through the FULL recovery first (stiff, the old ~4s feel). This one knob paces the whole
-- combo — raise it if hits blur, lower it if it feels sluggish. (~0.35 ≈ a ~2s 5-hit chain.)
M.RECOVERY_CANCEL = 0.35
-- MOVEMENT DURING AN ATTACK: fraction of normal WalkSpeed kept while swinging. 0 = FULLY LOCKED — you
-- commit to the swing and can't move until it's done (what the game wants; the earlier "stiff" feeling was
-- the locomotion anim fighting the swing, now fixed by fully fading loco while busy). >0 = a drift.
M.ATTACK_MOVE_FACTOR = 0

M.INPUT = {
	LIGHT = Enum.UserInputType.MouseButton1, -- 5-hit combo
	HEAVY = Enum.UserInputType.MouseButton2, -- heavy finisher
}

-- ── VFX / SFX (std/fx.luau resolves these BY NAME, recursively; a missing one warns once + no-ops) ──
-- VFX: ReplicatedStorage.Assets.VFX — each is a Part anchoring Attachment(s) of ParticleEmitters.
-- SFX: SoundService.Whoosh / .Hit are FOLDERS of variants, so we pick a random one per swing:
--   Whoosh → melee1-4 (boxing) | weapon1-4 (future weapon stances)
--   Hit    → punch1-4 (boxing) | sword1-2 (future weapon stances)
-- *_PICK filters the folder by name prefix, so the stance pulls the right family. Drop the PICK to let it
-- choose from every variant in the folder.
-- "HEAVY" class = the RMB heavy AND the LAST light hit (the combo finisher) — both hit harder, both get
-- the beefier swing + the bigger impact.
-- Each kit = { name in Assets.VFX, scale }. `scale` goes through **Model:ScaleTo** (std/fx wraps every kit
-- in a Model at spawn), so it resizes the WHOLE effect coherently — particle sizes AND attachment offsets.
-- 1 = the artist's authored size. Tune these freely; this is THE size knob per effect.
M.FX = {
	SWING_LIGHT  = { name = "Light", scale = 0.6 },  -- light chain hits 1..4  (authored size read too big)
	SWING_HEAVY  = { name = "Heavy", scale = 0.75 }, -- the finisher + the RMB heavy (also too big)
	IMPACT_LIGHT = { name = "Hit1",  scale = 1.8 },  -- mob hit by a light attack (authored size too small)
	IMPACT_HEAVY = { name = "Hit2",  scale = 2.6 },  -- mob hit by the heavy / last combo — the "bigger" one
	SWING_SOUND  = "Whoosh",
	SWING_PICK   = "melee",  -- boxing stance → melee*; a sword stance would use "weapon"
	HIT_SOUND    = "Hit",
	HIT_PICK     = "punch",  -- boxing stance → punch*; a sword stance would use "sword"
	-- Impacts are CLIENT-PREDICTED (see ClientSystems/mobs.playImpacts): every mob inside YOUR swing box
	-- pops its hit VFX immediately — no server roundtrip, purely visual. Catching 100 mobs should FEEL like
	-- 100 hits, so the cap is high; it's purely the perf escape hatch if a mega-swing tanks FPS.
	IMPACT_CAP   = 100,
	TTL          = 2,        -- seconds before a spawned VFX is cleaned up (> the particles' Lifetime)
	EMIT_BURST   = 0.35,     -- burst size = emitter.Rate × this (so each emitter keeps its authored
	                         -- density). An `EmitCount` attribute on an emitter pins an exact count instead.
}

-- Is this attack in the "heavy" class (finisher or RMB heavy)? Drives which swing/impact FX play.
-- ONE number on the wire identifies the attack AND whether it was airborne, so the client needs no extra
-- arg and the authoritative server can't be lied to about which row to apply:
--   ground → 1..5 light, 6 heavy      air → AIR_BASE+1..AIR_BASE+2 light, AIR_BASE+6 heavy
M.AIR_BASE = 10

-- Resolve a wire attack number → (config row, isAir). SINGLE SOURCE OF TRUTH for both ClientSystems/combat
-- and ServerScriptService/systems/combat — they must never disagree about what "attack 12" means.
function M.resolve(attackNum: number, stance: string?): (any, boolean)
	local st = M.stances[stance or "base"]
	if attackNum > M.AIR_BASE then
		local i = attackNum - M.AIR_BASE
		if i == 6 then return st.air.heavy, true end
		return st.air.light[i], true
	end
	if attackNum == 6 then return st.heavy, false end
	return st.light[attackNum], false
end

-- "HEAVY class" — drives the beefier swing/impact FX AND the commitment rule below. It's every heavy plus
-- the last light of its own chain (ground finisher / air ejector).
function M.isHeavy(attackNum: number): boolean
	if attackNum > M.AIR_BASE then
		local i = attackNum - M.AIR_BASE
		return i == 6 or i >= #M.stances.base.air.light
	end
	return attackNum >= #M.stances.base.light or attackNum == 6
end

-- COMMITTED = you cannot chain out of it; it plays its full recovery and returns to neutral. Same set as
-- the heavy class (a finisher earns its weight), but named separately because it's a different rule.
function M.isCommitted(attackNum: number): boolean
	return M.isHeavy(attackNum)
end

-- Stances → attacks. `light` is the ordered 5-hit LMB chain; `heavy` is the RMB finisher; `block` /
-- `blockhit` are this stance's guard hold + guard-hit reaction anims. Per attack: anim, active {s,e}
-- seconds, recovery (time to neutral if no chain), damage, knock (studs/sec impulse), box (hitbox size
-- in studs), reach (studs in front of the player the box front sits).
-- NOTE: no per-attack "block damage" — these are the PLAYER's attacks and they hit MOBS, which don't
-- block. Guard drain only happens when a MOB hits a blocking PLAYER, so it's a property of MOB attacks
-- (built later) and derives from their damage × M.block.GUARD_DRAIN — no per-attack value needed.
M.stances = {
	base = {
		-- `lift` = LAUNCHER: upward velocity (studs/sec) given to every mob the swing catches. 0 = pure
		-- knockback. The mob sim integrates it against mobConfig.GRAVITY and treats an airborne mob as
		-- hitstunned (it stops steering), so lift is what opens a juggle:
		--     apex = lift² / (2*GRAVITY)      hang time = 2*lift / GRAVITY      (GRAVITY 90 → 35 ≈ 7 studs
		--     for ~0.8s; 60 ≈ 20 studs for ~1.3s). Keep it under ~95 (the net lane ceiling, config.luau Net).
		-- Ground chain per design: 1/2/4 just knock back, 3 = medium lift, 5 = high lift (the launcher you
		-- combo INTO the air off of).
		light = {
			{ anim = 100703610993646, active = { s = 0.22, e = 0.27 }, recovery = 0.52, damage = 8,  knock = 8,  lift = 0,  box = Vector3.new(5, 5, 5.0), reach = 5.0 },
			{ anim = 101458014665602, active = { s = 0.28, e = 0.33 }, recovery = 0.65, damage = 8,  knock = 8,  lift = 0,  box = Vector3.new(5, 5, 5.0), reach = 5.0 },
			{ anim = 108537794224428,  active = { s = 0.27, e = 0.32 }, recovery = 0.7, damage = 10, knock = 0, lift = 50, box = Vector3.new(5, 5, 5.5), reach = 5.0 }, -- medium lift
			{ anim = 121009380251493, active = { s = 0.18, e = 0.23 }, recovery = 0.62, damage = 10, knock = 15, lift = 0,  box = Vector3.new(5, 5, 6.0), reach = 5.0 },
			{ anim = 95357150537358,  active = { s = 0.12, e = 0.20 }, recovery = 0.8, damage = 18, knock = 10, lift = 60, box = Vector3.new(10, 6, 6.0), reach = 5.5 }, -- HIGH lift (launcher)
		},
		heavy = { anim = 131157654388636, active = { s = 0.42, e = 0.5 }, recovery = 1.0, damage = 28, knock = 70, lift = -20, box = Vector3.new(7, 7, 7.0), reach = 6 },

		-- ── AIR combo (only usable while airborne) — deliberately short: 2 lights + a slam.
		--   air 1 → medium-HIGH lift: re-launches the mob so the juggle keeps going.
		--   air 2 → high KNOCKBACK, no lift: the ejector that ends the juggle.
		--   air heavy → DOWNSLAM: `lift` is NEGATIVE, which spikes every mob it catches into the floor.
		-- Player-side fields (air only):
		--   `float`    = the player's vertical velocity is HELD at this through the active window — this is
		--                the "+air time" a light air attack buys you. 0 = hang in place, small + = rise.
		--                (Phase 4 will SCALE this down the longer you've already been airborne.)
		--   `selfSlam` = the player dives at this speed (air heavy) instead of floating.
		-- Air actives are much shorter than ground: you're falling, so they have to come out fast.
		-- CRITICAL — box.Y is TALL on purpose. A launcher throws a mob to ~20 studs but the player only jumps
		-- to ~13 (mob gravity 90 vs the player's Roblox 196.2), so vertical alignment mid-air is never exact.
		-- The air box spans the whole JUGGLE COLUMN (±box.Y/2 around the player) so "roughly at the mob"
		-- connects. The slam's is tallest — you spike everything in the column you dive through.
		air = {
			light = {
				{ anim = 128044737475382, active = { s = 0.27, e = 0.3 }, recovery = 0.53, damage = 9,  knock = 6,  lift = 50, float = 2, box = Vector3.new(5, 7, 5.0), reach = 5.0 },
				{ anim = 93018757207208, active = { s = 0.07, e = 0.12 }, recovery = 0.27, damage = 12, knock = 70, lift = 0,  float = 0, box = Vector3.new(5, 7, 5.5), reach = 5.0 },
			},
			-- SLAM box is a tall/wide COLUMN: the server sweeps it down the dive path each frame (see
			-- systems/combat slamSweep), grabbing everything it passes through until landing. box.Y tall so
			-- the column reaches from the player down through the juggled mobs; box.X wide for the AOE.
			heavy = { anim = 80862020147663, active = { s = 0.47, e = 0.55 }, recovery = 0.83, damage = 26, knock = 45, lift = -35, selfSlam = 90, box = Vector3.new(10, 16, 10), reach = 6 },
		},
		block    = 86028190579169, -- guard hold/idle animation (0 = none)
		blockhit = 71323102476628, -- played when hit while blocking
	},
}

-- Block: HOLD to block. Mitigates (not negates) incoming damage by REDUCTION. A BLOCK_HP meter drains
-- when a MOB hit is blocked — drain = that mob attack's damage × GUARD_DRAIN (heavies pressure more
-- simply by hitting harder; no per-attack guard value). A heavy does NOT break block instantly, it just
-- drains faster. At 0 block HP you can't block until the meter recharges.
M.block = {
	key    = Enum.KeyCode.F,          -- HOLD to block (change freely)
	button = Enum.KeyCode.ButtonL2,   -- gamepad
	-- Blocking is a COMMITTED STANCE: while you hold it you can't attack, can't roll, can't sprint —
	-- release first. Movement isn't a dead stop (that felt stiff on attacks too), it's a turtle shuffle:
	-- MOVE_FACTOR × your normal WalkSpeed. 0 = rooted in place; 1 = block while moving freely (off).
	MOVE_FACTOR = 0.25,
	HP     = 100,
	REDUCTION      = 0.5,             -- blocked hits deal 50%
	GUARD_DRAIN    = 1.0,             -- block HP drained per 1 point of blocked (mob) damage
	RECHARGE       = 20,             -- block HP regained per second
	RECHARGE_DELAY = 1.5,            -- seconds after the last block-hit before regen resumes
}

-- ── SLAM IMPACT (the air-heavy touchdown) — RockModule + VoxManager in Workspace ─────────────────
-- On landing, systems/combat spawns a rock crater (cosmetic, self-cleaning) and optionally carves the
-- ground with the voxel destruction module. Both modules live under Workspace (RockModule V1.0 / VoxManager).
M.SLAM = {
	COOLDOWN = 2.0,      -- min seconds between SLAMS — you can't chain slam→jump→slam instantly (felt spammy)
	DEBRIS_TTL = 4.0,    -- seconds after impact before the rock crater is faded out (RockModule's own 30s
	                     -- crater lifetime lingered way too long for a combat hit)
	MAX_DIVE = 2.5,      -- CLIENT failsafe: if a dive hasn't landed in this long (deep pit / never-registers-
	                     -- a-landing edge), force it to land — bounds the committed hold so you can't soft-lock.
	                     -- Keep BELOW mobConfig.SLAM_GRAB_MAX so the forced slamland still finds the grab live.
	CRATER_RADIUS = 9,   -- RockModule.Crater ring radius
	CRATER_ROCKS_MIN = 8,
	CRATER_ROCKS_MAX = 14,
	EXPLOSION_ROCKS = 10, -- RockModule.Explosion — small rocks flung up on impact (0 = none)
	VOXELIZE = false,     -- carve real geometry with VoxManager (PERMANENT map destruction — off by default)
	VOXEL_RADIUS = 8,
	VOXEL_SIZE = 1.6,     -- module's recommended voxel size
}

return M
