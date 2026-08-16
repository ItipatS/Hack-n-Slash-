-- ClientSystems/xp.luau
-- XP gems + leveling (client-side — PvE, so no need to make it authoritative). A dead mob drops a pooled
-- gem that MAGNETS to the player; collecting it adds XP; filling the bar LEVELS UP and opens the pick-1-of-3
-- card screen. Gems are pooled + capped (overflow deaths grant XP directly, no gem) so the horde can't flood
-- the field. Upgrade EFFECTS are stubbed for now ("random bullshit is fine") — recorded + printed; the card
-- SCREEN is the showcase.
--!strict

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remote       = ReplicatedStorage:WaitForChild("CombatRemote") :: RemoteEvent
local Upgrades     = require(ReplicatedStorage.std.upgrades)
local upgradeStats = require(ReplicatedStorage.std.upgradeStats)
local runStats     = require(ReplicatedStorage.std.runStats) -- shared client stat set (playerAnim reads it)
local LevelUp      = require(script.Parent.levelUpCards)

local LP  = Players.LocalPlayer
local gui = LP:WaitForChild("PlayerGui")

-- ── tunables ─────────────────────────────────────────────────────────────────────
local GEM_CAP      = 110
local MAGNET_RANGE = 16   -- studs — inside this a gem flies to you
local COLLECT_RANGE = 2.4
local MAGNET_ACCEL = 130
local XP_PER_GEM   = 1
local function xpNeed(level: number): number return 5 + (level - 1) * 4 end

-- ── gem pool ─────────────────────────────────────────────────────────────────────
local folder = Instance.new("Folder")
folder.Name = "XPGems"
folder.Parent = workspace

local function newGem(): BasePart
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.one * 0.6
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(90, 220, 255)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

type Gem = { part: BasePart, pos: Vector3, vel: Vector3 }
local pool: { BasePart } = {}
local gems: { Gem } = {}

-- ── xp state + HUD ───────────────────────────────────────────────────────────────
local level, xp = 1, 0

local screen = Instance.new("ScreenGui")
screen.Name = "XPBar"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 22
screen.Parent = gui

local barBg = Instance.new("Frame")
barBg.Size = UDim2.new(0, 360, 0, 12)
barBg.AnchorPoint = Vector2.new(0.5, 1)
barBg.Position = UDim2.new(0.5, 0, 1, -12)
barBg.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
barBg.BackgroundTransparency = 0.25
barBg.BorderSizePixel = 0
barBg.Parent = screen
Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)

local barFill = Instance.new("Frame")
barFill.Size = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = Color3.fromRGB(90, 220, 255)
barFill.BorderSizePixel = 0
barFill.Parent = barBg
Instance.new("UICorner", barFill).CornerRadius = UDim.new(1, 0)

local lvlL = Instance.new("TextLabel")
lvlL.Size = UDim2.new(0, 60, 1, 6)
lvlL.AnchorPoint = Vector2.new(1, 0.5)
lvlL.Position = UDim2.new(0, -8, 0.5, 0)
lvlL.BackgroundTransparency = 1
lvlL.Font = Enum.Font.GothamBlack
lvlL.TextSize = 15
lvlL.TextColor3 = Color3.fromRGB(230, 240, 250)
lvlL.TextXAlignment = Enum.TextXAlignment.Right
lvlL.Text = "Lv 1"
lvlL.Parent = barBg

local function refreshBar()
	lvlL.Text = "Lv " .. level
	local frac = math.clamp(xp / xpNeed(level), 0, 1)
	barFill.Size = UDim2.new(frac, 0, 1, 0)
end
refreshBar()

-- ── upgrades (effects STUBBED for now — recorded + printed) ─────────────────────────
local function applyUpgrade(u: Upgrades.Upgrade)
	upgradeStats.apply(runStats, u.key)  -- CLIENT effects: playerAnim reads runStats live (speed/jump/air-jumps)
	remote:FireServer("upgrade", u.key)  -- SERVER effects: combat folds it into this player's stat set
	print(("[xp] picked '%s' (%s)"):format(u.name, Upgrades.RARITY[u.rarity].name))
end

local function addXP(amount: number)
	xp += amount
	while xp >= xpNeed(level) do
		xp -= xpNeed(level)
		level += 1
		LevelUp.open(applyUpgrade) -- pause + blur + pick a card
	end
	refreshBar()
end

-- ── spawn a gem on mob death (or grant XP directly if the field is full) ────────────
local function spawnGem(pos: Vector3)
	if #gems >= GEM_CAP then addXP(XP_PER_GEM); return end
	local part = table.remove(pool) or newGem()
	local gp = pos + Vector3.new(0, 1.5, 0)
	part.CFrame = CFrame.new(gp)
	part.Parent = folder
	gems[#gems + 1] = {
		part = part,
		pos = gp,
		vel = Vector3.new((math.random() - 0.5) * 6, 8 + math.random() * 4, (math.random() - 0.5) * 6),
	}
end

remote.OnClientEvent:Connect(function(kind: any, _a: any, cf: any)
	if kind == "mobdeath" and typeof(cf) == "CFrame" then
		spawnGem(cf.Position)
	end
end)

-- ── update: pop → settle → magnet → collect ─────────────────────────────────────────
RunService.Heartbeat:Connect(function(dt: number)
	local char = LP.Character
	local root = char and (char.PrimaryPart or char:FindFirstChild("HumanoidRootPart")) :: BasePart?
	local pp = root and root.Position
	local i = 1
	while i <= #gems do
		local g = gems[i]
		local collected = false
		if pp then
			local to = pp - g.pos
			local d2 = to.X * to.X + to.Y * to.Y + to.Z * to.Z
			if d2 <= COLLECT_RANGE * COLLECT_RANGE then
				collected = true
			elseif d2 <= MAGNET_RANGE * MAGNET_RANGE then
				g.vel += to.Unit * MAGNET_ACCEL * dt -- accelerate toward the player
			else
				g.vel = Vector3.new(g.vel.X * (1 - dt * 3), g.vel.Y - 30 * dt, g.vel.Z * (1 - dt * 3)) -- settle
			end
		end
		if collected then
			g.part.Parent = nil
			pool[#pool + 1] = g.part
			local last = #gems
			gems[i] = gems[last]; gems[last] = nil
			addXP(XP_PER_GEM)
		else
			-- clamp speed so magneted gems don't overshoot wildly
			local sp = g.vel.Magnitude
			if sp > 90 then g.vel = g.vel.Unit * 90 end
			g.pos += g.vel * dt
			if g.pos.Y < -300 then -- fell into a void → recycle
				g.part.Parent = nil; pool[#pool + 1] = g.part
				local last = #gems; gems[i] = gems[last]; gems[last] = nil
			else
				g.part.CFrame = CFrame.new(g.pos)
				i += 1
			end
		end
	end
end)

return 0
