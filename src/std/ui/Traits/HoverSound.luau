--!nocheck
--!native

--[=[
    @class HoverSound (Trait)
    @description: Plays a SoundService sound on MouseEnter. Mirrors ClickSound but for hover.
                  Looks the sound up under SoundService.Generics by name; clones-and-plays so
                  overlapping hovers don't cut each other off.

                  Construction-time config:
                    - sound_name : string (default "Hover")
]=]

local HoverSound = {};
HoverSound.__index = HoverSound;

-- / Services:

local SoundService = game:GetService('SoundService');

-- / Constants:

local DEFAULT_SOUND_NAME = "Hover";
local GENERICS = SoundService:FindFirstChild('Generics');

-- / Constructor:

function HoverSound.new(sound_name : string?)

    local self = setmetatable({}, HoverSound);

    self._SoundName = sound_name or DEFAULT_SOUND_NAME;

    return self;
end

-- / Methods:

function HoverSound:_Apply(element)

    local gui = element.Gui;
    if not gui then return end

    if not gui:IsA("GuiButton") and not gui:IsA("GuiObject") then return end

    local sound = GENERICS and GENERICS:FindFirstChild(self._SoundName);

    local conn = gui.MouseEnter:Connect(function()
        if not sound then return end

        local clone = sound:Clone();
        clone.Parent = SoundService;
        clone:Play();
        clone.Ended:Once(function()
            clone:Destroy();
        end);
    end);

    return function()
        conn:Disconnect();
    end;

end

function HoverSound:_Cleanup() end

return HoverSound;
