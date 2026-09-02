describe("SDL touch cancellation", function()
    local Device, UIManager
    local fake_ui_manager

    setup(function()
        require("commonrequire")
        Device = require("device/sdl/device")
        UIManager = require("ui/uimanager")
    end)

    before_each(function()
        fake_ui_manager = {
            broadcastEvent = spy.new(function() end),
            currently_scrolling = true,
        }
        Device:UIManagerReady(fake_ui_manager)
    end)

    after_each(function()
        Device:UIManagerReady(UIManager)
    end)

    it("cleans up an in-progress pan before resetting gesture state", function()
        local input = {
            resetState = spy.new(function() end),
        }

        Device:_handleSDLFingerCanceled(input)

        assert.spy(fake_ui_manager.broadcastEvent).was.called(1)
        local event = fake_ui_manager.broadcastEvent.calls[1].vals[2]
        assert.equals("onHandledAsSwipe", event.handler)
        assert.is_false(fake_ui_manager.currently_scrolling)
        assert.spy(input.resetState).was_called_with(input)
        assert.spy(input.resetState).was.called(1)
    end)
end)
