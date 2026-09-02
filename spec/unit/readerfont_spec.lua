describe("ReaderFont gesture sizing", function()
    local CreOptions, Device, Notification, ReaderCoptListener, ReaderFont, Screen, UIManager
    local original_device_input
    local scheduled

    setup(function()
        require("commonrequire")
        disable_plugins()
        CreOptions = require("ui/data/creoptions")
        Device = require("device")
        Notification = require("ui/widget/notification")
        ReaderCoptListener = require("apps/reader/modules/readercoptlistener")
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
        stub(G_reader_settings, "readSetting", function(_, key)
            if key == "cre_font" then return "Global Font" end
        end)
        stub(G_reader_settings, "saveSetting")
        stub(UIManager, "scheduleIn", function(_, delay, action)
            table.insert(scheduled, { delay = delay, action = action })
        end)
        stub(UIManager, "unschedule")
    end)

    after_each(function()
        Device.isIOS:revert()
        Device.input = original_device_input
        Notification.notify:revert()
        G_reader_settings.readSetting:revert()
        G_reader_settings.saveSetting:revert()
        UIManager.scheduleIn:revert()
        UIManager.unschedule:revert()
    end)

    local function newReaderFont()
        local document = {
            setCJKWidthScaling = spy.new(function() end),
            setFontSize = spy.new(function() end),
        }
        local font = {
            configurable = { cjk_width_scaling = 100, font_size = 20 },
            font_face = "Noto Sans CJK SC",
            font_family_fonts = {},
            steps = ReaderFont.steps,
            ui = {
                config = { isGlobalStyleEnabled = function() return false end },
                doc_settings = { saveSetting = spy.new(function() end) },
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

    it("does not rerender for a zero font-size delta", function()
        local font, document = newReaderFont()

        font:onChangeSize(0)

        assert.spy(document.setFontSize).was.called(0)
        assert.spy(font.ui.handleEvent).was.called(0)
    end)

    it("applies a preset after ConfigChange updated the shared value", function()
        local font, document = newReaderFont()
        local listener = setmetatable({
            document = { configurable = font.configurable },
            ui = { handleEvent = spy.new(function() end) },
        }, { __index = ReaderCoptListener })

        listener:onConfigChange("font_size", 24)

        font:onSetFontSize(24)

        assert.are.equal(24, font.configurable.font_size)
        assert.spy(document.setFontSize).was_called_with(document, Screen:scaleBySize(24))
        assert.spy(font.ui.handleEvent).was.called(1)
    end)

    it("applies CJK width scaling and requests a reflow", function()
        local font, document = newReaderFont()

        font:onSetCJKWidthScaling(110)

        assert.are.equal(110, font.configurable.cjk_width_scaling)
        assert.spy(document.setCJKWidthScaling).was_called_with(document, 110)
        assert.spy(font.ui.handleEvent).was.called(1)
    end)

    it("shows direct CJK spacing controls for iOS plain text", function()
        local cjk_option
        for _, tab in ipairs(CreOptions) do
            for _, option in ipairs(tab.options) do
                if option.name == "cjk_width_scaling" then
                    cjk_option = option
                    break
                end
            end
        end

        assert.is_not_nil(cjk_option)
        assert.is_true(cjk_option.show_func({}, { is_txt = true }))
        assert.is_false(cjk_option.show_func({}, { is_txt = false }))
        assert.same({ 100, 105, 110 }, cjk_option.values)
        assert.are.equal(100, cjk_option.more_options_param.value_min)
        assert.are.equal(150, cjk_option.more_options_param.value_max)
    end)

    it("saves the font globally without overwriting the document font", function()
        local font = newReaderFont()
        font.ui.config.isGlobalStyleEnabled = function() return true end

        font:onSaveSettings()

        assert.stub(G_reader_settings.saveSetting).was.called(1)
        local global_call = G_reader_settings.saveSetting.calls[1].vals
        assert.are.equal("cre_font", global_call[2])
        assert.are.equal("Noto Sans CJK SC", global_call[3])
        for _, call in ipairs(font.ui.doc_settings.saveSetting.calls) do
            assert.are_not.equal("font_face", call.vals[2])
        end
    end)

    it("prefers the global font only while global style is enabled", function()
        local font = newReaderFont()
        local document_settings = {
            readSetting = function(_, key)
                if key == "font_face" then return "Document Font" end
            end,
        }

        assert.are.equal("Document Font", font:_getFontFace(document_settings))

        font.ui.config.isGlobalStyleEnabled = function() return true end
        assert.are.equal("Global Font", font:_getFontFace(document_settings))
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
