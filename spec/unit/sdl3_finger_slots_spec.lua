describe("SDL finger slot state", function()
    local FingerSlots

    setup(function()
        require("commonrequire")
        FingerSlots = require("ffi/sdl3_finger_slots")
    end)

    it("allocates the lowest free slot and never allocates on pop", function()
        local slots = FingerSlots:new()

        assert.equals(0, slots:getOrCreate(101))
        assert.equals(1, slots:getOrCreate(202))
        assert.equals(0, slots:getOrCreate(101))
        assert.is_nil(slots:pop(303))
        assert.equals(0, slots:pop(101))
        assert.is_nil(slots:pop(101))
        assert.equals(0, slots:getOrCreate(404))
    end)

    it("drops the complete gesture on cancellation", function()
        local slots = FingerSlots:new()
        slots:getOrCreate(101)
        slots:getOrCreate(202)

        slots:reset()

        assert.is_nil(slots:pop(101))
        assert.is_nil(slots:pop(202))
        assert.equals(0, slots:getOrCreate(303))
    end)
end)
