--!nocheck
--!native

--[=[
    @class TagWatcher
    @description: Bridges CollectionService tags to the Element/Trait system. On
                  Initialize, walks every tag registered in TraitRegistry and connects
                  Added/Removed signals.

                  Added → resolves-or-creates the Element for the gui, builds the trait
                  via the registered factory, and attaches it under the tag-keyed slot.

                  Removed → detaches the trait keyed by that tag from the element.

                  Initialize is idempotent — repeated calls only attach factories for
                  tags that have appeared since the last call.
]=]

local TagWatcher = {};

-- / Services:

local CollectionService = game:GetService('CollectionService');

-- / Imports:

local ElementRegistry = require(script.Parent.ElementRegistry);
local TraitRegistry = require(script.Parent.TraitRegistry);

-- / Internal:

local _WatchedTags = {};
local _Connections = {};

-- / Functions:

local function _attach(tag_name : string, gui : Instance)

    local factory = TraitRegistry.Get(tag_name);
    if not factory then return end

    local element = ElementRegistry.GetOrCreate(gui);
    if not element then return end

    local trait = TraitRegistry.Build(tag_name, gui);
    if not trait then return end

    element:_AttachTagged(tag_name, trait);

    if not element:IsMounted() then
        element:Mount();
    end

end

local function _detach(tag_name : string, gui : Instance)

    local element = ElementRegistry.Get(gui);
    if not element then return end

    element:_DetachTagged(tag_name);

end

local function _watch(tag_name : string)

    if _WatchedTags[tag_name] then return end
    _WatchedTags[tag_name] = true;

    for _, gui in CollectionService:GetTagged(tag_name) do
        _attach(tag_name, gui);
    end

    local addedConn = CollectionService:GetInstanceAddedSignal(tag_name):Connect(function(gui)
        _attach(tag_name, gui);
    end);

    local removedConn = CollectionService:GetInstanceRemovedSignal(tag_name):Connect(function(gui)
        _detach(tag_name, gui);
    end);

    _Connections[tag_name] = { addedConn, removedConn };

end

--[=[
    @function Initialize
    @description: Walks every tag in TraitRegistry and starts watching. Idempotent.
]=]

function TagWatcher.Initialize()
    for _, tag_name in TraitRegistry.GetTags() do
        _watch(tag_name);
    end
end

--[=[
    @function Watch
    @description: Starts watching a single tag. Use this if a controller registers a
                  custom tag after the framework has already initialized.
]=]

function TagWatcher.Watch(tag_name : string)
    _watch(tag_name);
end

--[=[
    @function Stop
    @description: Disconnects all CollectionService listeners. Existing elements keep
                  their already-attached tagged traits.
]=]

function TagWatcher.Stop()

    for tag_name, conns in _Connections do
        for _, conn in conns do
            conn:Disconnect();
        end
        _Connections[tag_name] = nil;
        _WatchedTags[tag_name] = nil;
    end

end

return TagWatcher;
