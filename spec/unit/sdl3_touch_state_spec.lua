describe("SDL3 touch sequence state", function()
    local TouchState

    setup(function()
        require("commonrequire")
        TouchState = require("ffi/sdl3_touch_state")
    end)

    it("forwards normal single and multitouch contacts with stable slots", function()
        local state = TouchState:new()

        assert.same({ "forward", 0 }, { state:onDown(101) })
        assert.same({ "forward", 1 }, { state:onDown(202) })
        assert.same({ "forward", 0 }, { state:onMotion(101) })
        assert.same({ "forward", 1 }, { state:onMotion(202) })
        assert.same({ "forward", 0 }, { state:onUp(101) })
        assert.same({ "forward", 1 }, { state:onUp(202) })
        assert.equals(0, state:getActiveCount())
    end)

    it("cancels and drains a suppressed multitouch sequence", function()
        local state = TouchState:new()
        state:setMultitouchSuppressed(true)

        assert.same({ "forward", 0 }, { state:onDown(101) })
        assert.equals("cancel", state:onDown(202))
        assert.is_true(state:isDiscarding())
        assert.equals(0, state:getActiveCount())

        for _ = 1, 200 do
            assert.equals("consume", state:onMotion(101))
            assert.equals("consume", state:onMotion(202))
        end
        assert.equals("consume", state:onUp(101))
        assert.equals("consume", state:onUp(202))
        assert.is_false(state:isDiscarding())

        assert.same({ "forward", 0 }, { state:onDown(303) })
        assert.same({ "forward", 0 }, { state:onUp(303) })
    end)

    it("keeps a missing terminal event from blocking unrelated input", function()
        local state = TouchState:new()
        state:setMultitouchSuppressed(true)

        assert.same({ "forward", 0 }, { state:onDown(101) })
        assert.equals("cancel", state:onDown(202))
        assert.equals("consume", state:onUp(101))
        assert.is_true(state:isDiscarding())

        assert.same({ "forward", 0 }, { state:onDown(303) })
        assert.is_true(state:isDiscarding())
        assert.equals("consume", state:onMotion(202))
        assert.same({ "forward", 0 }, { state:onMotion(303) })
        assert.same({ "forward", 0 }, { state:onUp(303) })
        assert.is_true(state:isDiscarding())

        assert.same({ "forward", 0 }, { state:onDown(404) })
        assert.same({ "forward", 0 }, { state:onUp(404) })
        assert.equals("consume", state:onUp(202))
        assert.is_false(state:isDiscarding())
    end)

    it("quarantines old contacts while forwarding one new contact", function()
        local state = TouchState:new()
        state:setMultitouchSuppressed(true)

        assert.same({ "forward", 0 }, { state:onDown(101) })
        assert.equals("cancel", state:onDown(202))
        assert.same({ "forward", 0 }, { state:onDown(303) })
        assert.equals("consume", state:onMotion(101))
        assert.equals("consume", state:onMotion(202))
        assert.same({ "forward", 0 }, { state:onMotion(303) })
        assert.equals("cancel", state:onDown(404))
        assert.equals(0, state:getActiveCount())
        assert.equals("consume", state:onMotion(303))
        assert.equals("consume", state:onMotion(404))
        assert.equals("consume", state:onUp(303))
        assert.equals("consume", state:onUp(404))
        assert.equals("consume", state:onUp(101))
        assert.equals("consume", state:onUp(202))
        assert.is_false(state:isDiscarding())
    end)

    it("drains canceled contacts without creating phantom slots", function()
        local state = TouchState:new()

        assert.same({ "forward", 0 }, { state:onDown(101) })
        assert.same({ "forward", 1 }, { state:onDown(202) })
        assert.equals("cancel", state:onCancel(101))
        assert.is_true(state:isDiscarding())
        assert.equals("consume", state:onMotion(999))
        assert.equals("consume", state:onUp(999))
        assert.equals("consume", state:onCancel(202))
        assert.is_false(state:isDiscarding())

        assert.same({ "forward", 0 }, { state:onDown(303) })
        assert.same({ "forward", 0 }, { state:onUp(303) })
    end)

    it("ignores duplicate and out-of-order events without allocating", function()
        local state = TouchState:new()

        assert.equals("consume", state:onMotion(101))
        assert.equals("consume", state:onUp(101))
        assert.equals("consume", state:onCancel(101))
        assert.equals(0, state:getActiveCount())

        assert.same({ "forward", 0 }, { state:onDown(202) })
        assert.equals("consume", state:onCancel(999))
        assert.same({ "forward", 0 }, { state:onMotion(202) })
        assert.equals("consume", state:onDown(202))
        assert.same({ "forward", 0 }, { state:onUp(202) })
        assert.equals(0, state:getActiveCount())
    end)

    it("rejects contacts that start outside the iOS safe area", function()
        local state = TouchState:new()
        local outside = TouchState.isOutsideSafeArea
        local window_w, window_h = 1179, 2556
        local left, top, right, bottom = 0, 177, 0, 102

        assert.is_false(outside(0, 0, window_w, window_h, 0, 0, 0, 0))
        assert.is_false(outside(window_w - 1, window_h - 1,
            window_w, window_h, 0, 0, 0, 0))
        assert.is_false(outside(window_w, window_h,
            window_w, window_h, 0, 0, 0, 0))
        assert.is_true(outside(500, top - 1, window_w, window_h,
            left, top, right, bottom))
        assert.is_false(outside(0, top, window_w, window_h,
            left, top, right, bottom))
        assert.is_false(outside(window_w - 1, window_h - bottom - 1,
            window_w, window_h, left, top, right, bottom))
        assert.is_true(outside(500, window_h - bottom, window_w, window_h,
            left, top, right, bottom))

        left, top, right, bottom = 132, 0, 132, 63
        assert.is_true(outside(left - 1, 500, window_w, window_h,
            left, top, right, bottom))
        assert.is_false(outside(left, 500, window_w, window_h,
            left, top, right, bottom))
        assert.is_false(outside(window_w - right - 1, 500, window_w, window_h,
            left, top, right, bottom))
        assert.is_true(outside(window_w - right, 500, window_w, window_h,
            left, top, right, bottom))

        assert.equals("consume", state:onDown(101, true))
        assert.equals("consume", state:onMotion(101))
        assert.equals("consume", state:onUp(101))
        assert.equals(0, state:getActiveCount())
        assert.same({ "forward", 0 }, { state:onDown(202) })
        assert.same({ "forward", 0 }, { state:onUp(202) })
    end)

    it("keeps a valid contact active while an ignored contact is canceled", function()
        local state = TouchState:new()

        assert.same({ "forward", 0 }, { state:onDown(101) })
        assert.equals("consume", state:onDown(202, true))
        assert.equals("consume", state:onMotion(202))
        assert.equals("consume", state:onCancel(202))
        assert.same({ "forward", 0 }, { state:onMotion(101) })
        assert.same({ "forward", 0 }, { state:onUp(101) })
    end)

    it("does not release quarantined contacts for an ignored down", function()
        local state = TouchState:new()
        state:setMultitouchSuppressed(true)

        state:onDown(101)
        state:onDown(202)
        assert.is_true(state:isDiscarding())
        assert.equals("consume", state:onDown(101, true))
        assert.is_true(state:isDiscarding())
        assert.equals("consume", state:onUp(101))
        assert.equals("consume", state:onUp(202))
        assert.is_false(state:isDiscarding())
    end)

    it("queues one cancellation when the suppression mode changes mid-touch", function()
        local state = TouchState:new()
        state:onDown(101)

        state:setMultitouchSuppressed(true)

        assert.is_true(state:takePendingCancel())
        assert.is_false(state:takePendingCancel())
        assert.is_true(state:isDiscarding())
        assert.equals("consume", state:onMotion(101))
        state:setMultitouchSuppressed(false)
        assert.is_false(state:takePendingCancel())
        assert.equals("consume", state:onUp(101))
        assert.is_false(state:isDiscarding())
        assert.same({ "forward", 0 }, { state:onDown(202) })
        assert.same({ "forward", 0 }, { state:onUp(202) })
    end)

    it("clears incomplete sequences on a lifecycle reset", function()
        local state = TouchState:new()
        state:setMultitouchSuppressed(true)
        state:onDown(101)
        state:onDown(202)
        state:onUp(101)
        assert.is_true(state:isDiscarding())

        assert.is_true(state:resetContacts())
        assert.is_false(state:isDiscarding())
        assert.is_false(state:resetContacts())
        assert.equals("consume", state:onMotion(101))
        assert.equals("consume", state:onUp(202))
        assert.same({ "forward", 0 }, { state:onDown(303) })
        assert.same({ "forward", 0 }, { state:onUp(303) })
    end)
end)
