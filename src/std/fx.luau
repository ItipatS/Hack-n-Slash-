-- std/fx.luau
-- CLIENT-side one-shot VFX/SFX helper. Two jobs: spawn a transient particle burst at a CFrame, and play a
-- sound. Both resolve their template BY NAME (recursively) and warn-once + no-op if it's missing, so combat
-- never breaks on un-authored art.
--
-- Written against how THIS place authors FX (verified in Studio):
--   • VFX (ReplicatedStorage.Assets.VFX) = a **Part** anchoring one or more **Attachments** of
--     ParticleEmitters. The anchor Part ships as a visible 1x1x1 ForceField block — we force it INVISIBLE +
--     inert; it's only a mount point. Some kits ship as a **Model** already.
--   • Emitters ship Enabled=true with a LOW Rate, so we DISABLE them and :Emit(Rate * burst-seconds) — a
--     burst proportional to the artist's own density. An `EmitCount` attribute pins an exact count instead.
--   • SFX (SoundService) = Folders of variants (a random child, optionally filtered by a name prefix).
--
-- SCALING + POOLING (the iter-13 revamp): a kit is sized by wrapping it in a Model and using Model:ScaleTo
-- (scales particle sizes AND attachment offsets together — scaling emitter Size alone leaves offsets at their
-- authored distance so the effect drifts apart). That wrap + ScaleTo + clone + Destroy PER HIT was the cost
-- (Instance churn — the CLAUDE.md "pool everything, no Instance.new in hot paths" rule). So we now POOL the
-- prepared instances **per (name, scale)**: the first burst of a size BUILDS one (clone + wrap + ScaleTo +
-- cache emitters, ONCE); every later burst REUSES a parked instance — PivotTo + re-Emit, then park (NOT
-- Destroy) after ttl. Distinct sizes each keep their own pre-scaled pool, so there's no per-hit ScaleTo.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService      = game:GetService("SoundService")
local Debris            = game:GetService("Debris")

local M = {}

local assets  = ReplicatedStorage:WaitForChild("Assets", 10)
local vfxRoot = assets and assets:FindFirstChild("VFX")

local MAX_PER_KEY = 60 -- concurrency ceiling per (name, scale) — beyond this a burst is dropped (bounded pool)

local warned: { [string]: boolean } = {}
local function warnOnce(kind: string, name: string)
	local k = kind .. ":" .. name
	if warned[k] then return end
	warned[k] = true
	warn(("[fx] %s '%s' not found — effect skipped. Add it (name must match) and it plays automatically."):format(kind, name))
end

-- inert: can't collide, can't be queried, no shadow — but keeps whatever the artist made visible
local function makeInert(p: BasePart)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Material = Enum.Material.SmoothPlastic
end

-- a pure mount point: inert AND invisible (kits ship a visible ForceField block as the emitter anchor)
local function makeAnchor(p: BasePart)
	makeInert(p)
	p.Transparency = 1
end

-- ── Pool ─────────────────────────────────────────────────────────────────────────────
type Prepared = { model: Model, emitters: { ParticleEmitter } }
type Pool = { free: { Prepared }, active: number }
local pools: { [string]: Pool } = {}

-- BUILD one prepared instance for `name` at `scale`: clone → wrap in a Model (unless it already is one) →
-- make parts inert → ScaleTo (ONCE) → cache + disable the emitters → park (parent nil). Returns nil on a
-- missing/invalid kit. This is the only place that clones — every subsequent burst reuses the result.
local function buildPrepared(name: string, scale: number): Prepared?
	if not vfxRoot then return nil end
	local tpl = vfxRoot:FindFirstChild(name, true)
	if not tpl then warnOnce("VFX", name); return nil end

	local clone = tpl:Clone()
	local model: Model
	if clone:IsA("Model") then
		model = clone
		local pp = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
		if not pp then clone:Destroy(); return nil end
		model.PrimaryPart = pp
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then makeInert(d) end
		end
	else
		model = Instance.new("Model")
		local anchor: BasePart
		if clone:IsA("BasePart") then -- the house pattern: Part + Attachment(s) of emitters
			anchor = clone
			makeAnchor(anchor)
		elseif clone:IsA("Attachment") then -- a bare Attachment kit needs a part to live on
			anchor = Instance.new("Part")
			anchor.Size = Vector3.one
			makeAnchor(anchor)
			clone.Parent = anchor
		else
			clone:Destroy(); model:Destroy(); return nil
		end
		anchor.Parent = model
		model.PrimaryPart = anchor
	end

	if scale ~= 1 then model:ScaleTo(scale) end -- scales particles AND attachment offsets together (once)

	local emitters: { ParticleEmitter } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d.Enabled = false
			emitters[#emitters + 1] = d
		end
	end
	model.Parent = nil -- parked until first fire
	return { model = model, emitters = emitters }
end

-- Spawn `name` at `cf`, sized by `scale` (pre-scaled pooled instance — no per-hit ScaleTo). `emitBurst` =
-- seconds-of-authored-Rate worth of particles; `ttl` = park delay (keep it above the particles' Lifetime).
function M.burst(name: string, cf: CFrame, scale: number?, ttl: number?, emitBurst: number?)
	local s = scale or 1
	local key = name .. "@" .. string.format("%.2f", s)
	local pool = pools[key]
	if not pool then pool = { free = {}, active = 0 }; pools[key] = pool end

	local prep = table.remove(pool.free)
	if not prep then
		if pool.active >= MAX_PER_KEY then return end -- bounded: drop rather than build unboundedly
		prep = buildPrepared(name, s)
		if not prep then return end
	end

	local model = prep.model
	model:PivotTo(cf)
	model.Parent = workspace
	local burst = emitBurst or 0.35
	for _, e in prep.emitters do
		local n = e:GetAttribute("EmitCount")
		if typeof(n) ~= "number" then n = math.max(1, math.round(e.Rate * burst)) end
		e:Emit(n :: number)
	end
	pool.active += 1

	task.delay(ttl or 2, function() -- PARK (not Destroy) → reused by the next burst of this size
		model.Parent = nil
		pool.active -= 1
		pool.free[#pool.free + 1] = prep :: Prepared
	end)
end

-- ── Sound (unchanged) ────────────────────────────────────────────────────────────────
local function resolveSound(name: string, pick: string?): Sound?
	local found = SoundService:FindFirstChild(name, true)
	if not found then return nil end
	if found:IsA("Sound") then return found end
	local options: { Sound } = {}
	for _, d in found:GetDescendants() do
		if d:IsA("Sound") and (not pick or string.sub(d.Name, 1, #pick) == pick) then
			options[#options + 1] = d
		end
	end
	if #options == 0 then return nil end
	return options[math.random(1, #options)]
end

function M.sound(name: string, pos: Vector3?, pick: string?, ttl: number?)
	local tpl = resolveSound(name, pick)
	if not tpl then warnOnce("Sound", name); return end
	local s = tpl:Clone()
	local life = ttl or 4
	if pos then
		local p = Instance.new("Part")
		p.Size = Vector3.one
		makeAnchor(p)
		p.CFrame = CFrame.new(pos)
		s.Parent = p
		p.Parent = workspace
		s:Play()
		Debris:AddItem(p, life)
	else
		s.Parent = SoundService
		s:Play()
		Debris:AddItem(s, life)
	end
end

return M
