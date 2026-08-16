-- std/bossLabel.luau
-- A floating "BOSS" billboard so the player can find the boss in a 1000-mob horde. Attached to
-- the boss's root part; AlwaysOnTop so it shows through the crowd. Returns the BillboardGui so the
-- caller can destroy it when the boss dies (zombie rigs are POOLED → the tag must not linger).
--!strict

local bossLabel = {}

function bossLabel.attach(adornee: BasePart, yOffset: number): BillboardGui
    local bb = Instance.new("BillboardGui")
    bb.Name = "BossTag"
    bb.Size = UDim2.fromOffset(140, 38)
    bb.StudsOffsetWorldSpace = Vector3.new(0, yOffset, 0)
    bb.AlwaysOnTop = true
    bb.MaxDistance = 1500
    bb.LightInfluence = 0
    bb.Adornee = adornee
    bb.Parent = adornee

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.fromScale(1, 1)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamBlack
    lbl.TextScaled = true
    lbl.TextColor3 = Color3.fromRGB(255, 70, 70)
    lbl.TextStrokeTransparency = 0
    lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
    lbl.Text = "👑 BOSS"
    lbl.Parent = bb

    return bb
end

return bossLabel
