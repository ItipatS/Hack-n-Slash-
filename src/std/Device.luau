--[=[

    @module Device
    @description: Lightweight platform detection. Inspects UserInputService capability flags
    to bucket the local client as PC, Console, Mobile, or Unknown.

]=]

-- / Services:

local UserInputService = game:GetService("UserInputService");

-- / Module:

local Device = {};

local _cached: string? = nil; -- device can't change mid-session; resolve once (no per-call warns)

-- / Public Functions:

function Device.GetDevice() : ("PC" | "Console" | "Mobile" | "Unknown")

	if _cached then return _cached :: any end

	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		_cached = "Mobile";
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled and not UserInputService.MouseEnabled then
		_cached = "Console";
	elseif UserInputService.KeyboardEnabled and UserInputService.MouseEnabled then
		_cached = "PC";
	else
		_cached = "Unknown";
	end

	return _cached :: any;

end

function Device.IsTouchOnly() : boolean

	return Device.GetDevice() == "Mobile";

end

return Device;
