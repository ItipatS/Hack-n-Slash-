--!nocheck
--!native

--[=[
    @Util: Tweens.luau
    @description: Simple tween module to connect buttons to basic tweens and sum
]=]

local Tweens = {}

-- / Services:

local Lighting = game:GetService('Lighting')
local TweenService = game:GetService('TweenService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local SoundService = game:GetService('SoundService')

-- / Dependency injection:

local _tweenServiceOverride = nil;
local _uiSoundsOverride = nil;

function Tweens._init(tweenServiceOverride, uiSoundsOverride)
    _tweenServiceOverride = tweenServiceOverride
    _uiSoundsOverride = uiSoundsOverride
end

-- / Variables:

local HoverConnections = {}
local ClickConnections = {}
local LastOpenedFrame = nil

-- / Constants:

local HOVER_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 0, false, 0);
local CLICK_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 0, true);
local CollectionService = game:GetService('CollectionService');

local GENERICS = SoundService:FindFirstChild('Generics');
local HOVER_SOUND = GENERICS and GENERICS:FindFirstChild('Hover');
local CLICK_SOUND = GENERICS and GENERICS:FindFirstChild('Click');
local ROBUX_CLICK_SOUND = GENERICS and GENERICS:FindFirstChild('RobuxClick');

-- / Functions

--[=[
    @function SetHover
    @description: Sets hover tween for selected group of buttons
]=]

function Tweens.SetHover(buttons : {GuiButton}, hoverScale : number, overwritePreviousConnection : boolean?)
	assert(buttons, `buttons not defined`)
	assert(hoverScale, `hover_scale not defined`)

    assert(typeof(buttons) == "table", `Buttons wrong type, expeceted table, got {typeof(buttons)}`)
	assert(typeof(hoverScale) == "number", `Hover_scale wrong type, expected number, got {typeof(hoverScale)}`)

    for _, button: GuiButton in buttons do
        if not button:IsA("GuiButton") then continue end

        local hasPreviousConnection: RBXScriptConnection = HoverConnections[button]
        if hasPreviousConnection and overwritePreviousConnection == false then
            continue
        end

        if hasPreviousConnection then HoverConnections[button]:Disconnect() HoverConnections[button] = nil end

        local uiScale: UIScale? = button:FindFirstChildOfClass("UIScale")
        if not uiScale then
            continue
        end

        local hoverTween: Tween = TweenService:Create(uiScale, HOVER_TWEEN, {Scale = hoverScale})
        local unhoverTween: Tween = TweenService:Create(uiScale, HOVER_TWEEN, {Scale = 1})

        button.MouseEnter:Connect(function()
            hoverTween:Play()

            if not HOVER_SOUND then return end
            local clone = HOVER_SOUND:Clone()
            clone.Parent = SoundService
            clone:Play()
            clone.Ended:Once(function()
                clone:Destroy()
            end)
        end)

        button.MouseLeave:Connect(function()
            unhoverTween:Play()
        end)
    end
end

--[=[
    @function SetClick
    @description: Sets click tween for selected group of buttons
]=]

function Tweens.SetClick(buttons : {GuiButton}, clickScale : number, overwritePreviousConnection : boolean?)
	assert(buttons, `buttons not defined`)
	assert(clickScale, `clickScale not defined`)

	assert(typeof(buttons) == "table", `Buttons wrong type, expeceted table, got {typeof(buttons)}`)
	assert(typeof(clickScale) == "number", `Click_scale wrong type, expected number, got {typeof(clickScale)}`)

	for _, button: GuiButton in buttons do
		if not button:IsA("GuiButton") then continue end

		local hasPreviousConnection: RBXScriptConnection = ClickConnections[button]
		if hasPreviousConnection and overwritePreviousConnection == false then
			continue
		end

		if hasPreviousConnection then ClickConnections[button]:Disconnect() ClickConnections[button] = nil end

		local uiScale: UIScale? = button:FindFirstChildOfClass("UIScale")
		if not uiScale then
			continue
		end

		local clickTween: Tween = TweenService:Create(uiScale, CLICK_TWEEN, {Scale = clickScale})
        local debounce: boolean = false

		local isRobuxInitiator = CollectionService:HasTag(button, 'RobuxInitiator')

		button.Activated:Connect(function()
            if debounce then return end
            debounce = true

            task.delay(0.1, function() debounce = false end)
			clickTween:Play()

			local sound = if isRobuxInitiator and ROBUX_CLICK_SOUND then ROBUX_CLICK_SOUND else CLICK_SOUND
			if not sound then return end
			local clone = sound:Clone()
			clone.Parent = SoundService
			clone:Play()
			clone.Ended:Once(function()
				clone:Destroy()
			end)
		end)
	end
end


return Tweens