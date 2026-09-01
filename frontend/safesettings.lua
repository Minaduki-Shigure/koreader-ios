-- Loads writable Lua settings as bounded, plain data.
--
-- KOReader's settings format is a Lua table literal. In the hardened iOS
-- build those files must not inherit globals or act as executable patches.

local lfs = require("libs/libkoreader-lfs")

local SafeSettings = {}

local DEFAULT_MAX_FILE_BYTES = 8 * 1024 * 1024
local DEFAULT_MAX_INSTRUCTIONS = 1000000
local DEFAULT_MAX_DEPTH = 64
local DEFAULT_MAX_NODES = 200000
local DEFAULT_MAX_STRING_BYTES = 8 * 1024 * 1024
local HOOK_INTERVAL = 1000

local function option(options, name, default)
    if options and options[name] ~= nil then
        return options[name]
    end
    return default
end

local function checkFile(path, options)
    local attributes = lfs.symlinkattributes(path)
    if not attributes or attributes.mode ~= "file" then
        return false, "settings path is not a regular file"
    end
    local max_file_bytes = option(options, "max_file_bytes", DEFAULT_MAX_FILE_BYTES)
    if attributes.size and attributes.size > max_file_bytes then
        return false, "settings file exceeds size limit"
    end
    return true
end

local function runChunk(chunk, options)
    local jit_control = rawget(_G, "jit")
    if jit_control and type(jit_control.off) == "function" then
        local disabled = pcall(jit_control.off, chunk, true)
        if not disabled then
            return false, "failed to disable JIT for settings data"
        end
    end

    local max_instructions = option(options, "max_instructions", DEFAULT_MAX_INSTRUCTIONS)
    local instructions = 0
    local old_hook, old_mask, old_count = debug.gethook()
    local function instructionHook()
        instructions = instructions + HOOK_INTERVAL
        if instructions > max_instructions then
            error("settings instruction limit exceeded", 0)
        end
    end

    debug.sethook(instructionHook, "", HOOK_INTERVAL)
    local ok, result = pcall(chunk)
    if old_hook then
        debug.sethook(old_hook, old_mask, old_count)
    else
        debug.sethook()
    end
    return ok, result
end

function SafeSettings.validatePlainData(data, options)
    local max_depth = option(options, "max_depth", DEFAULT_MAX_DEPTH)
    local max_nodes = option(options, "max_nodes", DEFAULT_MAX_NODES)
    local max_string_bytes = option(options, "max_string_bytes", DEFAULT_MAX_STRING_BYTES)
    local seen = {}
    local nodes = 0
    local string_bytes = 0

    local function validate(value, depth, is_key)
        nodes = nodes + 1
        if nodes > max_nodes then
            return false, "settings node limit exceeded"
        end

        local value_type = type(value)
        if value_type == "string" then
            string_bytes = string_bytes + #value
            if string_bytes > max_string_bytes then
                return false, "settings string data exceeds size limit"
            end
            return true
        elseif value_type == "number" then
            if value ~= value or value == math.huge or value == -math.huge then
                return false, "settings contain a non-finite number"
            end
            return true
        elseif value_type == "boolean" or value_type == "nil" then
            return true
        elseif value_type ~= "table" then
            return false, "settings contain forbidden type: " .. value_type
        elseif is_key then
            return false, "settings contain a table key"
        end

        if depth > max_depth then
            return false, "settings nesting limit exceeded"
        end
        if getmetatable(value) ~= nil then
            return false, "settings table has a metatable"
        end
        if seen[value] then
            return false, "settings contain a cycle or shared table reference"
        end
        seen[value] = true

        for key, child in pairs(value) do
            local ok, err = validate(key, depth + 1, true)
            if not ok then return false, err end
            ok, err = validate(child, depth + 1, false)
            if not ok then return false, err end
        end
        return true
    end

    return validate(data, 1, false)
end

function SafeSettings.runFile(path, environment, options)
    local ok, err = checkFile(path, options)
    if not ok then return false, err end

    local chunk
    chunk, err = loadfile(path, "t", environment or {})
    if not chunk then return false, err end
    return runChunk(chunk, options)
end

function SafeSettings.loadTable(path, options)
    local ok, data = SafeSettings.runFile(path, {}, options)
    if not ok then return false, data end
    if type(data) ~= "table" then
        return false, "settings file did not return a table"
    end
    local valid, err = SafeSettings.validatePlainData(data, options)
    if not valid then return false, err end
    return true, data
end

return SafeSettings
