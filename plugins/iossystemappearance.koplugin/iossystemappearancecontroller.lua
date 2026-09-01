-- Event-driven synchronization between an iOS appearance bridge and KOReader.
-- Dependencies are injected so the state machine can be tested without UIKit.

local IOSSystemAppearanceController = {}
IOSSystemAppearanceController.__index = IOSSystemAppearanceController

function IOSSystemAppearanceController:new(options)
    assert(options and options.native, "missing native appearance bridge")
    assert(options.device and options.device.input, "missing device input")
    assert(options.event, "missing Event module")
    assert(options.settings, "missing reader settings")
    assert(options.ui_manager, "missing UIManager")
    return setmetatable({
        native = options.native,
        device = options.device,
        event = options.event,
        logger = options.logger,
        settings = options.settings,
        ui_manager = options.ui_manager,
        started = false,
    }, self)
end

function IOSSystemAppearanceController:_warn(...)
    if self.logger and self.logger.warn then
        self.logger.warn(...)
    end
end

function IOSSystemAppearanceController:syncCurrentAppearance()
    local state = tonumber(self.native.current())
    if state ~= 0 and state ~= 1 then
        self:_warn("iossystemappearance: native bridge returned an invalid state", state)
        return false
    end

    local nightMode = state == 1
    if self.settings:isTrue("night_mode") == nightMode then
        return false
    end

    self.ui_manager:broadcastEvent(self.event:new("SetNightMode", nightMode))
    return true
end

function IOSSystemAppearanceController:start()
    if self.started then
        self:syncCurrentAppearance()
        return true
    end
    if not self.native.start() then
        self:_warn("iossystemappearance: failed to start native appearance bridge")
        return false
    end

    local eventType = tonumber(self.native.eventType())
    if not eventType or eventType <= 0 then
        self:_warn("iossystemappearance: native bridge returned an invalid event type")
        return false
    end

    local originalHandler = self.device.input.handleSdlEv
    if type(originalHandler) ~= "function" then
        self:_warn("iossystemappearance: SDL input handler is unavailable")
        return false
    end

    self.event_type = eventType
    self.original_handler = originalHandler
    local controller = self
    self.device.input.handleSdlEv = function(deviceInput, event)
        if event and tonumber(event.code) == controller.event_type then
            -- Read the latest atomic state rather than trusting a possibly
            -- stale queued event when the system changes appearance rapidly.
            controller:syncCurrentAppearance()
            return
        end
        return originalHandler(deviceInput, event)
    end
    self.started = true
    self:syncCurrentAppearance()
    return true
end

return IOSSystemAppearanceController
