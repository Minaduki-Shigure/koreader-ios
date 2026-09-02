describe("ReaderFont gesture sizing", function()
    local Device, Notification, ReaderFont, Screen, UIManager
    local original_device_input
    local scheduled

    setup(function()
        require("commonrequire")
        disable_plugins()
        Device = require("device")
        Notification = require("ui/widget/notification")
        ReaderFont = require("apps/reader/modules/readerfont")
        Screen = Device.screen
        UIManager = require("ui/uimanager")
    end)

    before_each(function()
        scheduled = {}
        stub(Device, "isIOS")
        Device.isIOS.returns(true)
        original_device_input = Device.input
        Device.input = { gesture_detector = { contact_count = 0 } }
        stub(Notification, "notify")
        stub(UIManager, "scheduleIn", function(_, delay, action)
            table.insert(scheduled, { delay = delay, action = action })
        end)
        stub(UIManager, "unschedule")
    end)

    after_each(function()
        Device.isIOS:revert()
        Device.input = original_device_input
        Notification.notify:revert()
        UIManager.scheduleIn:revert()
        UIManager.unschedule:revert()
    end)

    local function newReaderFont()
        local document = {
            setFontSize = spy.new(function() end),
        }
        local font = {
            configurable = { font_size = 20 },
            steps = ReaderFont.steps,
            ui = {
                document = document,
                handleEvent = spy.new(function() end),
            },
        }
        return setmetatable(font, { __index = ReaderFont }), document
    end

    it("rejects invalid gesture distances and clamps valid large steps", function()
        local font = newReaderFont()
        local nan = 0 / 0

        assert.are.equal(0, font:gesToFontSize({ distance = 0 }))
        assert.are.equal(0, font:gesToFontSize({ distance = -1 }))
        assert.are.equal(0, font:gesToFontSize({ distance = nan }))
        assert.are.equal(0, font:gesToFontSize({ distance = math.huge }))
        assert.are.equal(0, font:gesToFontSize({ distance = "invalid" }))
        assert.are.equal(5, font:gesToFontSize({
            direction = "horizontal",
            distance = Screen:getWidth() * 2,
        }))
    end)

    it("does not rerender when the computed font size is unchanged", function()
        local font, document = newReaderFont()

        font:onChangeSize(0)
        font:onSetFontSize(20)

        assert.spy(document.setFontSize).was.called(0)
        assert.spy(font.ui.handleEvent).was.called(0)
    end)

    it("defers and coalesces iOS gesture changes until input can drain", function()
        local font = newReaderFont()
        font.onChangeSize = spy.new(function() end)
        local gesture = {
            direction = "horizontal",
            distance = Screen:getWidth() * 2,
        }

        font:onIncreaseFontSize(gesture)
        font:onIncreaseFontSize(gesture)

        assert.are.equal(20, font.configurable.font_size)
        assert.are.equal(2, #scheduled)
        assert.are.equal(0.05, scheduled[2].delay)
        assert.stub(UIManager.unschedule).was.called(2)

        scheduled[2].action()
        assert.spy(font.onChangeSize).was_called_with(font, 10)
    end)

    it("waits for every iOS touch to end before reflowing", function()
        local font = newReaderFont()
        font.onChangeSize = spy.new(function() end)
        Device.input.gesture_detector.contact_count = 1

        font:onIncreaseFontSize({
            direction = "horizontal",
            distance = Screen:getWidth() * 2,
        })
        scheduled[1].action()

        assert.spy(font.onChangeSize).was.called(0)
        assert.are.equal(2, #scheduled)

        Device.input.gesture_detector.contact_count = 0
        scheduled[2].action()
        assert.spy(font.onChangeSize).was_called_with(font, 5)
    end)

    it("drops a gesture if an iOS touch remains stuck", function()
        local font = newReaderFont()
        font.onChangeSize = spy.new(function() end)
        Device.input.gesture_detector.contact_count = 1

        font:onIncreaseFontSize({
            direction = "horizontal",
            distance = Screen:getWidth() * 2,
        })
        for index = 1, 40 do
            scheduled[index].action()
        end

        assert.is_nil(font._pending_gesture_font_delta)
        assert.is_nil(font._gesture_font_retry_count)
        assert.spy(font.onChangeSize).was.called(0)
        assert.are.equal(40, #scheduled)
    end)

    it("cancels a pending gesture change when the document closes", function()
        local font = newReaderFont()
        font.onChangeSize = spy.new(function() end)

        font:onDecreaseFontSize({
            direction = "vertical",
            distance = Screen:getHeight() * 2,
        })
        local pending_action = scheduled[1].action
        font:onCloseDocument()
        pending_action()

        assert.is_nil(font._pending_gesture_font_delta)
        assert.spy(font.onChangeSize).was.called(0)
        assert.stub(UIManager.unschedule).was.called(2)
    end)

    it("keeps non-iOS and numeric font changes synchronous", function()
        local font = newReaderFont()
        font.onChangeSize = spy.new(function() end)

        font:onIncreaseFontSize(2)
        assert.spy(font.onChangeSize).was_called_with(font, 2)
        assert.are.equal(0, #scheduled)

        font.onChangeSize:clear()
        Device.isIOS.returns(false)
        font:onIncreaseFontSize({
            direction = "horizontal",
            distance = Screen:getWidth() * 2,
        })

        assert.spy(font.onChangeSize).was_called_with(font, 5)
        assert.are.equal(0, #scheduled)
    end)
end)
