describe("Dispatcher runtime actions", function()
    local Dispatcher
    local settingsList

    setup(function()
        require("commonrequire")
        Dispatcher = require("frontend/dispatcher")
        -- grab private settingsList from upvalue of registerAction
        local i = 1
        while true do
            local name, val = debug.getupvalue(Dispatcher.registerAction, i)
            if not name then break end
            if name == "settingsList" then
                settingsList = val
                break
            end
            i = i + 1
        end
        assert.is_truthy(settingsList)
    end)

    it("should add and remove a custom action", function()
        assert.is_nil(settingsList.custom_test)
        Dispatcher:registerAction("custom_test", {category="none", event="TestEvent"})
        assert.equals("TestEvent", settingsList.custom_test.event)
        -- registering again should not duplicate
        Dispatcher:registerAction("custom_test", {category="none", event="TestEvent"})
        -- remove it
        Dispatcher:removeAction("custom_test")
        assert.is_nil(settingsList.custom_test)
    end)

    it("removeAction on missing name does not error", function()
        assert.is_truthy(Dispatcher:removeAction("nopenopenope"))
    end)

    describe("iOS plain-text pinch safety", function()
        local Device, Notification, ReaderUI, UIManager
        local original_reader_ui
        local sent_events

        before_each(function()
            Device = require("device")
            Notification = require("ui/widget/notification")
            ReaderUI = require("apps/reader/readerui")
            UIManager = require("ui/uimanager")
            original_reader_ui = ReaderUI.instance
            ReaderUI.instance = {
                document = { is_txt = true },
                rolling = {},
                gestures = {},
            }
            sent_events = {}
            stub(Device, "isIOS")
            Device.isIOS.returns(true)
            stub(Notification, "notify")
            stub(UIManager, "sendEvent", function(_, event)
                table.insert(sent_events, event)
            end)
            stub(UIManager, "broadcastEvent")
        end)

        after_each(function()
            Device.isIOS:revert()
            Notification.notify:revert()
            UIManager.sendEvent:revert()
            UIManager.broadcastEvent:revert()
            ReaderUI.instance = original_reader_ui
        end)

        it("blocks fixed-step font actions while preserving other actions", function()
            Dispatcher:execute({
                decrease_font = 4,
                history = true,
                show_menu = true,
                settings = {
                    order = { "decrease_font", "history", "show_menu" },
                },
            }, {
                gesture = { ges = "pinch" },
            })

            assert.equals(2, #sent_events)
            assert.equals("onShowHist", sent_events[1].handler)
            assert.equals("onShowMenu", sent_events[2].handler)
            assert.stub(Notification.notify).was.called(1)
            assert.stub(UIManager.broadcastEvent).was.called(0)
        end)

        it("keeps numeric non-gesture font actions available", function()
            Dispatcher:execute({ increase_font = 2 })

            assert.equals(1, #sent_events)
            assert.equals("onIncreaseFontSize", sent_events[1].handler)
            assert.equals(2, sent_events[1].args[1])
            assert.stub(Notification.notify).was.called(0)
        end)

        it("preserves one-by-one action identity after filtering", function()
            local actions = {
                decrease_font = 4,
                history = true,
                show_menu = true,
                settings = {
                    order = { "decrease_font", "history", "show_menu" },
                    execute_one_by_one = 3,
                },
            }

            Dispatcher:execute(actions, { gesture = { ges = "pinch" } })
            assert.equals(1, #sent_events)
            assert.equals("onShowMenu", sent_events[1].handler)
            assert.equals(2, actions.settings.execute_one_by_one)

            sent_events = {}
            Dispatcher:execute(actions, { gesture = { ges = "pinch" } })
            assert.equals(1, #sent_events)
            assert.equals("onShowHist", sent_events[1].handler)
            assert.equals(3, actions.settings.execute_one_by_one)
            assert.stub(UIManager.broadcastEvent).was.called(0)
        end)

        it("skips a blocked one-by-one action without losing the next safe action", function()
            local actions = {
                decrease_font = 4,
                history = true,
                show_menu = true,
                settings = {
                    order = { "decrease_font", "history", "show_menu" },
                    execute_one_by_one = 1,
                },
            }

            Dispatcher:execute(actions, { gesture = { ges = "pinch" } })
            assert.equals(1, #sent_events)
            assert.equals("onShowHist", sent_events[1].handler)
            assert.equals(3, actions.settings.execute_one_by_one)
            assert.stub(UIManager.broadcastEvent).was.called(0)
        end)

        it("keeps a single remaining one-by-one action isolated", function()
            local actions = {
                decrease_font = 4,
                history = true,
                settings = {
                    order = { "decrease_font", "history" },
                    execute_one_by_one = 1,
                },
            }

            Dispatcher:execute(actions, { gesture = { ges = "pinch" } })
            assert.equals(1, #sent_events)
            assert.equals("onShowHist", sent_events[1].handler)
            assert.equals(2, actions.settings.execute_one_by_one)
            assert.stub(UIManager.broadcastEvent).was.called(0)
        end)

        it("leaves one-by-one state unchanged when every action is blocked", function()
            local actions = {
                decrease_font = 4,
                settings = {
                    order = { "decrease_font" },
                    execute_one_by_one = 1,
                },
            }

            assert.is_true(Dispatcher:execute(actions, { gesture = { ges = "pinch" } }))
            assert.equals(0, #sent_events)
            assert.equals(1, actions.settings.execute_one_by_one)
            assert.stub(UIManager.broadcastEvent).was.called(0)
        end)
    end)
end)
