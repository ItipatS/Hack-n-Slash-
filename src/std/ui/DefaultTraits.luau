--!nocheck
--!native

--[=[
    @module DefaultTraits
    @description: Bootstrap. Registers framework-shipped tag names with TraitRegistry.
                  Must be required before TagWatcher.Initialize so the watcher sees the
                  default tags.

                  Tag factories may read attributes off the gui for per-instance config.
                  Attribute names are documented next to each registration.

                  Controllers register their own domain-specific tags by calling
                  TraitRegistry.Register directly.
]=]

local DefaultTraits = {};

-- / Imports:

local TraitRegistry = require(script.Parent.TraitRegistry);

local HoverTween = require(script.Parent.Traits.HoverTween);
local ClickTween = require(script.Parent.Traits.ClickTween);
local ClickSound = require(script.Parent.Traits.ClickSound);
local HoverSound = require(script.Parent.Traits.HoverSound);

-- / Internal:

local _registered = false;

-- / Functions:

--[=[
    @function Register
    @description: Registers all framework default tags. Idempotent.
]=]

function DefaultTraits.Register()

    if _registered then return end
    _registered = true;

    TraitRegistry.Register("HoverTween", function(gui : Instance)
        local scale = gui:GetAttribute("HoverScale");
        local duration = gui:GetAttribute("HoverDuration");
        return HoverTween.new(scale, duration);
    end);

    TraitRegistry.Register("ClickTween", function(gui : Instance)
        local scale = gui:GetAttribute("ClickScale");
        local duration = gui:GetAttribute("ClickDuration");
        return ClickTween.new(scale, duration);
    end);

    TraitRegistry.Register("ClickSound", function(gui : Instance)
        local soundName = gui:GetAttribute("SoundName");
        return ClickSound.new(soundName);
    end);

    TraitRegistry.Register("HoverSound", function(gui : Instance)
        local soundName = gui:GetAttribute("HoverSoundName");
        return HoverSound.new(soundName);
    end);

end

return DefaultTraits;
