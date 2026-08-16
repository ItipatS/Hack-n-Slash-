-- Bullet Heaven persisted META profile (ProfileStore Template). Field names match the live game
-- state the rest of the codebase already reads (profile.luau / playerState), so no remapping is
-- needed. This is NOT in-run state — that's ephemeral (playerState.reset wipes it each run).
--
-- Missing keys are reconciled to these defaults on load; bump Settings.version + add a migration
-- step in Data/init.luau (MIGRATIONS) when this shape changes in a breaking way. Additive fields
-- need no migration — ProfileStore Reconcile seeds them on the next load.

return {

    _SchemaVersion = 1;

    tix = 0;          -- META currency (Tix shop)

    bestWave = 0;     -- lifetime best stats
    bestLevel = 1;
    bestTime = 0;
    totalKills = 0;
    runs = 0;

    pets = { axolotl = true; fox = true; slime = true; }; -- owned collection (3 starters)
    squad = { "axolotl" };                                -- chosen run squad (slot1 = main)

}
