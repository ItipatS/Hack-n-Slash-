-- std/playerStates.luau
-- The player action-state enum, shared by BOTH ends: the client animator (playerAnim) reports
-- transitions over blink.PlayerAction; the server (systems/players) stores {state, since} per
-- player for combat rules (roll i-frames, attack gating, landing lag). Add a state = add a
-- number here — the wire is a u8, so values must stay 0..255 and EXISTING values never change
-- (a live client and server must agree).
--!strict

local M = {
	Idle = 0,
	Walk = 1,
	Run  = 2,
	Jump = 3,
	Fall = 4,
	Roll = 5,
}

-- reverse lookup for logs/debug ("state 5" → "Roll")
M.Name = {} :: { [number]: string }
for name, id in M :: any do
	if type(id) == "number" then M.Name[id] = name end
end

return table.freeze(M)
