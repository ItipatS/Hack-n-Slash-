-- std/mobBar.luau
-- A floating HEALTH BAR billboard for elite/boss mobs (so you can find them in the horde AND see
-- how close they are to dying). AlwaysOnTop so it shows through the crowd. Bosses also get a
-- "👑 BOSS" caption + a bigger red bar; elites get a smaller orange bar. Returns the BillboardGui
-- (destroy it when the mob dies — pooled zombie rigs reuse parts, so the tag must not linger) and
-- the fill Frame (set its X scale to hp/max).
--!strict

local mobBar = {}

function mobBar.attach(adornee: BasePart, yOffset: number, isBoss: boolean): (BillboardGui, Frame)
    local barH = if isBoss then 16 else 12
    local bb = Instance.new("BillboardGui")
    bb.Name = "MobBar"
    bb.Size = UDim2.fromOffset(if isBoss then 150 else 110, if isBoss then 42 else barH)
    bb.StudsOffsetWorldSpace = Vector3.new(0, yOffset, 0)
    bb.AlwaysOnTop = true
    bb.MaxDistance = 1500
    bb.LightInfluence = 0
    bb.Adornee = adornee
    bb.Parent = adornee

    if isBoss then
        local lbl = Instance.new("TextLabel")
        lbl.AnchorPoint = Vector2.new(0.5, 0)
        lbl.Position = UDim2.new(0.5, 0, 0, 0)
        lbl.Size = UDim2.new(1, 0, 0, 22)
        lbl.BackgroundTransparency = 1
        lbl.Font = Enum.Font.GothamBlack
        lbl.TextScaled = true
        lbl.TextColor3 = Color3.fromRGB(255, 70, 70)
        lbl.TextStrokeTransparency = 0
        lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
        lbl.Text = "👑 BOSS"
        lbl.Parent = bb
    end

    local bg = Instance.new("Frame")
    bg.AnchorPoint = Vector2.new(0.5, 1)
    bg.Position = UDim2.new(0.5, 0, 1, 0)
    bg.Size = UDim2.new(1, 0, 0, barH)
    bg.BackgroundColor3 = Color3.fromRGB(26, 10, 10)
    bg.BackgroundTransparency = 0.2
    bg.BorderSizePixel = 0
    bg.Parent = bb
    Instance.new("UICorner").Parent = bg
    local pad = Instance.new("UIStroke")
    pad.Color = Color3.fromRGB(0, 0, 0)
    pad.Thickness = 1.5
    pad.Parent = bg

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(1, 0, 1, 0) -- X scale = hp/max
    fill.BackgroundColor3 = if isBoss then Color3.fromRGB(255, 60, 60) else Color3.fromRGB(255, 160, 50)
    fill.BorderSizePixel = 0
    fill.Parent = bg
    Instance.new("UICorner").Parent = fill

    return bb, fill
end

return mobBar
