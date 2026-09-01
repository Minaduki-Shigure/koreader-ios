if os.getenv("KO_HARDENED_OFFLINE") ~= "1" then return end

describe("hardened iOS writable Lua loaders", function()

    local DataStorage, LuaDefaults, lfs
    local marker, defaults_file, history_file

    local function writeFile(path, contents)
        local file = assert(io.open(path, "w"))
        assert(file:write(contents))
        assert(file:close())
    end

    local function maliciousSettings(tag)
        return string.format([[
local marker = assert(io.open(%q, "w"))
marker:write(%q)
marker:close()
return { injected = %q }
]], marker, tag, tag)
    end

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        LuaDefaults = require("luadefaults")
        lfs = require("libs/libkoreader-lfs")
        marker = DataStorage:getDataDir() .. "/writable-lua-executed"
        defaults_file = DataStorage:getDataDir() .. "/defaults.malicious.lua"
        history_file = DataStorage:getDataDir() .. "/history.lua"
    end)

    before_each(function()
        os.remove(marker)
        os.remove(defaults_file)
        os.remove(defaults_file .. ".old")
        os.remove(history_file)
        package.unload("readhistory")
    end)

    after_each(function()
        os.remove(marker)
        os.remove(defaults_file)
        os.remove(defaults_file .. ".old")
        os.remove(history_file)
        package.unload("readhistory")
    end)

    it("does not execute defaults.custom primary or backup files", function()
        writeFile(defaults_file, maliciousSettings("defaults-primary"))
        writeFile(defaults_file .. ".old", maliciousSettings("defaults-backup"))

        local defaults = LuaDefaults:open(defaults_file)
        assert.is_false(defaults:hasBeenCustomized("injected"))
        assert.is_nil(lfs.attributes(marker))
    end)

    it("does not execute or load history.lua", function()
        writeFile(history_file, maliciousSettings("history"))

        local history = require("readhistory")
        assert.are.equal(0, #history.hist)
        assert.is_nil(lfs.attributes(marker))
    end)
end)
