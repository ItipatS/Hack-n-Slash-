--!nocheck
--!native

--[=[
    @class ClickTween (Trait)
    @description: Activated → click pulse on a child UIScale. Mirrors the original
                  Tweens.SetClick behavior but in trait form. Includes a debounce so
                  rapid clicks don't stack tweens.

                  Construction-time config:
                    - click_scale : number (default 0.95)
                    - duration    : number (default 0.1)
]=]

local ClickTween = {};
ClickTween.__index = ClickTween;

-- / Services:

local TweenService = game:GetService('TweenService');

-- / Constants:

local DEFAULT_SCALE = 0.95;
local DEFAULT_DURATION = 0.1;
local DEBOUNCE_TIME = 0.1;

-- / Constructor:

function ClickTween.new(click_scale : number?, duration : number?)

    local self = setmetatable({}, ClickTween);

    self._ClickScale = click_scale or DEFAULT_SCALE;
    self._Duration = duration or DEFAULT_DURATION;

    return self;
end

-- / Methods:

function ClickTween:_Apply(element)

    local gui = element.Gui;
    if not gui then return end

    if not gui:IsA("GuiButton") then return end

    local UIScale = gui:FindFirstChildOfClass("UIScale");
    if not UIScale then return end

    local info = TweenInfo.new(self._Duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 0, true);
    local clickTween = TweenService:Create(UIScale, info, { Scale = self._ClickScale });

    local debounce = false;

    local conn = gui.Activated:Connect(function()
        if debounce then return end
        debounce = true;
        task.delay(DEBOUNCE_TIME, function() debounce = false end);
        clickTween:Play();
    end);

    return function()
        conn:Disconnect();
        clickTween:Cancel();
    end;

end

function ClickTween:_Cleanup() end

return ClickTween;
