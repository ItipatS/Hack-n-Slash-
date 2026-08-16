--[=[

	@utility SFX
	@description: sound helper for cloning + parenting + playing + cleanup

]=]

-- / Services:

local ReplicatedStorage = game:GetService('ReplicatedStorage');
local Debris = game:GetService('Debris');
local Workspace = game:GetService('Workspace');

-- / Assets:

local SFXAssets = nil;

local function getSFXAssets()
    if not SFXAssets then
        -- guarded: this project has no Assets.SFX folder yet, so Play() just no-ops instead of erroring
        local assets = ReplicatedStorage:FindFirstChild("Assets")
        SFXAssets = assets and assets:FindFirstChild("SFX")
    end
    return SFXAssets
end

-- / Types:

type SoundOptions = {
	volume: number?;
	playback_speed: number?;
	time_position: number?;
	rolloff_max_distance: number?;
	rolloff_min_distance: number?;
}

type LoopHandle = {
	sound: Sound;
	parent: Instance;
}

-- / Utility:

local SFX = {}

function SFX._init(sfxFolderOverride)
    SFXAssets = sfxFolderOverride
end

function SFX._GetTemplate(sound_name : string) : Sound?
	local assets = getSFXAssets();
	if not assets then return nil end -- no SFX folder → no-op
	local SoundTemplate = assets:FindFirstChild(sound_name, true);
	if not SoundTemplate then return nil end
	if not SoundTemplate:IsA('Sound') then return nil end
	return SoundTemplate
end

function SFX._ApplyOptions(sound : Sound, options : SoundOptions?)
	if not options then return end

	if options.volume ~= nil then
		sound.Volume = options.volume;
	end

	if options.playback_speed ~= nil then
		sound.PlaybackSpeed = options.playback_speed;
	end

	if options.time_position ~= nil then
		sound.TimePosition = options.time_position;
	end

	if options.rolloff_max_distance ~= nil then
		sound.RollOffMaxDistance = options.rolloff_max_distance;
	end

	if options.rolloff_min_distance ~= nil then
		sound.RollOffMinDistance = options.rolloff_min_distance;
	end
end

function SFX.Play(sound_name : string, parent : Instance?, options : SoundOptions?) : Sound?
	local SoundTemplate = SFX._GetTemplate(sound_name);
	if not SoundTemplate then return nil end

	local sound = SoundTemplate:Clone();
	sound.Name = sound_name;
	sound.Looped = false;
	SFX._ApplyOptions(sound, options);

	sound.Parent = parent or Workspace;
	sound:Play();

	local fallbackLifetime = 5;
	if sound.TimeLength and sound.TimeLength > 0 then
		fallbackLifetime = math.max(0.1, sound.TimeLength + 0.25);
	end

	Debris:AddItem(sound, fallbackLifetime);

	return sound
end

function SFX.PlayAtPosition(sound_name : string, position : Vector3, options : SoundOptions?) : Sound?
	local SoundTemplate = SFX._GetTemplate(sound_name);
	if not SoundTemplate then return nil end

	local part = Instance.new('Part');
	part.Name = 'SFX';
	part.Anchored = true;
	part.CanCollide = false;
	part.CanQuery = false;
	part.CanTouch = false;
	part.Transparency = 1;
	part.Size = Vector3.new(1, 1, 1);
	part.CFrame = CFrame.new(position);
	part.Parent = Workspace;

	local sound = SoundTemplate:Clone();
	sound.Name = sound_name;
	sound.Looped = false;
	SFX._ApplyOptions(sound, options);
	sound.Parent = part;
	sound:Play();

	local fallbackLifetime = 5;
	if sound.TimeLength and sound.TimeLength > 0 then
		fallbackLifetime = math.max(0.1, sound.TimeLength + 0.25);
	end

	Debris:AddItem(sound, fallbackLifetime);
	Debris:AddItem(part, fallbackLifetime + 0.25);

	return sound
end

function SFX.StartLoop(sound_name : string, parent : Instance?, options : SoundOptions?) : Sound?
	local SoundTemplate = SFX._GetTemplate(sound_name);
	if not SoundTemplate then return nil end

	local sound = SoundTemplate:Clone();
	sound.Name = sound_name;
	sound.Looped = true;
	SFX._ApplyOptions(sound, options);

	sound.Parent = parent or Workspace;
	sound:Play();

	return sound
end

function SFX.StartLoopAtPosition(sound_name : string, position : Vector3, options : SoundOptions?) : LoopHandle?
	local SoundTemplate = SFX._GetTemplate(sound_name);
	if not SoundTemplate then return nil end

	local part = Instance.new('Part');
	part.Name = 'SFX';
	part.Anchored = true;
	part.CanCollide = false;
	part.CanQuery = false;
	part.CanTouch = false;
	part.Transparency = 1;
	part.Size = Vector3.new(1, 1, 1);
	part.CFrame = CFrame.new(position);
	part.Parent = Workspace;

	local sound = SoundTemplate:Clone();
	sound.Name = sound_name;
	sound.Looped = true;
	SFX._ApplyOptions(sound, options);
	sound.Parent = part;
	sound:Play();

	return {
		sound = sound;
		parent = part;
	}
end

function SFX.Stop(sound : Sound?)
	if not sound then return end
	if sound.Parent == nil then return end

	sound:Stop();
	sound:Destroy();
end

function SFX.StopHandle(handle : LoopHandle?)
	if not handle then return end

	if handle.sound then
		SFX.Stop(handle.sound);
	end

	if handle.parent and handle.parent.Parent then
		handle.parent:Destroy();
	end
end

return SFX
