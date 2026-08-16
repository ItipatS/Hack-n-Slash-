-- std/panels.luau
-- Tiny shared state for the MENU tabs (Pets / Items) so they don't fight: only one open at a time,
-- and each tab's open-button hides while ANOTHER tab is open (fixes the PETS button rendering over an
-- open Items panel — they live in separate ScreenGuis with different DisplayOrders).
--!strict

local Panels = {}

local current: string? = nil
local subs: { (string?) -> () } = {}

local function notify()
    for _, f in subs do f(current) end
end

-- mark a panel open/closed (name e.g. "pets" / "items")
function Panels.set(name: string, open: boolean)
    if open then
        current = name
    elseif current == name then
        current = nil
    end
    notify()
end

function Panels.get(): string?
    return current
end

-- subscribe to changes; fires immediately with the current value
function Panels.onChanged(f: (string?) -> ())
    subs[#subs + 1] = f
    f(current)
end

return Panels
