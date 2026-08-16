-- std/serverPause.luau
-- Shared SERVER pause flag. `paused` is true while any player is on the level-up card screen. systems/combat
-- flips it (from the "picking" count); systems/mobs (movement + wave director + mob attacks) checks it and
-- freezes the world so the level-up screen is a REAL pause. Solo-/co-op-demo scope: it pauses for everyone.
--!strict
return { paused = false }
