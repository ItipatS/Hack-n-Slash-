-- std/MobRenderPool.luau
-- Recycled anchored-RIG pool for the horde. One cheap zombie rig per visible mob. Each rig is
-- ONE anchored root (PrimaryPart / HumanoidRootPart) with unanchored, jointed (Motor6D) limbs —
-- so moving just the root in BULK via WorldRoot:BulkMoveTo drags the whole body (the joint
-- solver carries the limbs). Phase-0 finding holds: drawing the parts is GPU-free; the cost is
-- applying transforms, so we batch only the roots.
--
-- Usage:
--   local pool = MobRenderPool.new(templateModel, folder)  -- template Model with a PrimaryPart
--   pool:acquire(key, cf, scale)  -- spawn (idempotent per key); scale>1 = bigger (elite/boss)
--   pool:setCFrame(key, cf)       -- queue this frame's root transform (no instance write yet)
--   pool:flush()                  -- one BulkMoveTo for every active root
--   pool:release(key)             -- despawn → rig recycled
--   pool:get(key)                 -- current root BasePart or nil
--   pool:getModel(key)            -- current rig Model or nil
--
-- Internally keeps parallel structures so release is O(1) (swap-remove):
--   parts[i] (roots), cfs[i], keyAt[i], models[i]  and  index[key] = i
--!optimize 2
--!native
--!strict

local SpatialHash = require(script.Parent.spatialhash)

local MobRenderPool = {}
MobRenderPool.__index = MobRenderPool

-- shared scratch for the separation pass (one mob pool in practice)
local sepHash = SpatialHash.new(8)
local sepOut: { number } = {}

export type Pool = typeof(setmetatable(
    {} :: {
        template: Model,
        folder: Instance,
        parts: { BasePart }, -- the rig roots (PrimaryParts) — what BulkMoveTo moves
        cfs: { CFrame },
        keyAt: { any },
        models: { Model },
        index: { [any]: number },
        free: { Model },
    },
    MobRenderPool
))

function MobRenderPool.new(template: Model, folder: Instance): Pool
    return setmetatable({
        template = template,
        folder = folder,
        parts = {},
        cfs = {},
        keyAt = {},
        models = {},
        index = {},
        free = {},
    }, MobRenderPool)
end

function MobRenderPool.get(self: Pool, key: any): BasePart?
    local i = self.index[key]
    return if i then self.parts[i] else nil
end

function MobRenderPool.getModel(self: Pool, key: any): Model?
    local i = self.index[key]
    return if i then self.models[i] else nil
end

function MobRenderPool.acquire(self: Pool, key: any, cf: CFrame, scale: number?): Model
    local i = self.index[key]
    if i then
        return self.models[i]
    end
    local model = table.remove(self.free) or self.template:Clone()
    local prim = model.PrimaryPart :: BasePart
    local s = scale or 1
    if model:GetScale() ~= s then
        model:ScaleTo(s) -- elite/boss = bigger rig (joints scale too)
    end
    prim.CFrame = cf
    model.Parent = self.folder
    local n = #self.parts + 1
    self.parts[n] = prim
    self.cfs[n] = cf
    self.keyAt[n] = key
    self.models[n] = model
    self.index[key] = n
    return model
end

function MobRenderPool.setCFrame(self: Pool, key: any, cf: CFrame)
    local i = self.index[key]
    if i then
        self.cfs[i] = cf
    end
end

function MobRenderPool.release(self: Pool, key: any)
    local i = self.index[key]
    if not i then
        return
    end
    local parts, cfs, keyAt, models, index = self.parts, self.cfs, self.keyAt, self.models, self.index
    local n = #parts
    local model = models[i]

    -- swap the last entry into slot i, then truncate
    local lastKey = keyAt[n]
    parts[i] = parts[n]
    cfs[i] = cfs[n]
    keyAt[i] = lastKey
    models[i] = models[n]
    index[lastKey] = i

    parts[n] = nil
    cfs[n] = nil
    keyAt[n] = nil
    models[n] = nil
    index[key] = nil -- after, so the i==n self-removal lands correctly

    model.Parent = nil
    self.free[#self.free + 1] = model
end

-- Spread overlapping mobs apart in XZ (one relaxation step) so a horde piling on the player
-- doesn't draw 1000 rigs on the same pixels — overdraw is what tanks FPS when stacked. Pure
-- render-side nudge of the queued root CFrames; call before flush().
--   yBand   — only push apart mobs within this height of each other, so a pile at a wedge/cliff
--             doesn't fling top-level mobs against base-level ones (the "explode" bug).
--   maxPush — clamp the per-frame displacement so an ultra-dense chokepoint can't blow up.
function MobRenderPool.separate(self: Pool, radius: number, strength: number, yBand: number, maxPush: number)
    local cfs = self.cfs
    local n = #self.parts
    if n < 2 then return end
    local r2 = radius * radius
    local maxPush2 = maxPush * maxPush

    sepHash:beginFrame()
    for i = 1, n do
        local p = cfs[i].Position
        sepHash:insert(i, p.X, p.Y, p.Z)
    end

    for i = 1, n do
        local p = cfs[i].Position
        local cnt = sepHash:queryInto(p.X, p.Y, p.Z, sepOut)
        local px, pz = 0, 0
        for j = 1, cnt do
            local k = sepOut[j]
            if k ~= i then
                local q = cfs[k].Position
                if math.abs(p.Y - q.Y) <= yBand then -- same level only
                    local dx, dz = p.X - q.X, p.Z - q.Z
                    local d2 = dx * dx + dz * dz
                    if d2 > 1e-4 and d2 < r2 then
                        local d = math.sqrt(d2)
                        local w = (radius - d) / radius
                        px += dx / d * w
                        pz += dz / d * w
                    end
                end
            end
        end
        px *= strength
        pz *= strength
        local m2 = px * px + pz * pz
        if m2 > maxPush2 then
            local s = maxPush / math.sqrt(m2)
            px *= s
            pz *= s
        end
        if px ~= 0 or pz ~= 0 then
            cfs[i] = cfs[i] + Vector3.new(px, 0, pz)
        end
    end
end

function MobRenderPool.flush(self: Pool)
    if #self.parts > 0 then
        -- FireCFrameChanged is the LIGHTER BulkMoveMode (the only other value is FireAllEvents; there is NO
        -- "None"). With nothing connected to these roots' CFrameChanged it fires into the void for ~free, so
        -- the mode was never the cost — the per-frame LuaBridge hit was the per-mob leg writes (MobCfg.FAR_LEGS,
        -- now off). One BulkMoveTo moves every root in a single engine call regardless of the mode.
        workspace:BulkMoveTo(self.parts, self.cfs, Enum.BulkMoveMode.FireCFrameChanged)
    end
end

return MobRenderPool
