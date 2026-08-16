-- std/uiScale.luau
-- Mobile/desktop UI fit. Roblox GUI offsets are RAW PIXELS — fixed-px panels overflow a small
-- (phone / Studio-emulated) viewport. This drops a viewport-driven `UIScale` onto each HUD widget
-- so everything shrinks to fit a small screen and stays pixel-perfect on desktop.
--
-- A UIScale only works parented to a GuiObject (not a ScreenGui), so we attach one PER top-level
-- child of a ScreenGui. Full-bleed backdrops (Size scale ≈ 1×1) are skipped — scaling them would
-- leave black bars. Scaling is about each widget's AnchorPoint, so edge/corner/centre anchors stay
-- pinned where they are; only their size (and descendants) shrink.
--!strict

local Device = require(script.Parent.Device)

local UIScale = {}

local REF = Vector2.new(1280, 720) -- design reference resolution
-- never blow past the desktop design size (MAX=1); floor a bit higher on phones so touch UI
-- doesn't get too tiny to tap (framework Device tells us if we're touch-only)
local MIN = if Device.IsTouchOnly() then 0.6 else 0.5
local MAX = 1.0

local scales: { UIScale } = {}

local function currentFactor(): number
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or REF
    if vp.X < 1 or vp.Y < 1 then return 1 end -- viewport not ready yet
    return math.clamp(math.min(vp.X / REF.X, vp.Y / REF.Y), MIN, MAX)
end

local function applyAll()
    local f = currentFactor()
    for _, s in scales do
        if s.Parent then s.Scale = f end
    end
end

-- a widget whose Size is (≈1 scale, ≈1 scale) is a full-screen backdrop — leave it alone
local function isBackdrop(o: GuiObject): boolean
    local sz = o.Size
    return sz.X.Scale >= 0.99 and sz.Y.Scale >= 0.99
end

local function attachOne(o: Instance)
    if not o:IsA("GuiObject") then return end
    if isBackdrop(o) then return end
    if o:FindFirstChildOfClass("UIScale") then return end -- already has one (ours or a juice trait's)
    local s = Instance.new("UIScale")
    s.Name = "__AutoUIScale"
    s.Scale = currentFactor()
    s.Parent = o
    scales[#scales + 1] = s
end

-- attach to every current + future top-level widget of `gui`
function UIScale.attach(gui: ScreenGui)
    for _, c in gui:GetChildren() do attachOne(c) end
    gui.ChildAdded:Connect(attachOne)
end

-- keep all scales current as the viewport changes (rotation, window resize, device)
local function bindCamera()
    local cam = workspace.CurrentCamera
    if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyAll) end
    applyAll()
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCamera)
bindCamera()

return UIScale
