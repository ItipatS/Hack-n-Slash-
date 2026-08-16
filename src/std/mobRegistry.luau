-- std/mobRegistry.luau
-- Tiny server-side lookup bridging Chrono/render identities to the ECS mob entity. Populated by
-- systems/mobs on spawn/despawn; read by systems/combat to resolve a shapecast-hit hitbox PART (or a
-- Chrono entity id) back to the ECS entity whose Health/Knock it should modify. Server-only shared state
-- (same precedent as std/petRegistry) — the map never needs to replicate.
--!strict

local M = {}

local byPart:     { [BasePart]: any } = {}
local byChronoId: { [number]: { part: BasePart, entity: any } } = {}
local idByEntity: { [any]: number } = {}

function M.register(chronoId: number, part: BasePart, entity: any)
	byPart[part] = entity
	byChronoId[chronoId] = { part = part, entity = entity }
	idByEntity[entity] = chronoId
end

function M.unregister(chronoId: number, part: BasePart?)
	local r = byChronoId[chronoId]
	if r then idByEntity[r.entity] = nil end
	byChronoId[chronoId] = nil
	if part then byPart[part] = nil end
end

function M.entityOfPart(part: BasePart): any
	return byPart[part]
end

function M.entityOfChronoId(chronoId: number): any
	local r = byChronoId[chronoId]
	return r and r.entity
end

-- ECS entity → its Chrono id (so combat can tell clients which rig to react on)
function M.chronoIdOf(entity: any): number?
	return idByEntity[entity]
end

-- iterate every live mob (entity + its hitbox part). Used by combat to do a manual overlap test —
-- robust even if the engine won't spatial-query parts parented under Chrono's storage Camera.
function M.forEach(fn: (entity: any, part: BasePart) -> ())
	for _id, r in byChronoId do
		fn(r.entity, r.part)
	end
end

return M
