--!nocheck
--!native

--[=[
    @class TraitRegistry
    @description: Maps a CollectionService tag name to a factory function that produces
                  a trait instance for a given gui. Factories typically read attributes
                  off the gui to drive per-instance config (e.g. "HoverScale" attribute
                  for the HoverTween factory).

                  TagWatcher iterates this registry on Initialize and connects
                  CollectionService signals for every registered tag.
]=]

local TraitRegistry = {};

-- / Internal:

local _Factories = {};

-- / Functions:

--[=[
    @function Register
    @description: Associates a tag name with a factory(gui) -> trait.
]=]

function TraitRegistry.Register(tag_name : string, factory : (Instance) -> any)

    if type(tag_name) ~= "string" or #tag_name == 0 then
        warn(`[TraitRegistry:Register] tag_name must be a non-empty string, got {type(tag_name)}`);
        return;
    end

    if type(factory) ~= "function" then
        warn(`[TraitRegistry:Register] factory must be a function for tag {tag_name}`);
        return;
    end

    if _Factories[tag_name] then
        warn(`[TraitRegistry:Register] Overwriting existing factory for tag {tag_name}`);
    end

    _Factories[tag_name] = factory;

end

--[=[
    @function Unregister
    @description: Removes a factory for a tag. Does not affect already-attached traits.
]=]

function TraitRegistry.Unregister(tag_name : string)
    _Factories[tag_name] = nil;
end

--[=[
    @function Get
    @description: Returns the factory for a tag, or nil.
]=]

function TraitRegistry.Get(tag_name : string)
    return _Factories[tag_name];
end

--[=[
    @function GetTags
    @description: Returns an array of all registered tag names.
]=]

function TraitRegistry.GetTags()
    local tags = {};
    for tag in _Factories do
        table.insert(tags, tag);
    end
    return tags;
end

--[=[
    @function Build
    @description: Convenience — looks up the factory for tag_name and calls it with gui.
                  Returns nil if no factory is registered or the factory errors.
]=]

function TraitRegistry.Build(tag_name : string, gui : Instance)

    local factory = _Factories[tag_name];
    if not factory then return nil end

    local ok, result = pcall(factory, gui);

    if not ok then
        warn(`[TraitRegistry:Build] Factory for tag {tag_name} errored: {result}`);
        return nil;
    end

    return result;

end

return TraitRegistry;
