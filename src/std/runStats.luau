-- std/runStats.luau
-- The LOCAL player's current run stats (client). A single shared table: every client `require` gets the SAME
-- one (module cache), so xp.luau writes it (via upgradeStats.apply) and playerAnim reads it. Persists for the
-- session. See std/upgradeStats for what each field means.
--!strict
local upgradeStats = require(script.Parent.upgradeStats)
return upgradeStats.defaults()
