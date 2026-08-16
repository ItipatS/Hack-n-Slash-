--!nocheck
--!native

--[=[
    @class OnClick (Trait)
    @description: Wires gui.Activated to a handler. The handler receives the element
                  so it can read state, mutate child guis, etc.

                  Construction-time config:
                    - handler : function(element) -> ()
]=]

local OnClick = {};
OnClick.__index = OnClick;

-- / Constructor:

function OnClick.new(handler : ({}) -> ())

    if type(handler) ~= "function" then
        warn(`[OnClick:new] handler must be a function`);
    end

    local self = setmetatable({}, OnClick);

    self._Handler = handler;

    return self;
end

-- / Methods:

function OnClick:_Apply(element)

    local gui = element.Gui;
    if not gui then return end

    if not gui:IsA("GuiButton") then return end

    local conn = gui.Activated:Connect(function()
        local ok, err = pcall(self._Handler, element);
        if not ok then
            warn(`[OnClick] Handler errored on {gui.Name}: {err}`);
        end
    end);

    return function()
        conn:Disconnect();
    end;

end

function OnClick:_Cleanup() end

return OnClick;
