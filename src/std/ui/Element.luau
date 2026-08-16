--!nocheck
--!native

--[=[
    @class Element
    @description: Wrapper around a GuiBase2d (or any Instance — traits enforce their own
                  shape). Composes Trait objects that subscribe to state, attach tweens,
                  play sounds, etc.

                  Element.new(gui) is idempotent — delegates to ElementRegistry, so the
                  same GUI never has two elements. Tag-applied and code-applied traits
                  both land on the same instance.

                  Lifecycle:
                    - Pre-mount: :Use(trait) stages traits without applying.
                    - :Mount() flips a flag and applies all staged traits.
                    - Post-mount: :Use(trait) auto-applies immediately.
                    - :Destroy() cleans every trait's connections and removes the
                      element from the registry.

                  Internal :_AttachTagged / :_DetachTagged are called by TagWatcher and
                  keep tagged traits in a separate bucket so a tag removal can target a
                  specific trait without touching user-supplied ones.
]=]

local Element = {};
Element.__index = Element;

-- / Internal:

local _Registry = nil;

local function _resolveRegistry()
    if _Registry then return _Registry end
    _Registry = require(script.Parent.ElementRegistry);
    return _Registry;
end

-- / Constructor:

--[=[
    @function new
    @description: Idempotent — returns existing element for the gui or constructs one.
]=]

function Element.new(gui : Instance)
    if not gui then
        warn(`[Element:new] Called with nil gui`);
        return nil;
    end

    return _resolveRegistry().GetOrCreate(gui);
end

--[=[
    @function _RawConstruct
    @description: Internal — bypasses the registry. Only ElementRegistry.GetOrCreate
                  should call this.
]=]

function Element._RawConstruct(gui : Instance)

    local self = setmetatable({}, Element);

    self.Gui = gui;
    self._mounted = false;
    self._destroyed = false;
    self._userTraits = {};
    self._taggedTraits = {};
    self._cleanups = {};

    return self;

end

-- / Public Methods:

--[=[
    @method Use
    @description: Adds a trait to the element. Pre-mount: stages it. Post-mount: applies
                  immediately and stores the cleanup token.
]=]

function Element:Use(trait : {})

    if self._destroyed then
        warn(`[Element:Use] Element for {self.Gui and self.Gui.Name or "?"} is destroyed`);
        return self;
    end

    if not trait or type(trait._Apply) ~= "function" then
        warn(`[Element:Use] Trait must implement :_Apply`);
        return self;
    end

    table.insert(self._userTraits, trait);

    if self._mounted then
        self:_ApplyTrait(trait);
    end

    return self;
end

--[=[
    @method Mount
    @description: Flips the mount flag and applies every staged trait. Idempotent —
                  calling :Mount on an already-mounted element is a no-op.
]=]

function Element:Mount()

    if self._destroyed then
        warn(`[Element:Mount] Element for {self.Gui and self.Gui.Name or "?"} is destroyed`);
        return self;
    end

    if self._mounted then return self end
    self._mounted = true;

    for _, trait in self._userTraits do
        self:_ApplyTrait(trait);
    end

    for _, trait in self._taggedTraits do
        self:_ApplyTrait(trait);
    end

    return self;
end

--[=[
    @method IsMounted
]=]

function Element:IsMounted()
    return self._mounted;
end

--[=[
    @method Destroy
    @description: Runs every cleanup token, calls optional :_Cleanup on each trait,
                  removes the element from the registry. Safe to call multiple times.
]=]

function Element:Destroy()

    if self._destroyed then return end
    self._destroyed = true;

    for _, cleanup in self._cleanups do
        local ok, err = pcall(cleanup);
        if not ok then
            warn(`[Element:Destroy] Cleanup failed for {self.Gui and self.Gui.Name or "?"}: {err}`);
        end
    end

    for _, trait in self._userTraits do
        if type(trait._Cleanup) ~= "function" then continue end
        pcall(function() trait:_Cleanup() end);
    end

    for _, trait in self._taggedTraits do
        if type(trait._Cleanup) ~= "function" then continue end
        pcall(function() trait:_Cleanup() end);
    end

    self._cleanups = {};
    self._userTraits = {};
    self._taggedTraits = {};

end

-- / Internal Methods (TagWatcher only):

--[=[
    @method _AttachTagged
    @description: TagWatcher entry point. Adds a trait under a tag-keyed slot. Applies
                  immediately if the element is mounted; stages otherwise.
]=]

function Element:_AttachTagged(tag_name : string, trait : {})

    if self._destroyed then return end
    if self._taggedTraits[tag_name] then return end

    self._taggedTraits[tag_name] = trait;

    if self._mounted then
        self:_ApplyTrait(trait, tag_name);
    end

end

--[=[
    @method _DetachTagged
    @description: TagWatcher entry point. Removes the trait keyed by tag_name. Runs
                  the trait's cleanup token (if it had been applied) and optional
                  :_Cleanup method.
]=]

function Element:_DetachTagged(tag_name : string)

    local trait = self._taggedTraits[tag_name];
    if not trait then return end

    self._taggedTraits[tag_name] = nil;

    local cleanupKey = "tag:" .. tag_name;
    local cleanup = self._cleanups[cleanupKey];

    if cleanup then
        self._cleanups[cleanupKey] = nil;
        local ok, err = pcall(cleanup);
        if not ok then
            warn(`[Element:_DetachTagged] Cleanup failed for tag {tag_name}: {err}`);
        end
    end

    if type(trait._Cleanup) == "function" then
        pcall(function() trait:_Cleanup() end);
    end

end

-- / Internal Methods:

function Element:_ApplyTrait(trait : {}, tag_name : string?)

    local ok, result = pcall(function()
        return trait:_Apply(self);
    end);

    if not ok then
        warn(`[Element:_ApplyTrait] Apply failed for {self.Gui and self.Gui.Name or "?"}: {result}`);
        return;
    end

    if type(result) ~= "function" then return end

    if tag_name then
        self._cleanups["tag:" .. tag_name] = result;
    else
        table.insert(self._cleanups, result);
    end

end

return Element;
