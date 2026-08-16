--!nocheck
--!native

--[=[
    @class ElementRegistry
    @description: Central map of [GuiInstance] = Element. Ensures Element.new(gui) is
                  idempotent so tag-applied and code-applied traits both land on the
                  same Element. Listens to Instance.Destroying to auto-clean entries.
]=]

local ElementRegistry = {};

-- / Internal:

local _ElementsByGui = {};
local _DestroyConnections = {};
local _ElementClass = nil;

-- / Functions:

local function _resolveElementClass()
    if _ElementClass then return _ElementClass end
    _ElementClass = require(script.Parent.Element);
    return _ElementClass;
end

--[=[
    @function Get
    @description: Returns the existing Element for a gui, or nil.
]=]

function ElementRegistry.Get(gui : Instance)
    return _ElementsByGui[gui];
end

--[=[
    @function GetOrCreate
    @description: Returns the existing Element for a gui, or constructs a bare one
                  and registers it. Wires Instance.Destroying for auto-cleanup.
]=]

function ElementRegistry.GetOrCreate(gui : Instance)

    if not gui then return nil end
    if _ElementsByGui[gui] then return _ElementsByGui[gui] end

    local Element = _resolveElementClass();
    local element = Element._RawConstruct(gui);

    _ElementsByGui[gui] = element;

    _DestroyConnections[gui] = gui.Destroying:Connect(function()
        ElementRegistry.Remove(gui);
    end);

    return element;

end

--[=[
    @function Remove
    @description: Destroys the element for a gui and clears the registry entry.
]=]

function ElementRegistry.Remove(gui : Instance)

    local element = _ElementsByGui[gui];
    if not element then return end

    _ElementsByGui[gui] = nil;

    if _DestroyConnections[gui] then
        _DestroyConnections[gui]:Disconnect();
        _DestroyConnections[gui] = nil;
    end

    element:Destroy();

end

--[=[
    @function GetAll
    @description: Returns the internal map (read-only intent). For testing/diagnostics.
]=]

function ElementRegistry.GetAll()
    return _ElementsByGui;
end

return ElementRegistry;
