--[=[
    @Module: DataWrapper
    @description: ProfileStore wrapper. Owns the per-player Profile lifecycle
    (start session, reconcile against Template, run migrations, end session)
    and exposes a retry-with-backoff Save path for callers that need
    durability beyond the auto-save / EndSession defaults.

    Persistence flow (CLO-215):
        1. Player joins -> Session.RegisterPlayer -> AttemptLoadData ->
           Profile reconciles missing keys to Template defaults, _ApplyMigrations
           upgrades the loaded shape if its _SchemaVersion is below
           Settings.version, profile.Data is handed to the components.
        2. Components mutate self.data.* in place. ProfileStore's internal
           auto-save loop (~5 min) snapshots Data periodically.
        3. Session.UnregisterPlayer calls EndProfileSession -> profile:EndSession
           which forces a final save and releases the session lock so the
           player can rejoin a different server immediately.
        4. Auto-save cadence required by CLO-215 AC4 (60s during active play)
           is driven by Session.luau invoking SaveProfileWithRetry, which
           wraps profile:Save() in an exponential backoff loop.

    Last-writer-wins on simultaneous saves is a property of ProfileStore's
    UpdateAsync-based commit — every Save (auto or manual) replaces the stored
    blob in full, so the leave-game save always supersedes any in-flight
    auto-save by virtue of being the later one to commit.
]=]

-- / Services:

local ReplicatedStorage = game:GetService('ReplicatedStorage');

-- / Imports:

local Template = require(script.Template);
local Settings = require(script.Settings);
local Logger = require(ReplicatedStorage.Logger);

-- / Constants:

local IDENTIFIER = "DataWrapper";

local SAVE_RETRY_ATTEMPTS = 3;
local SAVE_RETRY_BASE_DELAY = 0.5;
local SAVE_RETRY_BACKOFF_FACTOR = 2;

-- / Validation:

if type(Settings.key) ~= "string" or #Settings.key == 0 then
    error(`[{IDENTIFIER}:Init] Settings.key must be a non-empty string, got {type(Settings.key)}`);
end

if type(Settings.version) ~= "number" then
    error(`[{IDENTIFIER}:Init] Settings.version must be a number, got {type(Settings.version)}`);
end

if type(Template) ~= "table" then
    error(`[{IDENTIFIER}:Init] Template must be a table, got {type(Template)}`);
end

-- / State:

local DataWrapper = {};

local Profiles = {};
local _profileStore = nil;
local Store = nil;

-- / Migrations:

-- Each entry maps from_version -> migrator(data) -> data. The chain runs in
-- ascending order; missing intermediate steps are a hard error so we don't
-- silently skip a migration. V0 had no _SchemaVersion field, so anything
-- without the marker is treated as V0.
local MIGRATIONS = {

    -- V0 (pre-_SchemaVersion) -> V1. Reconcile already seeds missing keys from the Template, so this
    -- only needs to guard the nested tables and stamp the version marker.
    [0] = function(data)
        if type(data.pets) ~= "table" then data.pets = { axolotl = true, fox = true, slime = true } end
        if type(data.squad) ~= "table" then data.squad = { "axolotl" } end
        data._SchemaVersion = 1;
        return data;
    end;

};

-- / Init:

function DataWrapper._init(profileStoreOverride)
    _profileStore = profileStoreOverride or require(game.ReplicatedStorage.Packages.profilestore);
    Store = _profileStore.New(`{Settings.key}_{Settings.version}`, Template);
    if not Store then
        error(`[{IDENTIFIER}:Init] Failed to create ProfileStore`);
    end

    if Settings.mock then
        Store = Store.Mock;
    end
end

DataWrapper._init();

function DataWrapper._getProfiles()
    return Profiles
end

function DataWrapper._reset()
    Profiles = {}
    Store = nil
    _profileStore = nil
end

-- / Private:

function DataWrapper._ApplyMigrations(data)

    if type(data) ~= "table" then
        return data;
    end

    local target = Settings.version;
    local current = type(data._SchemaVersion) == "number" and data._SchemaVersion or 0;

    if current >= target then
        return data;
    end

    while current < target do

        local migrator = MIGRATIONS[current];

        if not migrator then
            Logger.warn(`[{IDENTIFIER}:ApplyMigrations] No migrator registered for V{current} -> V{current + 1}, leaving data at V{current}`);
            break;
        end

        local migrateOk, migrateErr = pcall(function()
            data = migrator(data);
        end)

        if not migrateOk then
            Logger.error(`[{IDENTIFIER}:ApplyMigrations] Migrator V{current} threw: {migrateErr}`);
            break;
        end

        local newVersion = type(data._SchemaVersion) == "number" and data._SchemaVersion or current;

        if newVersion <= current then
            Logger.error(`[{IDENTIFIER}:ApplyMigrations] Migrator V{current} did not advance _SchemaVersion (still {newVersion}), aborting chain`);
            break;
        end

        Logger.info(`[{IDENTIFIER}:ApplyMigrations] Migrated V{current} -> V{newVersion}`);
        current = newVersion;
    end

    return data;
end

-- / Functions:

function DataWrapper.AttemptLoadData(player : Player)

    if not Store then
        DataWrapper._init();
    end

    if not player or not player:IsA("Player") then
        error(`[{IDENTIFIER}:AttemptLoadData] Invalid player argument, got {type(player)}`);
    end

    if Profiles[player.UserId] then
        Logger.warn(`[{IDENTIFIER}:AttemptLoadData] Profile already loaded for {player.Name}, returning existing data`);
        return Profiles[player.UserId].Data;
    end

    local profile = Store:StartSessionAsync(`Player_{player.UserId}`);

    if profile == nil then
        Logger.warn(`[{IDENTIFIER}:AttemptLoadData] Failed to load profile for {player.Name} (UserId: {player.UserId})`);
        return nil;
    end

    Profiles[player.UserId] = profile;

    local addUserIdSuccess, addUserIdError = pcall(function()
        profile:AddUserId(player.UserId);
    end)

    if not addUserIdSuccess then
        Logger.warn(`[{IDENTIFIER}:AttemptLoadData] Failed to add UserId to profile for {player.Name}: {addUserIdError}`);
    end

    local reconcileSuccess, reconcileError = pcall(function()
        profile:Reconcile();
    end)

    if not reconcileSuccess then
        Logger.warn(`[{IDENTIFIER}:AttemptLoadData] Failed to reconcile profile for {player.Name}: {reconcileError}`);
    end

    profile.Data = DataWrapper._ApplyMigrations(profile.Data);

    local loadedVersion = type(profile.Data._SchemaVersion) == "number" and profile.Data._SchemaVersion or 0;
    Logger.info(`[{IDENTIFIER}:AttemptLoadData] Loaded profile for {player.Name} — schema V{loadedVersion}, Tix={profile.Data.tix or 0}, Runs={profile.Data.runs or 0}`);

    profile.OnSessionEnd:Connect(function()
        Profiles[player.UserId] = nil;
    end)

    if player:IsDescendantOf(game.Players) then
        return profile.Data;
    else
        Logger.warn(`[{IDENTIFIER}:AttemptLoadData] Player {player.Name} left before profile could be returned`);
        profile:EndSession();
        return nil;
    end
end

function DataWrapper.EndProfileSession(player : Player)
    if not player or not player:IsA("Player") then
        Logger.warn(`[{IDENTIFIER}:EndProfileSession] Invalid player argument, got {type(player)}`);
        return;
    end

    local profile = Profiles[player.UserId];

    if not profile then
        return;
    end

    local endSuccess, endError = pcall(function()
        profile:EndSession();
    end)

    if not endSuccess then
        Logger.warn(`[{IDENTIFIER}:EndProfileSession] Failed to end session for {player.Name}: {endError}`);
    else
        Logger.info(`[{IDENTIFIER}:EndProfileSession] Final save committed and session released for {player.Name}`);
    end
end

function DataWrapper.GetProfile(player : Player)
    if not player or not player:IsA("Player") then
        Logger.warn(`[{IDENTIFIER}:GetProfile] Invalid player argument, got {type(player)}`);
        return nil;
    end

    return Profiles[player.UserId];
end

function DataWrapper.SaveProfile(player : Player)
    if not player or not player:IsA("Player") then
        Logger.warn(`[{IDENTIFIER}:SaveProfile] Invalid player argument, got {type(player)}`);
        return;
    end

    local profile = Profiles[player.UserId];

    if not profile then
        Logger.warn(`[{IDENTIFIER}:SaveProfile] No profile found for {player.Name} (UserId: {player.UserId})`);
        return;
    end

    local saveSuccess, saveError = pcall(function()
        profile:Save();
    end)

    if not saveSuccess then
        Logger.warn(`[{IDENTIFIER}:SaveProfile] Failed to save profile for {player.Name}: {saveError}`);
    end
end

function DataWrapper.SaveProfileWithRetry(player : Player) : boolean

    if not player or not player:IsA("Player") then
        Logger.warn(`[{IDENTIFIER}:SaveProfileWithRetry] Invalid player argument, got {type(player)}`);
        return false;
    end

    local profile = Profiles[player.UserId];

    if not profile then
        Logger.warn(`[{IDENTIFIER}:SaveProfileWithRetry] No profile found for {player.Name} (UserId: {player.UserId})`);
        return false;
    end

    local activeOk, isActive = pcall(function()
        return profile:IsActive();
    end)

    if activeOk and isActive == false then
        Logger.warn(`[{IDENTIFIER}:SaveProfileWithRetry] Profile inactive for {player.Name}, skipping save`);
        return false;
    end

    local delay = SAVE_RETRY_BASE_DELAY;

    for attempt = 1, SAVE_RETRY_ATTEMPTS do

        local saveSuccess, saveError = pcall(function()
            profile:Save();
        end)

        if saveSuccess then
            if attempt > 1 then
                Logger.info(`[{IDENTIFIER}:SaveProfileWithRetry] Save succeeded for {player.Name} on attempt {attempt}`);
            end
            return true;
        end

        Logger.warn(`[{IDENTIFIER}:SaveProfileWithRetry] Attempt {attempt}/{SAVE_RETRY_ATTEMPTS} failed for {player.Name}: {saveError}`);

        if attempt < SAVE_RETRY_ATTEMPTS then
            task.wait(delay);
            delay = delay * SAVE_RETRY_BACKOFF_FACTOR;
        end
    end

    Logger.error(`[{IDENTIFIER}:SaveProfileWithRetry] All {SAVE_RETRY_ATTEMPTS} attempts failed for {player.Name} — data may be stale until next opportunity`);
    return false;
end

return DataWrapper;
