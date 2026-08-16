--!strict

--[[
    @Module: Common.luau
    @description: Common functions that are used all over the codebase.
]]

-- << CONSTS >> --

local SUFFIXES = {"", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc", "Ud", "Dd"}

-- << FUNCTIONS >> --

local common = {}

-- < SHORT VALUE > --

 -- 1000 -> 1.0K, 125 -> 125
function common.format_to_short_value(number: number): string
	if number < 1000 then
		return tostring(number)
	end

	local exponent = math.floor(math.log10(number) / 3)
	local suffix = SUFFIXES[exponent + 1] or "??"
	local short_number = number / (1000 ^ exponent)

	local formatted = string.format("%.1f", short_number)

	return formatted .. suffix
end

-- 1.0K -> 1000, 125 -> 125
function common.decode_from_short_value(string: string): number
    string = string:gsub("^%s+", ""):gsub("%s+$", "")
    
    local num = tonumber(string)
    if num then
        return num
    end
    
    local suffix_length = 0
    local suffix_index = 0
    for i, suffix in ipairs(SUFFIXES) do
        if string:match(suffix .. "$") and #suffix > suffix_length then
            suffix_length = #suffix
            suffix_index = i
        end
    end
    
    if suffix_index == 0 then
        return 0
    end
    
    local num_str = string:sub(1, -suffix_length - 1)
    local number = tonumber(num_str)
    
    if not number then
        return 0
    end
    
    local multiplier = 1000 ^ (suffix_index - 1)
    
    return number * multiplier
end

-- < LONG VALUE > --

-- 1000 -> 1,000, 125 -> 125
function common.format_to_long_value(number: number): string
	if number < 1000 then
		return tostring(number)
	end
	
	local int_part = math.floor(number)
	local formatted = tostring(int_part):reverse():gsub("(%d%d%d)", "%1,"):reverse()

	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end

	return formatted
end

-- 1,000 -> 1000, 125 -> 125
function common.decode_from_long_value(string: string): number

end

-- < TIME > --

-- 1 -> 1s, 60 -> 1m 0s, 3600 -> 1h 00m
function common.format_to_HHMMSS(number: number): string
	local hours = math.floor(number / 3600)
	local minutes = math.floor((number % 3600) / 60)
	local secs = number % 60

	if hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm %ds", minutes, secs)
	else
		return string.format("%ds", secs)
	end
end

-- 1 -> 00:01, 60 -> 01:00, 3600 -> 01:00:00
function common.format_to_electronic_time(number: number): string
	local hours = math.floor(number / 3600)
	local minutes = math.floor((number % 3600) / 60)
	local secs = number % 60

	if hours > 0 then
		return string.format("%02d:%02d:%02d", hours, minutes, secs)
	else
		return string.format("%02d:%02d", minutes, secs)
	end
end

-- < TABLES > --

function common.deep_copy(original : {})
    local lookup = {}

    local function _copy(value : {})
        if type(value) ~= "table" then
            return value
        elseif lookup[value] then
            return lookup[value]
        end

        local newTable = {}
        lookup[value] = newTable

        for k, v in value do
            newTable[_copy(k)] = _copy(v)
        end

        return newTable
    end

    return _copy(original)
end

function common.total_in_table(t : {})
    local c = 0
    for _, v in t do 
        c += v 
    end
    
    return c
end

function common.get_dictionary_key_index(key : string, dict : {})

    local c = 0

    for k, v in dict do
        c += 1
        if k == key then break end
    end

    return c

end

function common.get_dictionary_length(dict : {})

    local c = 0

    for k, v in dict do c += 1 end

    return c

end

function common.get_t_len(t : {})
    local c = 0
    for k, v in t do
        if v == nil then continue end
        c +=1
    end
    return c
end

-- < OTHER > --

function common.parse_path(b, path : string)

    local i = nil

    for _, v : string in string.split(path, '/') do
        if i == nil then
            i = b
        else
            i = i:FindFirstChild(v)
        end
    end

    return i
end


-- < COLORS > --

function common.color_to_hex(c: Color3): string
    return string.format("%02X%02X%02X",
        math.floor(c.R * 255),
        math.floor(c.G * 255),
        math.floor(c.B * 255)
    )
end

-- < MOVEMENT > --

--[[
    @function get_camera_relative_direction
    @description: Calculates movement direction relative to camera orientation
    @param moveVector: Vector3 - The player's movement input vector
    @param camera: Camera - The current camera object
    @return: string - Direction relative to camera ('Forward', 'Back', 'Left', 'Right', or 'None')
]]
function common.get_camera_relative_direction(moveVector: Vector3, camera): string
    -- Check if player is moving
    if moveVector.Magnitude <= 0.1 then
        return 'None'
    end
    
    -- Get camera's orientation vectors
    local camCF = camera.CFrame
    local camForward = camCF.LookVector
    local camRight = camCF.RightVector
    
    local movement = moveVector.Unit
    
    -- Project movement onto camera orientation
    local relativeX = movement:Dot(camRight)
    local relativeZ = movement:Dot(camForward)
    
    -- Determine primary direction based on stronger component
    if math.abs(relativeX) > math.abs(relativeZ) then
        if relativeX > 0 then
            return 'Right'
        else
            return 'Left'
        end
    else
        if relativeZ > 0 then
            return 'Forward'
        else
            return 'Back'
        end
    end
end

return common