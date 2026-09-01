--[[--
Strict copy-in document import for iOS.

The native bridge never exposes a provider path to Lua. A successful poll
returns only the final path below KO_BOOKS_HOME.

@module koplugin.iOSImporter
--]]--

if os.getenv("KO_IOS") ~= "1"
        or os.getenv("KO_HARDENED_OFFLINE") ~= "1" then
    return { disabled = true }
end

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")
local T = ffiUtil.template

if not pcall(ffi.typeof, "ko_import_state_t") then
    ffi.cdef[[
    typedef enum {
        KO_IMPORT_IDLE = 0,
        KO_IMPORT_PENDING = 1,
        KO_IMPORT_DONE_OK = 2,
        KO_IMPORT_DONE_CANCEL = 3,
        KO_IMPORT_DONE_ERROR = 4,
    } ko_import_state_t;

    bool ko_ios_import_document_start(void);
    ko_import_state_t ko_ios_import_document_poll(
        char *out_path, size_t path_capacity,
        char *out_error, size_t error_capacity);
    ]]
end

local C = ffi.C
local PATH_CAPACITY = 4096
local ERROR_CAPACITY = 512

local IOSImporter = WidgetContainer:extend{
    name = "iosimporter",
    is_doc_only = false,
}

function IOSImporter:init()
    self.ui.menu:registerToMainMenu(self)
end

function IOSImporter:addToMainMenu(menu_items)
    menu_items.ios_import_document = {
        text = _("Import document…"),
        sorting_hint = "more_tools",
        callback = function()
            self:startImport()
        end,
    }
end

function IOSImporter:startImport()
    if not C.ko_ios_import_document_start() then
        UIManager:show(InfoMessage:new{
            text = _("A document import is already in progress."),
        })
        return
    end

    local out_path = ffi.new("char[?]", PATH_CAPACITY)
    local out_error = ffi.new("char[?]", ERROR_CAPACITY)

    local function poll()
        local state = C.ko_ios_import_document_poll(
            out_path, PATH_CAPACITY, out_error, ERROR_CAPACITY)
        if state == C.KO_IMPORT_PENDING then
            UIManager:scheduleIn(0.2, poll)
        elseif state == C.KO_IMPORT_DONE_OK then
            self:onImportSucceeded(ffi.string(out_path))
        elseif state == C.KO_IMPORT_DONE_CANCEL then
            UIManager:show(InfoMessage:new{ text = _("Import cancelled.") })
        elseif state == C.KO_IMPORT_DONE_ERROR then
            local message = ffi.string(out_error)
            logger.warn("iosimporter:", message)
            UIManager:show(InfoMessage:new{
                text = T(_("Import failed: %1"), message),
            })
        else
            logger.warn("iosimporter: native bridge returned an unexpected state", state)
            UIManager:show(InfoMessage:new{ text = _("Import failed.") })
        end
    end

    UIManager:scheduleIn(0.2, poll)
end

function IOSImporter:onImportSucceeded(path)
    local books_home = os.getenv("KO_BOOKS_HOME")
    local real_path = ffiUtil.realpath(path)
    local real_home = books_home and ffiUtil.realpath(books_home)
    if not real_path or not real_home
            or (real_path ~= real_home
                and real_path:sub(1, #real_home + 1) ~= real_home .. "/") then
        logger.err("iosimporter: native bridge returned a path outside Books")
        UIManager:show(InfoMessage:new{ text = _("Import failed.") })
        return
    end

    if self.ui.file_chooser then
        self.ui.file_chooser:changeToPath(ffiUtil.dirname(real_path), real_path)
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Imported %1."), real_path:match("([^/]+)$") or real_path),
        ok_text = _("Open"),
        ok_callback = function()
            local FileManager = require("apps/filemanager/filemanager")
            FileManager.openFile(self.ui, real_path)
        end,
    })
end

return IOSImporter
