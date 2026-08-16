-- std/aimState.luau
-- The local player's current AIM direction, as a world-space unit vector (XZ plane; Y kept).
-- ONE shared slot so the input source and the consumers stay decoupled:
--   • writers  → aimstick.luau (mobile thumbstick) or syncPet.luau (desktop mouse)
--   • readers  → syncPet.luau streams it to the server (Aim) + faces the pets
-- Client-only state (each client has its own); the server learns it through the Aim event.
--!strict

local AimState = {}

local dir = Vector3.new(0, 0, -1) -- default: face -Z until the player aims

function AimState.set(v: Vector3)
    if v.Magnitude > 1e-3 then
        dir = v.Unit
    end
end

function AimState.get(): Vector3
    return dir
end

return AimState
