-- ClientSystems/playerCamera.luau
-- Custom third-person OVER-THE-RIGHT-SHOULDER camera (always-on shift-lock). The Roblox
-- PlayerModule can't be forced into mouse-lock externally, so this owns the camera outright:
-- CameraType.Scriptable, yaw/pitch accumulated from locked-mouse deltas, wheel zoom, and an
-- occlusion ray so walls never hide the character. Tunables live in animConfig.CAM.
--
--   • Mouse is LOCKED to screen centre while in control; HOLD the FREE_KEY (LeftAlt) to release
--     it for UI — camera holds still, releasing re-locks.
--   • The character's yaw follows this camera via playerAnim's FACE_MODE="camera" (it reads
--     CurrentCamera.LookVector) — strafe/backpedal clips do the rest.
--   • Gamepad: right thumbstick rotates (same yaw/pitch path).
--!strict

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std       = ReplicatedStorage.std
local scheduler = require(std:WaitForChild("scheduler"))
local phases    = require(std:WaitForChild("phases"))
local Cfg       = require(std:WaitForChild("animConfig"))

local CAM = Cfg.CAM
local LP  = Players.LocalPlayer

local yaw   = 0
local pitch = math.rad(-10)
local dist  = CAM.DIST
local freeMouse = false
local padVec = Vector2.zero -- right-thumbstick input (rad/sec applied per frame)

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- seed yaw from wherever the character faces on spawn so the camera doesn't whip around
LP.CharacterAdded:Connect(function(char)
	local root = char:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if root then
		local lv = root.CFrame.LookVector
		yaw = math.atan2(-lv.X, -lv.Z)
		pitch = math.rad(-10)
	end
end)

UserInputService.InputChanged:Connect(function(input, processed)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		if freeMouse then return end
		local sens = CAM.SENS * UserInputService.MouseDeltaSensitivity
		yaw -= input.Delta.X * sens
		pitch = math.clamp(pitch - input.Delta.Y * sens, CAM.PITCH_MIN, CAM.PITCH_MAX)
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		if processed then return end -- over scrolling UI → leave the zoom alone
		dist = math.clamp(dist - input.Position.Z * CAM.ZOOM_STEP, CAM.DIST_MIN, CAM.DIST_MAX)
	elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
		local p = input.Position
		padVec = if p.Magnitude > 0.15 then Vector2.new(p.X, p.Y) else Vector2.zero
	end
end)

ContextActionService:BindAction("HS_FreeMouse", function(_, state)
	if state == Enum.UserInputState.Begin then
		freeMouse = true
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		freeMouse = false
	end
	return Enum.ContextActionResult.Sink
end, false, CAM.FREE_KEY)

local function update(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then return end
	local char = LP.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (char and root) then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		return
	end

	-- gamepad look (per-frame, rate-based)
	if padVec.Magnitude > 0 then
		yaw -= padVec.X * 2.4 * dt
		pitch = math.clamp(pitch + padVec.Y * 1.8 * dt, CAM.PITCH_MIN, CAM.PITCH_MAX)
	end

	cam.CameraType = Enum.CameraType.Scriptable -- every frame: respawn/other scripts reset it
	UserInputService.MouseBehavior = if freeMouse
		then Enum.MouseBehavior.Default
		else Enum.MouseBehavior.LockCenter

	local rot = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
	local pivot = root.Position + Vector3.new(0, CAM.SHOULDER.Y, 0)
		+ rot:VectorToWorldSpace(Vector3.new(CAM.SHOULDER.X, 0, 0))
	local back = rot:VectorToWorldSpace(Vector3.new(0, 0, dist))

	-- occlusion: pull the camera in front of anything between the shoulder pivot and it
	rayParams.FilterDescendantsInstances = { char }
	local hit = workspace:Raycast(pivot, back, rayParams)
	local camPos = if hit then pivot + back.Unit * math.max(0.5, hit.Distance - CAM.OCCLUDE_PAD)
		else pivot + back

	cam.CFrame = CFrame.new(camPos) * rot
	cam.Focus = CFrame.new(pivot)
end

scheduler.SYSTEM(update, phases.PreRender)
return 0
