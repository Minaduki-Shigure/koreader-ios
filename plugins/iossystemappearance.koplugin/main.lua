-- Follow the effective iOS light/dark appearance without polling.

if os.getenv("KO_IOS") ~= "1"
        or os.getenv("KO_HARDENED_OFFLINE") ~= "1" then
    return { disabled = true }
end

local Device = require("device")
local Event = require("ui/event")
local IOSSystemAppearanceController = require("iossystemappearancecontroller")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local logger = require("logger")

if not pcall(ffi.typeof, "ko_ios_system_appearance_state_t") then
    ffi.cdef[[
    typedef enum {
        KO_IOS_SYSTEM_APPEARANCE_UNAVAILABLE = -1,
        KO_IOS_SYSTEM_APPEARANCE_LIGHT = 0,
        KO_IOS_SYSTEM_APPEARANCE_DARK = 1,
    } ko_ios_system_appearance_state_t;

    bool ko_ios_system_appearance_start(void);
    uint32_t ko_ios_system_appearance_event_type(void);
    int32_t ko_ios_system_appearance_current(void);
    ]]
end

local C = ffi.C
local controller

local IOSSystemAppearance = WidgetContainer:extend{
    name = "iossystemappearance",
    is_doc_only = false,
}

function IOSSystemAppearance:init()
    if not controller then
        controller = IOSSystemAppearanceController:new{
            native = {
                start = function()
                    return C.ko_ios_system_appearance_start()
                end,
                eventType = function()
                    return C.ko_ios_system_appearance_event_type()
                end,
                current = function()
                    return C.ko_ios_system_appearance_current()
                end,
            },
            device = Device,
            event = Event,
            logger = logger,
            settings = G_reader_settings,
            ui_manager = UIManager,
        }
    end
    if controller:start() then
        -- Plugin instances are created before their FileManager/ReaderUI is
        -- placed on UIManager's window stack. Repeat the idempotent initial
        -- sync on the first loop tick so SetNightMode always has a listener.
        UIManager:nextTick(function()
            controller:syncCurrentAppearance()
        end)
    end
end

return IOSSystemAppearance
