-- ClientSystems/damageText.luau
-- Pooled floating damage numbers. `M.pop(worldPos, amount, heavy)` spawns a rising, fading number at a hit.
-- SCREEN-PROJECTED (WorldToViewportPoint each frame) rather than a BillboardGui-per-number, so there are NO
-- per-number Instances churning in the world — just pooled TextLabels moved in 2D. Pool-capped, so a swing
-- that catches 100 mobs pops 100 numbers and still holds frame (a small scale flex in its own right).
--!strict

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local LP  = Players.LocalPlayer
local gui = LP:WaitForChild("PlayerGui")

local M = {}

local CAP        = 90    -- max concurrent numbers (oldest recycled → bounded cost at scale)
local TTL        = 0.72  -- seconds a number lives
local RISE       = 7.5   -- studs/sec it floats up
local DRIFT      = 4.0   -- studs/sec initial random horizontal spread (eases out)
local LIGHT_SIZE = 22
local HEAVY_SIZE = 30
local rng        = Random.new()

local screen = Instance.new("ScreenGui")
screen.Name = "DamageText"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 20
screen.Parent = gui

type Num = { label: TextLabel, pos: Vector3, vel: Vector3, t0: number, size: number }
local pool:   { TextLabel } = {}
local active: { Num } = {}

local function newLabel(): TextLabel
	local l = Instance.new("TextLabel")
	l.Size = UDim2.fromOffset(90, 28)
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBlack
	l.TextStrokeTransparency = 0.25
	l.TextStrokeColor3 = Color3.new(0, 0, 0)
	l.Visible = false
	l.Parent = screen
	return l
end

function M.pop(worldPos: Vector3, amount: number, heavy: boolean)
	if #active >= CAP then -- recycle the oldest to stay bounded
		local old = table.remove(active, 1)
		if old then old.label.Visible = false; pool[#pool + 1] = old.label end
	end
	local label = table.remove(pool) or newLabel()
	label.Text = tostring(math.floor(amount + 0.5))
	label.TextColor3 = if heavy then Color3.fromRGB(255, 168, 58) else Color3.fromRGB(255, 244, 208)
	local size = if heavy then HEAVY_SIZE else LIGHT_SIZE
	label.TextSize = size
	label.TextTransparency = 0
	label.TextStrokeTransparency = 0.25
	label.Visible = true
	active[#active + 1] = {
		label = label,
		pos = worldPos + Vector3.new(rng:NextNumber(-0.6, 0.6), 0.8, rng:NextNumber(-0.6, 0.6)),
		vel = Vector3.new(rng:NextNumber(-DRIFT, DRIFT), RISE, rng:NextNumber(-DRIFT, DRIFT)),
		t0 = os.clock(),
		size = size,
	}
end

RunService.RenderStepped:Connect(function(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then return end
	local now = os.clock()
	local i = 1
	while i <= #active do
		local n = active[i]
		local t = now - n.t0
		if t >= TTL then
			n.label.Visible = false
			pool[#pool + 1] = n.label
			local last = #active
			active[i] = active[last]
			active[last] = nil
		else
			n.pos += n.vel * dt
			n.vel = Vector3.new(n.vel.X * (1 - dt * 4), n.vel.Y - dt * 6, n.vel.Z * (1 - dt * 4)) -- ease drift, slight fall
			local sp, onScreen = cam:WorldToViewportPoint(n.pos)
			if onScreen then
				n.label.Visible = true
				n.label.Position = UDim2.fromOffset(sp.X, sp.Y)
				local a = t / TTL
				local fade = math.clamp((a - 0.4) / 0.6, 0, 1) -- hold, then fade over the last 60%
				n.label.TextTransparency = fade
				n.label.TextStrokeTransparency = 0.25 + fade * 0.75
				n.label.TextSize = n.size * (1 + 0.35 * math.max(0, 1 - t * 9)) -- pop on spawn, settle
			else
				n.label.Visible = false
			end
			i += 1
		end
	end
end)

return M
