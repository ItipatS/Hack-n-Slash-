-- Logger — minimal leveled logger at ReplicatedStorage.Logger.
-- The imported Framework (Data/ProfileStore wrapper) requires this module, and the studio
-- convention is `Logger.*` over raw print/warn. Levels: debug (gated by Config.Debug.LOG_DEBUG),
-- info/warn/error always through. Each takes one already-formatted string.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- config is optional (Logger may load before std is synced in some contexts) — degrade gracefully
local LOG_DEBUG = false
do
    local stdFolder = ReplicatedStorage:FindFirstChild("std")
    local configMod = stdFolder and stdFolder:FindFirstChild("config")
    if configMod then
        local ok, Config = pcall(require, configMod)
        if ok and Config and Config.Debug then LOG_DEBUG = Config.Debug.LOG_DEBUG == true end
    end
end

local Logger = {}

function Logger.debug(message: string)
    if LOG_DEBUG then print("[DEBUG]", message) end
end

function Logger.info(message: string)
    print("[INFO]", message)
end

function Logger.warn(message: string)
    warn("[WARN]", message)
end

function Logger.error(message: string)
    warn("[ERROR]", message)
end

return Logger
