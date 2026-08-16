-- std/pet.luau
-- Pet placement on a RING around the owner (so multiple pets distribute evenly). The pet
-- doesn't orbit; it holds its ring slot and follows the owner. Pure function of owner pos +
-- slot, so server (bubble origin) and client (render) agree.
--!strict

local Pet = {}

Pet.RADIUS = 5   -- studs out from the owner
Pet.HEIGHT = 1   -- studs up from the owner's root (beside, not on the head)

-- Position of pet `index` (0-based) of `count` total, on the ring around `center`.
function Pet.slotPos(center: Vector3, index: number, count: number): Vector3
    local a = (index / math.max(count, 1)) * (2 * math.pi)
    return center + Vector3.new(math.cos(a) * Pet.RADIUS, Pet.HEIGHT, math.sin(a) * Pet.RADIUS)
end

-- Single-pet convenience (slot 0 of 1).
function Pet.pos(center: Vector3): Vector3
    return Pet.slotPos(center, 0, 1)
end

return Pet
