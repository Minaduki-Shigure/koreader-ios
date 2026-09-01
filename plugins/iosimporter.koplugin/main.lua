--[[--
Strict copy-in document and folder import for iOS.

The native bridge never exposes a provider path to Lua. A successful poll
returns only the final file or collection path below KO_BOOKS_HOME, plus
bounded import and skip counts.

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
local lfs = require("libs/libkoreader-lfs")
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

    typedef enum {
        KO_IMPORT_SELECT_FILES = 0,
        KO_IMPORT_SELECT_FOLDERS = 1,
    } ko_import_selection_mode_t;

    bool ko_ios_import_document_start(ko_import_selection_mode_t selection_mode);
    ko_import_state_t ko_ios_import_document_poll(
        char *out_path, size_t path_capacity,
        char *out_error, size_t error_capacity,
        uint32_t *out_imported_count,
        uint32_t *out_skipped_count,
        int *out_is_collection);
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
    menu_items.ios_import_files = {
        text = _("Import files…"),
        sorting_hint = "more_tools",
        callback = function()
            self:startImport(C.KO_IMPORT_SELECT_FILES)
        end,
    }
    menu_items.ios_import_folder = {
        text = _("Import folder…"),
        sorting_hint = "more_tools",
        callback = function()
            self:startImport(C.KO_IMPORT_SELECT_FOLDERS)
        end,
    }
end

function IOSImporter:startImport(selection_mode)
    if not C.ko_ios_import_document_start(selection_mode) then
        UIManager:show(InfoMessage:new{
            text = _("A document import is already in progress."),
        })
        return
    end

    local out_path = ffi.new("char[?]", PATH_CAPACITY)
    local out_error = ffi.new("char[?]", ERROR_CAPACITY)
    local out_imported_count = ffi.new("uint32_t[1]")
    local out_skipped_count = ffi.new("uint32_t[1]")
    local out_is_collection = ffi.new("int[1]")

    local function poll()
        local state = C.ko_ios_import_document_poll(
            out_path, PATH_CAPACITY, out_error, ERROR_CAPACITY,
            out_imported_count, out_skipped_count, out_is_collection)
        if state == C.KO_IMPORT_PENDING then
            UIManager:scheduleIn(0.2, poll)
        elseif state == C.KO_IMPORT_DONE_OK then
            self:onImportSucceeded(
                ffi.string(out_path),
                tonumber(out_imported_count[0]),
                tonumber(out_skipped_count[0]),
                out_is_collection[0] ~= 0)
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

function IOSImporter:getCurrentUI()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then return FileManager.instance end
    return require("apps/reader/readerui").instance
end

function IOSImporter:showImportedFolder(path)
    local ui = self:getCurrentUI()
    if ui and ui.file_chooser then
        ui.file_chooser:changeToPath(path)
    elseif ui and ui.showFileManager then
        -- ReaderUI treats a non-trailing path component as a focused file.
        ui:onClose()
        ui:showFileManager(path .. "/")
    else
        local FileManager = require("apps/filemanager/filemanager")
        FileManager:showFiles(path)
    end
end

function IOSImporter:onImportSucceeded(path, imported_count, skipped_count, is_collection)
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

    if not imported_count or imported_count < 1 then
        logger.err("iosimporter: native bridge returned an invalid import count")
        UIManager:show(InfoMessage:new{ text = _("Import failed.") })
        return
    end

    local imported_mode = lfs.attributes(real_path, "mode")
    if (is_collection and imported_mode ~= "directory")
            or (not is_collection and imported_mode ~= "file") then
        logger.err("iosimporter: native bridge returned an invalid result type")
        UIManager:show(InfoMessage:new{ text = _("Import failed.") })
        return
    end

    if is_collection then
        local destination = real_path:match("([^/]+)$") or real_path
        local message = T(
            _("Imported documents: %1\nDestination: %2"),
            imported_count,
            destination)
        if skipped_count and skipped_count > 0 then
            message = message .. "\n" .. T(
                _("Skipped unsupported or unsafe items: %1"),
                skipped_count)
        end
        UIManager:show(ConfirmBox:new{
            text = message,
            ok_text = _("Browse"),
            ok_callback = function()
                self:showImportedFolder(real_path)
            end,
        })
        return
    end

    local current_ui = self:getCurrentUI()
    if current_ui and current_ui.file_chooser then
        current_ui.file_chooser:changeToPath(ffiUtil.dirname(real_path), real_path)
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Imported %1."), real_path:match("([^/]+)$") or real_path),
        ok_text = _("Open"),
        ok_callback = function()
            local FileManager = require("apps/filemanager/filemanager")
            local ui = self:getCurrentUI()
            if ui then
                FileManager.openFile(ui, real_path)
            else
                require("apps/reader/readerui"):showReader(real_path)
            end
        end,
    })
end

return IOSImporter
