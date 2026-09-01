describe("safe settings loader", function()
    local SafeSettings
    local paths = {}

    local function writeFile(contents)
        local path = os.tmpname()
        local file = assert(io.open(path, "w"))
        assert(file:write(contents))
        assert(file:close())
        table.insert(paths, path)
        return path
    end

    setup(function()
        require("commonrequire")
        SafeSettings = require("safesettings")
    end)

    teardown(function()
        for _, path in ipairs(paths) do
            os.remove(path)
        end
        paths = {}
    end)

    it("loads a plain table without globals", function()
        local ok, data = SafeSettings.loadTable(writeFile([[return { answer = 42, nested = { true, "text" } }]]))
        assert.is_true(ok)
        assert.are.equal(42, data.answer)
        assert.are.same({ true, "text" }, data.nested)
    end)

    it("rejects global access and executable values", function()
        local ok = SafeSettings.loadTable(writeFile([[return { value = os.time() }]]))
        assert.is_false(ok)

        ok = SafeSettings.loadTable(writeFile([[return { callback = function() return true end }]]))
        assert.is_false(ok)
    end)

    it("enforces file, instruction, and nesting limits", function()
        local ok = SafeSettings.loadTable(writeFile([[return {}]]), { max_file_bytes = 4 })
        assert.is_false(ok)

        ok = SafeSettings.loadTable(writeFile([[while true do end]]), { max_instructions = 2000 })
        assert.is_false(ok)

        ok = SafeSettings.loadTable(writeFile([[return { { { { true } } } }]]), { max_depth = 3 })
        assert.is_false(ok)
    end)

    it("rejects cycles, shared tables, and metatables", function()
        local cyclic = {}
        cyclic.self = cyclic
        local ok = SafeSettings.validatePlainData(cyclic)
        assert.is_false(ok)

        local shared = {}
        ok = SafeSettings.validatePlainData({ shared, shared })
        assert.is_false(ok)

        ok = SafeSettings.validatePlainData(setmetatable({}, {}))
        assert.is_false(ok)
    end)
end)
