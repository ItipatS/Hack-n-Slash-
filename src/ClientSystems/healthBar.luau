-- ClientSystems/healthBar.luau
-- Pooled mob health bars. A BillboardGui ADORNED to the mob's rig root follows it natively (engine-side) —
-- so there are NO per-frame Lua position writes (the horde-scale trap). The fill is updated only ON a hit;
-- the bar auto-hides after TTL of no damage. Full-HP mobs never show one. `mobs` calls show()/hide().
--!strict

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local LP  = Players.LocalPlayer
local gui = LP:WaitForChild("PlayerGui")

local M = {}

local TTL = 2.5 -- seconds a bar stays after the last hit, then hides

local screen = Instance.new("ScreenGui") -- BillboardGuis parent here (they render in 3D via Adornee)
screen.Name = "MobHealthBars"
screen.ResetOnSpawn = false
screen.Parent = gui

type Bar = { bg: BillboardGui, fill: Frame }
local pool:   { Bar } = {}
local active: { [BasePart]: { bar: Bar, hideAt: number } } = {}

local function newBar(): Bar
	local bg = Instance.new("BillboardGui")
	bg.Size = UDim2.fromOffset(58, 7)
	bg.StudsOffset = Vector3.new(0, 3.4, 0) -- above the head
	bg.AlwaysOnTop = true
	bg.MaxDistance = 70
	bg.Enabled = false
	bg.Parent = screen
	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	back.BackgroundTransparency = 0.2
	back.BorderSizePixel = 0
	back.Parent = bg
	Instance.new("UICorner", back).CornerRadius = UDim.new(1, 0)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(220, 60, 60)
	fill.BorderSizePixel = 0
	fill.Parent = back
	Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)
	return { bg = bg, fill = fill }
end

-- show/refresh a bar over `adornee` at HP fraction `frac`. frac >= 1 → nothing (don't clutter full-HP mobs).
function M.show(adornee: BasePart, frac: number)
	frac = math.clamp(frac, 0, 1)
	local rec = active[adornee]
	if not rec then
		if frac >= 1 then return end
		local bar = table.remove(pool) or newBar()
		bar.bg.Adornee = adornee
		bar.bg.Enabled = true
		active[adornee] = { bar = bar, hideAt = 0 }
		rec = active[adornee]
	end
	local bar = rec.bar
	bar.fill.Size = UDim2.fromScale(frac, 1)
	-- green (full) → red (empty)
	bar.fill.BackgroundColor3 = Color3.fromRGB(220, 60, 60):Lerp(Color3.fromRGB(90, 210, 100), frac)
	rec.hideAt = os.clock() + TTL
end

function M.hide(adornee: BasePart)
	local rec = active[adornee]
	if not rec then return end
	rec.bar.bg.Enabled = false
	rec.bar.bg.Adornee = nil
	pool[#pool + 1] = rec.bar
	active[adornee] = nil
end

-- auto-hide expired bars (collect-then-hide — don't mutate `active` mid-iteration)
RunService.Heartbeat:Connect(function()
	local now = os.clock()
	local expired: { BasePart }? = nil
	for adornee, rec in active do
		if now >= rec.hideAt then
			expired = expired or {}
			expired[#expired + 1] = adornee
		end
	end
	if expired then for _, a in expired do M.hide(a) end end
end)

return M
