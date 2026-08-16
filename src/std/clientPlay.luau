-- std/clientPlay.luau
-- CLIENT-ONLY shared UI context: which screen are we on?
--   "menu"       — at the main menu (loadout/PETS panel usable; gameplay HUD hidden)
--   "playing"    — in a live run (gameplay HUD + skill button shown; loadout locked)
--   "spectating" — dead, watching the round (no HUD, no loadout)
-- Driven by the menu/death flow (mainmenu sets menu/playing, gameover sets spectating) so every
-- HUD system can gate its visibility off ONE source instead of `player.Character` — which no longer
-- distinguishes menu from play now that a frozen lobby body always exists.
--!strict

export type State = "menu" | "playing" | "spectating"

local M = {}

local state: State = "menu"
local listeners: { (s: State) -> () } = {}

function M.set(s: State)
    if state == s then return end
    state = s
    for _, f in listeners do f(s) end
end

function M.get(): State
    return state
end

function M.isPlaying(): boolean
    return state == "playing"
end

-- subscribe; fires immediately with the current state so callers don't need a separate init
function M.onChanged(f: (s: State) -> ())
    listeners[#listeners + 1] = f
    f(state)
end

return M
