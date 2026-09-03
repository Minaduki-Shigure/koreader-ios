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

    it("cancels and drains horizontal motion from the bottom reader edge", function()
        local state = TouchState:new()
        state:setBottomHorizontalSuppressed(true)

        assert.same({ "forward", 0 }, { state:onDown(101, false, 500, 900) })
        assert.same({ "forward", 0 }, {
            state:onMotion(101, 515, 905, 1000, 1000),
        })
        assert.equals("cancel", state:onMotion(101, 525, 905, 1000, 1000))
        assert.is_true(state:isDiscarding())
        assert.equals("consume", state:onMotion(101, 700, 920, 1000, 1000))
        assert.equals("consume", state:onUp(101))
        assert.is_false(state:isDiscarding())

        assert.same({ "forward", 0 }, { state:onDown(202, false, 500, 500) })
        assert.same({ "forward", 0 }, {
            state:onMotion(202, 700, 510, 1000, 1000),
        })
        assert.same({ "forward", 0 }, { state:onUp(202) })
    end)

    it("preserves vertical motion from the bottom reader edge", function()
        local state = TouchState:new()
        state:setBottomHorizontalSuppressed(true)

        assert.same({ "forward", 0 }, { state:onDown(101, false, 500, 900) })
        assert.same({ "forward", 0 }, {
            state:onMotion(101, 510, 820, 1000, 1000),
        })
        assert.same({ "forward", 0 }, {
            state:onMotion(101, 520, 700, 1000, 1000),
        })
        assert.same({ "forward", 0 }, {
            state:onMotion(101, 800, 700, 1000, 1000),
        })
        assert.same({ "forward", 0 }, {
            state:onUp(101, 900, 700, 1000, 1000),
        })
        assert.is_false(state:isDiscarding())
    end)

    it("does not classify jitter or diagonal motion as bottom horizontal", function()
        local classify = TouchState.bottomHorizontalDecision

        assert.equals("pending", classify(500, 900, 519, 900, 1000, 1000))
        assert.equals("cancel", classify(500, 900, 520, 900, 1000, 1000))
        assert.equals("cancel", classify(500, 900, 535, 900, 1000, 1000))
        assert.equals("pending", classify(500, 900, 560, 940, 1000, 1000))
        assert.equals("allow", classify(500, 900, 520, 840, 1000, 1000))
        assert.equals("allow", classify(500, 874, 700, 874, 1000, 1000))
        assert.equals("cancel", classify(500, 875, 700, 875, 1000, 1000))
        assert.equals("pending", classify(1000, 1800, 1019, 1800, 2000, 2000))
        assert.equals("cancel", classify(1000, 1800, 1020, 1800, 2000, 2000))
    end)

    it("keeps watching an ambiguous start that becomes horizontal", function()
        local state = TouchState:new()
        state:setBottomHorizontalSuppressed(true)

        assert.same({ "forward", 0 }, { state:onDown(101, false, 500, 900) })
        assert.same({ "forward", 0 }, {
            state:onMotion(101, 520, 915, 1000, 1000),
        })
        assert.equals("cancel", state:onMotion(101, 700, 930, 1000, 1000))
        assert.equals("consume", state:onUp(101))
    end)

    it("cancels a slow horizontal drag before the frontend pan threshold", function()
        local state = TouchState:new()
        state:setBottomHorizontalSuppressed(true)

        assert.same({ "forward", 0 }, { state:onDown(101, false, 500, 900) })
        assert.same({ "forward", 0 }, {
            state:onMotion(101, 505, 900, 1000, 1000),
        })
        assert.same({ "forward", 0 }, {
            state:onMotion(101, 510, 901, 1000, 1000),
        })
        assert.same({ "forward", 0 }, {
            state:onMotion(101, 515, 901, 1000, 1000),
        })
        assert.equals("cancel", state:onMotion(101, 520, 901, 1000, 1000))
        assert.equals("consume", state:onMotion(101, 525, 901, 1000, 1000))
        assert.equals("consume", state:onUp(101))
    end)

    it("classifies a fast bottom flick from its terminal coordinates", function()
        local state = TouchState:new()
        state:setBottomHorizontalSuppressed(true)

        assert.same({ "forward", 0 }, { state:onDown(101, false, 500, 900) })
        assert.equals("cancel", state:onUp(101, 700, 905, 1000, 1000))
        assert.equals(0, state:getActiveCount())
        assert.is_false(state:isDiscarding())

        assert.same({ "forward", 0 }, { state:onDown(202, false, 500, 900) })
        assert.same({ "forward", 0 }, {
            state:onMotion(202, 515, 905, 1000, 1000),
        })
        assert.equals("cancel", state:onUp(202, 700, 905, 1000, 1000))
        assert.equals(0, state:getActiveCount())
        assert.is_false(state:isDiscarding())
    end)

    it("allows an unresolved diagonal sequence at release", function()
        local state = TouchState:new()
        state:setBottomHorizontalSuppressed(true)

        assert.same({ "forward", 0 }, { state:onDown(101, false, 500, 900) })
        assert.same({ "forward", 0 }, {
            state:onMotion(101, 560, 940, 1000, 1000),
        })
        assert.same({ "forward", 0 }, {
            state:onUp(101, 620, 980, 1000, 1000),
        })
    end)

    it("recovers after a bottom horizontal sequence has no terminal event", function()
        local state = TouchState:new()
        state:setBottomHorizontalSuppressed(true)

        state:onDown(101, false, 500, 900)
        assert.equals("cancel", state:onMotion(101, 700, 900, 1000, 1000))
        assert.is_true(state:isDiscarding())

        assert.same({ "forward", 0 }, { state:onDown(202, false, 500, 500) })
        assert.same({ "forward", 0 }, {
            state:onMotion(202, 700, 500, 1000, 1000),
        })
        assert.same({ "forward", 0 }, { state:onUp(202) })
        assert.is_true(state:isDiscarding())
        assert.equals("consume", state:onUp(101))
        assert.is_false(state:isDiscarding())
    end)

    it("keeps bottom horizontal motion when suppression is disabled", function()
        local state = TouchState:new()

        assert.same({ "forward", 0 }, { state:onDown(101, false, 500, 900) })
        assert.same({ "forward", 0 }, {
            state:onMotion(101, 700, 900, 1000, 1000),
        })
        assert.same({ "forward", 0 }, { state:onUp(101) })
    end)

    it("restores bottom horizontal motion after suppression is disabled", function()
        local state = TouchState:new()
        state:setBottomHorizontalSuppressed(true)
        state:setBottomHorizontalSuppressed(false)

        assert.same({ "forward", 0 }, { state:onDown(101, false, 500, 900) })
        assert.same({ "forward", 0 }, {
            state:onMotion(101, 700, 900, 1000, 1000),
        })
        assert.same({ "forward", 0 }, { state:onUp(101) })
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
