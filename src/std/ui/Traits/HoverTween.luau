--!nocheck
--!native

--[=[
    @class HoverTween (Trait)
    @description: MouseEnter / MouseLeave tween on a child UIScale. Mirrors the original
                  Tweens.SetHover behavior but in trait form.

                  Construction-time config:
                    - hover_scale : number (default 1.15)
                    - duration    : number (default 0.1)

                  When constructed via tag factory, reads attributes off the gui:
                    - HoverScale     -> hover_scale
                    - HoverDuration  -> duration
]=]

local HoverTween = {};
HoverTween.__index = HoverTween;

-- / Services:

local TweenService = game:GetService('TweenService');

-- / Constants:

local DEFAULT_SCALE = 1.15;
local DEFAULT_DURATION = 0.1;
local TWEEN_INFO = function(duration : number)
    return TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 0, false, 0);
end

-- / Constructor:

function HoverTween.new(hover_scale : number?, duration : number?)

    local self = setmetatable({}, HoverTween);

    self._HoverScale = hover_scale or DEFAULT_SCALE;
    self._Duration = duration or DEFAULT_DURATION;

    return self;
end

-- / Methods:

function HoverTween:_Apply(element)

    local gui = element.Gui;
    if not gui then return end

    if not gui:IsA("GuiButton") and not gui:IsA("GuiObject") then return end

    local UIScale = gui:FindFirstChildOfClass("UIScale");
    if not UIScale then return end

    local info = TWEEN_INFO(self._Duration);
    local hoverTween = TweenService:Create(UIScale, info, { Scale = self._HoverScale });
    local unhoverTween = TweenService:Create(UIScale, info, { Scale = 1 });

    local enterConn = gui.MouseEnter:Connect(function()
        hoverTween:Play();
    end);

    local leaveConn = gui.MouseLeave:Connect(function()
        unhoverTween:Play();
    end);

    return function()
        enterConn:Disconnect();
        leaveConn:Disconnect();
        hoverTween:Cancel();
        unhoverTween:Cancel();
    end;

end

function HoverTween:_Cleanup() end

return HoverTween;
