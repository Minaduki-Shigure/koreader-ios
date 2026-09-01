describe("iOS system appearance controller", function()
    local Controller

    setup(function()
        Controller = dofile(
            "plugins/iossystemappearance.koplugin/iossystemappearancecontroller.lua")
    end)

    local function newFixture(initialState, nightMode)
        local fixture = {
            state = initialState,
            event_type = 0x8001,
            night_mode = nightMode,
            broadcasts = {},
            delegated = {},
            native_start_count = 0,
        }
        fixture.original_handler = function(_, event)
            table.insert(fixture.delegated, event)
            return "delegated"
        end
        fixture.device = {
            input = {
                handleSdlEv = fixture.original_handler,
            },
        }
        fixture.controller = Controller:new{
            native = {
                start = function()
                    fixture.native_start_count = fixture.native_start_count + 1
                    return true
                end,
                eventType = function() return fixture.event_type end,
                current = function() return fixture.state end,
            },
            device = fixture.device,
            event = {
                new = function(_, name, value)
                    return { name = name, value = value }
                end,
            },
            settings = {
                isTrue = function(_, key)
                    assert.equals("night_mode", key)
                    return fixture.night_mode == true
                end,
            },
            ui_manager = {
                broadcastEvent = function(_, event)
                    table.insert(fixture.broadcasts, event)
                    fixture.night_mode = event.value
                end,
            },
        }
        return fixture
    end

    it("applies the initial dark appearance once", function()
        local fixture = newFixture(1, false)

        assert.is_true(fixture.controller:start())
        assert.equals(1, fixture.native_start_count)
        assert.equals(1, #fixture.broadcasts)
        assert.equals("SetNightMode", fixture.broadcasts[1].name)
        assert.is_true(fixture.broadcasts[1].value)

        assert.is_true(fixture.controller:start())
        assert.equals(1, fixture.native_start_count)
        assert.equals(1, #fixture.broadcasts)
    end)

    it("turns off a persisted night mode when the system starts in light mode", function()
        local fixture = newFixture(0, true)

        assert.is_true(fixture.controller:start())
        assert.equals(1, #fixture.broadcasts)
        assert.is_false(fixture.broadcasts[1].value)
    end)

    it("applies each runtime appearance transition without duplicate work", function()
        local fixture = newFixture(0, false)
        assert.is_true(fixture.controller:start())
        assert.equals(0, #fixture.broadcasts)

        fixture.state = 1
        fixture.device.input.handleSdlEv({}, {
            code = fixture.event_type,
            value = { code = 1 },
        })
        assert.equals(1, #fixture.broadcasts)
        assert.is_true(fixture.broadcasts[1].value)

        fixture.device.input.handleSdlEv({}, {
            code = fixture.event_type,
            value = { code = 1 },
        })
        assert.equals(1, #fixture.broadcasts)

        fixture.state = 0
        fixture.device.input.handleSdlEv({}, {
            code = fixture.event_type,
            value = { code = 0 },
        })
        assert.equals(2, #fixture.broadcasts)
        assert.is_false(fixture.broadcasts[2].value)
    end)

    it("reads the latest native state instead of a stale queued payload", function()
        local fixture = newFixture(0, false)
        assert.is_true(fixture.controller:start())

        fixture.state = 1
        fixture.device.input.handleSdlEv({}, {
            code = fixture.event_type,
            value = { code = 0 },
        })
        assert.equals(1, #fixture.broadcasts)
        assert.is_true(fixture.broadcasts[1].value)
    end)

    it("delegates unrelated SDL events to the original handler", function()
        local fixture = newFixture(0, false)
        assert.is_true(fixture.controller:start())
        local event = { code = 1234 }

        assert.equals("delegated", fixture.device.input.handleSdlEv({}, event))
        assert.equals(1, #fixture.delegated)
        assert.equals(event, fixture.delegated[1])
    end)

    it("ignores an unavailable native appearance", function()
        local fixture = newFixture(-1, false)

        assert.is_true(fixture.controller:start())
        assert.equals(0, #fixture.broadcasts)
    end)

    it("fails closed when native event registration fails", function()
        local fixture = newFixture(1, false)
        fixture.event_type = 0

        assert.is_false(fixture.controller:start())
        assert.equals(fixture.original_handler, fixture.device.input.handleSdlEv)
        assert.equals(0, #fixture.broadcasts)
    end)

    it("does not replace the SDL handler when the native bridge cannot start", function()
        local fixture = newFixture(1, false)
        fixture.controller.native.start = function() return false end

        assert.is_false(fixture.controller:start())
        assert.equals(fixture.original_handler, fixture.device.input.handleSdlEv)
        assert.equals(0, #fixture.broadcasts)
    end)
end)
