--!nocheck
--!native

--[=[
    @class ClickSound (Trait)
    @description: Plays a SoundService sound on Activated. Looks the sound up under
                  SoundService.Generics by name. Clones-and-plays so overlapping clicks
                  don't cut each other off.

                  Construction-time config:
                    - sound_name : string (default "Click")
]=]

local ClickSound = {};
ClickSound.__index = ClickSound;

-- / Services:

local SoundService = game:GetService('SoundService');

-- / Constants:

local DEFAULT_SOUND_NAME = "Click";
local GENERICS = SoundService:FindFirstChild('Generics');

-- / Constructor:

function ClickSound.new(sound_name : string?)

    local self = setmetatable({}, ClickSound);

    self._SoundName = sound_name or DEFAULT_SOUND_NAME;

    return self;
end

-- / Methods:

function ClickSound:_Apply(element)

    local gui = element.Gui;
    if not gui then return end

    if not gui:IsA("GuiButton") then return end

    local sound = GENERICS and GENERICS:FindFirstChild(self._SoundName);
    if not sound then
        warn(`[ClickSound:_Apply] No sound named {self._SoundName} under SoundService.Generics`);
    end

    local conn = gui.Activated:Connect(function()
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

function ClickSound:_Cleanup() end

return ClickSound;
