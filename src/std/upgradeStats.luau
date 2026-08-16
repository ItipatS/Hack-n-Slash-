-- std/upgradeStats.luau
-- The single source of truth for what each level-up upgrade DOES. Both sides build the same stat set from
-- the picked keys: the SERVER keeps a per-player set and reads it in combat (damage/knock/range/air/chain/
-- slam); the CLIENT keeps one `runStats` (std/runStats) that playerAnim reads (speed/jump/air-jumps).
-- `apply(stats, key)` mutates a set for one pick. Keys come from std/upgrades' `key` field.
--!strict

local M = {}

export type Stats = {
	dmgMul: number, airDmgMul: number, rangeMul: number, knockMul: number, slamMul: number, -- server
	speedMul: number, jumpMul: number, atkSpeedMul: number, bonusJumps: number,             -- client
	chain: number, lifesteal: number, slowmo: boolean, meteor: boolean,                     -- special
}

function M.defaults(): Stats
	return {
		dmgMul = 1, airDmgMul = 1, rangeMul = 1, knockMul = 1, slamMul = 1,
		speedMul = 1, jumpMul = 1, atkSpeedMul = 1, bonusJumps = 0,
		chain = 0, lifesteal = 0, slowmo = false, meteor = false,
	}
end

-- fold one picked upgrade into `s` (multiplicative for stats, additive for counts/flags)
function M.apply(s: Stats, key: string)
	if key == "damage" then s.dmgMul *= 1.15
	elseif key == "speed" then s.speedMul *= 1.12
	elseif key == "atkspeed" then s.atkSpeedMul *= 1.10
	elseif key == "jump" then s.jumpMul *= 1.15
	elseif key == "range" then s.rangeMul *= 1.20
	elseif key == "airdmg" then s.airDmgMul *= 1.25
	elseif key == "lifesteal" then s.lifesteal += 2 -- inert until a player-HP system exists
	elseif key == "chain" then s.chain += 1
	elseif key == "knock" then s.knockMul *= 1.40
	elseif key == "airjump" then s.bonusJumps += 1
	elseif key == "slowmo" then s.slowmo = true
	elseif key == "slam" then s.slamMul *= 1.80
	elseif key == "meteor" then s.meteor = true
	elseif key == "devil" then -- Devil Trigger: a bit of everything
		s.dmgMul *= 1.5; s.knockMul *= 1.5; s.speedMul *= 1.25; s.atkSpeedMul *= 1.2
	end
end

return M
