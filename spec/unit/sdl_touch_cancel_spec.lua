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

describe("SDL bottom horizontal suppression scope", function()
    local Input, UIManager
    local fake_ui_manager, input, owner, stack
    local applied

    setup(function()
        require("commonrequire")
        Input = require("device/input")
        UIManager = require("ui/uimanager")
    end)

    before_each(function()
        applied = {}
        owner = {}
        stack = { owner }
        fake_ui_manager = {
            topdown_widgets_iter = function()
                local index = 0
                return function()
                    index = index + 1
                    return stack[index]
                end
            end,
        }
        Input:UIManagerReady(fake_ui_manager)
        input = setmetatable({
            input = {
                setBottomHorizontalSuppressed = function(suppressed)
                    table.insert(applied, suppressed)
                end,
            },
        }, { __index = Input })
    end)

    after_each(function()
        Input:UIManagerReady(UIManager)
    end)

    it("applies only while the requesting reader owns input", function()
        input:setBottomHorizontalSuppressed(true, owner)
        assert.same({ true }, applied)

        stack = { { toast = true }, owner }
        input:_syncBottomHorizontalSuppression()
        assert.same({ true }, applied)

        stack = { {}, owner }
        input:_syncBottomHorizontalSuppression()
        assert.same({ true, false }, applied)

        stack = { owner }
        input:_syncBottomHorizontalSuppression()
        assert.same({ true, false, true }, applied)

        input:setBottomHorizontalSuppressed(false)
        assert.same({ true, false, true, false }, applied)
        assert.is_nil(input._bottom_horizontal_suppression_owner)
    end)
end)
