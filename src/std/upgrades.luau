-- std/upgrades.luau
-- Level-up upgrade pool + rarity table for the pick-1-of-3 card screen. "Random bullshit is fine for now" —
-- a mix of stat bumps and flavor skills across five rarities. `key` names the effect; ClientSystems/xp
-- applies the simple ones and stubs the rest (the card SCREEN is the showcase, not the effect depth yet).
--!strict

local M = {}

-- rarity by index (1..5). `weight` = roll odds; `color` tints the card + glow.
export type Rarity = { name: string, color: string, weight: number }
M.RARITY = {
	{ name = "Common",    color = "b8c0c8", weight = 48 },
	{ name = "Uncommon",  color = "63d2a2", weight = 27 },
	{ name = "Rare",      color = "6ec6ff", weight = 15 },
	{ name = "Epic",      color = "c07bff", weight = 8 },
	{ name = "Legendary", color = "ffb02e", weight = 2 },
}

export type Upgrade = { name: string, desc: string, rarity: number, key: string }
M.POOL = {
	-- Common
	{ name = "Sharper Blades", desc = "+15% attack damage",     rarity = 1, key = "damage" },
	{ name = "Swift Feet",     desc = "+12% move speed",        rarity = 1, key = "speed" },
	{ name = "Quick Hands",    desc = "+10% attack speed",      rarity = 1, key = "atkspeed" },
	{ name = "Spring Step",    desc = "+15% jump power",        rarity = 1, key = "jump" },
	-- Uncommon
	{ name = "Wide Arcs",      desc = "+20% attack range",      rarity = 2, key = "range" },
	{ name = "Air Superiority",desc = "+25% air damage",        rarity = 2, key = "airdmg" },
	{ name = "Vampiric Edge",  desc = "Heal a little on hit",   rarity = 2, key = "lifesteal" },
	-- Rare
	{ name = "Chain Lightning",desc = "Hits arc to nearby foes",rarity = 3, key = "chain" },
	{ name = "Concussive Hits",desc = "Knockback +40%",         rarity = 3, key = "knock" },
	{ name = "Triple Jump",    desc = "One extra air jump",     rarity = 3, key = "airjump" },
	-- Epic
	{ name = "Bullet Time",    desc = "Brief slow-mo on a kill",rarity = 4, key = "slowmo" },
	{ name = "Seismic Slam",   desc = "Slam shockwave +80%",    rarity = 4, key = "slam" },
	-- Legendary
	{ name = "Devil Trigger",  desc = "Everything, but MORE",   rarity = 5, key = "devil" },
	{ name = "Meteor",         desc = "Kills rain fire",        rarity = 5, key = "meteor" },
}

-- roll a rarity index by weight
function M.rollRarity(): number
	local total = 0
	for _, r in M.RARITY do total += r.weight end
	local x = math.random() * total
	for i, r in M.RARITY do
		x -= r.weight
		if x <= 0 then return i end
	end
	return 1
end

-- a random upgrade of (or nearest to) a rarity
function M.rollUpgrade(rarity: number): Upgrade
	local matches: { Upgrade } = {}
	for _, u in M.POOL do if u.rarity == rarity then matches[#matches + 1] = u end end
	if #matches == 0 then -- no upgrade at that exact rarity → any
		return M.POOL[math.random(1, #M.POOL)]
	end
	return matches[math.random(1, #matches)]
end

-- one full roll: rarity then an upgrade of it
function M.roll(): (Upgrade, number)
	local r = M.rollRarity()
	return M.rollUpgrade(r), r
end

return M
