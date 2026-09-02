describe("SDL touch cancellation", function()
    local Device

    setup(function()
        require("commonrequire")
        Device = require("device/sdl/device")
    end)

    it("resets the complete frontend gesture state", function()
        local input = {
            resetState = spy.new(function() end),
        }

        Device:_handleSDLFingerCanceled(input)

        assert.spy(input.resetState).was_called_with(input)
        assert.spy(input.resetState).was.called(1)
    end)
end)
