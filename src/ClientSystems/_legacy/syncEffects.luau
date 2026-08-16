-- ClientSystems/syncEffects.luau
-- One-shot AoE visuals for the non-projectile weapons (server applies the damage; this is
-- purely cosmetic): 1=aura pulse ring, 2=melee swing (arc-matched footprint), 3=stone drop,
-- 4=tongue lash (narrow line along dir). Ground FX raycast down so they sit ON the floor,
-- not floating at hip height.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Debris            = game:GetService("Debris")

local std   = ReplicatedStorage.std
local blink = require(std:WaitForChild("ClientNet"))

local DROP_DELAY = 0.8 -- mirror combat.luau

local folder = Instance.new("Folder")
folder.Name = "FX"
folder.Parent = workspace

-- snap an FX position to the floor (server positions are at root/hip height). CanQuery=false
-- visuals (bubbles/pets/mobs/FX) are skipped by raycasts automatically, so this finds the map.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { folder }
local DOWN = Vector3.new(0, -60, 0)
local function groundPos(pos: Vector3): Vector3
    local hit = workspace:Raycast(pos + Vector3.new(0, 6, 0), DOWN, rayParams)
    return if hit then Vector3.new(pos.X, hit.Position.Y + 0.15, pos.Z) else pos
end

-- a flat translucent disc (cylinder laid on its side) on the ground at `pos`
local function disc(pos: Vector3, diameter: number, color: Color3): BasePart
    local p = Instance.new("Part")
    p.Shape = Enum.PartType.Cylinder
    p.Size = Vector3.new(0.4, diameter, diameter)
    p.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
    p.Anchored = true
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.CastShadow = false
    p.Material = Enum.Material.Neon
    p.Color = color
    p.Transparency = 0.45
    p.Parent = folder
    return p
end

-- the firing weapon's color rides the packet (nil → the kind's default tint)
local function tint(e: any, fallback: Color3): Color3
    local c = e.color
    return if c then Color3.new(c.X, c.Y, c.Z) else fallback
end

blink.Effect.On(function(batch)
    for _, e in batch do
        local pos = e.pos :: Vector3
        local r = e.radius

        if e.kind == 1 then -- aura pulse (on the floor, in the pet's color)
            local d = disc(groundPos(pos), r * 2, tint(e, Color3.fromRGB(120, 255, 150)))
            TweenService:Create(d, TweenInfo.new(0.35), { Transparency = 1, Size = Vector3.new(0.4, r * 2.2, r * 2.2) }):Play()
            Debris:AddItem(d, 0.4)

        elseif e.kind == 2 then -- melee swing: a flat WEDGE footprint matching the cone hitbox (arc)
            local dir = e.dir :: Vector3
            local arc = e.arc or math.rad(100)
            local width = math.min(r * 2, 2 * r * math.sin(math.min(arc, math.pi) * 0.5))
            local center = groundPos(pos + dir * (r * 0.5))
            local d = Instance.new("Part")
            d.Size = Vector3.new(width, 0.4, r)
            d.CFrame = CFrame.lookAt(center, center + dir)
            d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false; d.CastShadow = false
            d.Material = Enum.Material.Neon
            d.Color = tint(e, Color3.fromRGB(255, 130, 130))
            d.Transparency = 0.45
            d.Parent = folder
            TweenService:Create(d, TweenInfo.new(0.2), { Transparency = 1 }):Play()
            Debris:AddItem(d, 0.25)

        elseif e.kind == 4 then -- tongue lash: a NARROW line along dir (length = radius), at body height
            local dir = e.dir :: Vector3
            local center = pos + dir * (r * 0.5)
            local d = Instance.new("Part")
            d.Size = Vector3.new(1, 0.8, r)
            d.CFrame = CFrame.lookAt(center, center + dir)
            d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false; d.CastShadow = false
            d.Material = Enum.Material.Neon
            d.Color = tint(e, Color3.fromRGB(255, 120, 160)) -- tongue defaults pink; packets carry frog green
            d.Transparency = 0.15
            d.Parent = folder
            TweenService:Create(d, TweenInfo.new(0.15), { Transparency = 1, Size = Vector3.new(0.3, 0.4, r) }):Play()
            Debris:AddItem(d, 0.2)

        elseif e.kind == 5 then -- EXPLOSION: flash sphere + expanding ground ring (bee bombers / Rebirth / revive)
            local c = tint(e, Color3.fromRGB(255, 160, 60))
            local flash = Instance.new("Part")
            flash.Shape = Enum.PartType.Ball
            flash.Size = Vector3.new(r, r, r)
            flash.CFrame = CFrame.new(pos)
            flash.Anchored = true; flash.CanCollide = false; flash.CanQuery = false; flash.CanTouch = false; flash.CastShadow = false
            flash.Material = Enum.Material.Neon
            flash.Color = c
            flash.Transparency = 0.1
            flash.Parent = folder
            TweenService:Create(flash, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                { Transparency = 1, Size = Vector3.new(r * 2.2, r * 2.2, r * 2.2) }):Play()
            Debris:AddItem(flash, 0.35)
            local ring = disc(groundPos(pos), r * 1.2, c)
            TweenService:Create(ring, TweenInfo.new(0.3), { Transparency = 1, Size = Vector3.new(0.4, r * 2.6, r * 2.6) }):Play()
            Debris:AddItem(ring, 0.35)

        elseif e.kind == 3 then -- stone drop
            local stone = Instance.new("Part")
            stone.Shape = Enum.PartType.Ball
            stone.Size = Vector3.new(r, r, r)
            stone.Color = Color3.fromRGB(120, 100, 80)
            stone.Material = Enum.Material.Slate
            stone.Anchored = true
            stone.CanCollide = false
            stone.CanQuery = false
            stone.CastShadow = false
            stone.CFrame = CFrame.new(pos + Vector3.new(0, 45, 0))
            stone.Parent = folder
            TweenService:Create(stone, TweenInfo.new(DROP_DELAY, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
                { CFrame = CFrame.new(pos + Vector3.new(0, r * 0.4, 0)) }):Play()
            Debris:AddItem(stone, DROP_DELAY + 0.3)
            task.delay(DROP_DELAY, function()
                local ring = disc(groundPos(pos), r * 2, Color3.fromRGB(255, 170, 70))
                TweenService:Create(ring, TweenInfo.new(0.3), { Transparency = 1, Size = Vector3.new(0.4, r * 2.4, r * 2.4) }):Play()
                Debris:AddItem(ring, 0.35)
            end)
        end
    end
end)

return 0
