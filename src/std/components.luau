--ReplicatedStorage/std/components.luau

local jecs = require(game:GetService("ReplicatedStorage").ecs)
local world = require(script.Parent.world)

type Entity<T = nil> = jecs.Entity<T>
local components: {
	Character: Entity<Model>,
	Mob: Entity,
	Model: Entity<Model>,
	Player: Entity,
	Target: Entity,
	Transform: Entity<{ new: CFrame, old: CFrame }>,
	Speed: Entity<number>,
	Velocity: Entity<Vector3>,
	Previous: Entity,
	Size: Entity<number>,
	Hitbox: Entity<Part>,
	MobType: Entity<string>,

	 -- Behavior Components
    StateMachine: Entity<{ current: string, states: {[string]: any} }>,
    ChaseTarget: Entity<{ target: number?, range: number, loseRange: number }>,
    Patrol: Entity<{ points: {Vector3}, current: number, wait: number }>,
	
    Wander: Entity<{ center: Vector3, radius: number, nextMove: number }>,
    Aggressive: Entity<{ attackRange: number, damage: number, cooldown: number }>,
    Flee: Entity<{ from: number?, fleeRange: number, speed: number }>,
    
    -- Timers/Conditions
    Timer: Entity<{ remaining: number }>,
    Cooldown: Entity<{ remaining: number }>,
	PendingStateChanges: Entity<{ [number]:{ id:number,  state: string } }>,

	--movement intent
	Locomotion: Entity<{ dir: Vector3, speed: number }>,

	 Traits: Entity<{
        baseSpeedMul: number,
        chaseWeight: number,
        fleeWeight: number,
        circleWeight: number,
        jumpWeight: number,
        fleeDistance: number,
        preferDistance: number,
    }>,

	AIState: Entity<{
        state: string,   -- "wander" | "chase" | "flee" | "circle"
        t: number,       -- time spent in state
        dur: number,     -- how long to stay in state (seconds)
        circleSign: number, -- +1 / -1 for circle direction
    }>,

	PathNode: Entity<number>,     -- current node ID (mob is HERE)
	PathTarget: Entity<number>,   -- next node ID (mob is going HERE)
	PathTween: Entity<{ from: number, to: number, startTime: number, speed: number }>,

	-- Direct-chase mode (in range + line of sight): home on a player's character.
	Hunt: Entity<{ target: Model, speed: number }>,

	-- Player action state (hack&slash pivot): the client-reported locomotion/action state
	-- (std/playerStates enum) + WHEN it started (server time). Combat reads this for state
	-- rules — e.g. roll i-frames = state == Roll and now - since < window.
	ActionState: Entity<{ state: number, since: number }>,

	-- Combat
	Health: Entity<{ hp: number, max: number }>,
	Elite: Entity, -- tag: tougher monster that drops a reward (upgrade card) on death
	Boss: Entity,  -- tag: rare big monster that drops a PET pickup on death
	Flying: Entity, -- tag: UFO — ignores pathfinding, hovers + attacks at range (ufo.luau)
	Knock: Entity<Vector3>, -- current knockback velocity (decays); horde applies it
	Slot: Entity<number>, -- dense replication slot (0..N); the wire position key (no per-mob id)
	-- SLAM GRAB: set by combat when the air-heavy slam catches a mob. While present the mob is dragged
	-- straight DOWN (mobConfig.SLAM_DRAG), stops steering, and holds until the player lands → combat then
	-- scatters it radially and removes this. `owner` = the slamming player; `t0` = grab start (safety timeout).
	Grabbed: Entity<{ owner: any, t0: number }>,
	-- Status effects (mob buffs/debuffs). Combat APPLIES via std/statuses; statuses.tick() owns expiry
	-- and folds active effects into the derived SpeedMul. Movement (horde) reads ONLY SpeedMul — it
	-- never interprets a raw effect. Add a new effect = new component here + an aggregation rule in statuses.
	Slow: Entity<{ factor: number, untilT: number }>, -- raw effect: factor (<1 slow, >1 haste) until untilT
	SpeedMul: Entity<number>, -- DERIVED: aggregate movement multiplier (absent = 1, normal speed)

	-- Player buffs (players are ECS entities — Player/Character live here). Same shape as mob statuses:
	-- std/playerBuffs APPLIES timed buffs into `Buffs`; its resolver folds them WITH passive gear defense
	-- into the derived `PlayerMods`. Combat + ufo QUERY PlayerMods for the damage loop instead of reading
	-- PlayerState modifiers inline. Add a buff = a new `kind` + an aggregation branch in playerBuffs.tick.
	Buffs: Entity<{ [string]: { mag: number, untilT: number } }>, -- active timed buffs, keyed by kind (refresh-by-kind)
	-- DERIVED: the player's FULL resolved combat modifier set (passive stats + active timed buffs).
	-- DEFENSE/move: invuln/armor/reflect/regen/walkSpeed (damage loop + ufo). OFFENSE/firing path
	-- (fireStep/spawnBubble/SKILLS): damage(×)/crit(+)/critDmg(+)/atkSize(×)/knock(×)/haste(×)/skillCd(×).
	PlayerMods: Entity<{
		invuln: boolean, armor: number, reflect: number, regen: number, walkSpeed: number,
		damage: number, crit: number, critDmg: number, atkSize: number, knock: number, haste: number, skillCd: number,
	}>,
} = {
		Character = world:component(),
		Mob = world:component(),
		Model = world:component(),
		Player = world:component(),
		Target = world:component(),
		Transform = world:component(),
		Speed = world:component(),
		Velocity = world:component(),
		Previous = world:component(),
		Size = world:component(),
		MobType = world:component(),

		Hitbox = world:component(),

		StateMachine = world:component(),
		ChaseTarget = world:component(),
		Patrol = world:component(),
		Wander = world:component(),
		Aggressive = world:component(),
		Flee = world:component(),
		Timer = world:component(),
		Cooldown = world:component(),
		PendingStateChanges = world:component(),

		Locomotion = world:component(),

		Traits      = world:component(),
    	AIState     = world:component(),

		PathNode = world:component(),
		PathTarget = world:component(),
		PathTween = world:component(),
		Hunt = world:component(),

		ActionState = world:component(),
		Health = world:component(),
		Elite = world:component(),
		Boss = world:component(),
		Flying = world:component(),
		Knock = world:component(),
		Slot = world:component(),
		Grabbed = world:component(),
		Slow = world:component(),
		SpeedMul = world:component(),
		Buffs = world:component(),
		PlayerMods = world:component(),
	}

for name, component in components :: {[string]: jecs.Entity} do 
	world:set(component, jecs.Name, name)
end

return table.freeze(components)
