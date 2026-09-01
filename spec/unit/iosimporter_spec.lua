if os.getenv("KO_HARDENED_OFFLINE") ~= "1" or os.getenv("KO_IOS") ~= "1"
        or os.getenv("KO_BOOKS_HOME") == nil then return end

describe("iOS importer result handling", function()
    local FileManager, IOSImporter, ReaderUI, UIManager, ffiUtil, lfs
    local importer, original_file_manager, original_reader_ui
    local shown, test_dir

    local function writeFile(path)
        local file = assert(io.open(path, "w"))
        assert(file:write("fixture"))
        assert(file:close())
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        FileManager = require("apps/filemanager/filemanager")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        ffiUtil = require("ffi/util")
        lfs = require("libs/libkoreader-lfs")
        IOSImporter = dofile("plugins/iosimporter.koplugin/main.lua")
    end)

    before_each(function()
        original_file_manager = FileManager.instance
        original_reader_ui = ReaderUI.instance
        FileManager.instance = nil
        ReaderUI.instance = nil
        shown = {}
        stub(UIManager, "show", function(_, widget)
            table.insert(shown, widget)
        end)
        stub(FileManager, "openFile")

        test_dir = ffiUtil.joinPath(os.getenv("KO_BOOKS_HOME"),
                                    "iosimporter-result-spec")
        ffiUtil.purgeDir(test_dir)
        assert(lfs.mkdir(test_dir))
        importer = setmetatable({}, { __index = IOSImporter })
    end)

    after_each(function()
        FileManager.openFile:revert()
        UIManager.show:revert()
        FileManager.instance = original_file_manager
        ReaderUI.instance = original_reader_ui
        ffiUtil.purgeDir(test_dir)
    end)

    it("rejects a native result outside private Books", function()
        importer:onImportSucceeded("/", 1, 0, true)

        assert.are.equal(1, #shown)
        assert.matches("Import failed", shown[1].text)
    end)

    it("validates the result count and file-or-collection type", function()
        local collection = ffiUtil.joinPath(test_dir, "Collection")
        assert(lfs.mkdir(collection))

        importer:onImportSucceeded(collection, 0, 0, true)
        importer:onImportSucceeded(collection, 1, 0, false)

        assert.are.equal(2, #shown)
        assert.matches("Import failed", shown[1].text)
        assert.matches("Import failed", shown[2].text)
    end)

    it("reports a collection and browses it in the current file manager", function()
        local collection = ffiUtil.joinPath(test_dir, "Collection")
        assert(lfs.mkdir(collection))
        local changeToPath = spy.new(function() end)
        FileManager.instance = {
            file_chooser = { changeToPath = changeToPath },
        }

        importer:onImportSucceeded(collection, 3, 2, true)

        assert.are.equal(1, #shown)
        assert.matches("3", shown[1].text)
        assert.matches("2", shown[1].text)
        shown[1].ok_callback()
        assert.spy(changeToPath).was_called_with(FileManager.instance.file_chooser,
                                                 collection)
    end)

    it("closes the current reader before opening an imported folder", function()
        local collection = ffiUtil.joinPath(test_dir, "Collection")
        assert(lfs.mkdir(collection))
        local closeReader = spy.new(function() end)
        local showFileManager = spy.new(function() end)
        ReaderUI.instance = {
            onClose = closeReader,
            showFileManager = showFileManager,
        }

        importer:showImportedFolder(collection)

        assert.spy(closeReader).was.called(1)
        assert.spy(showFileManager).was_called_with(ReaderUI.instance,
                                                    collection .. "/")
    end)

    it("uses the active UI when opening a file after a long import", function()
        local book = ffiUtil.joinPath(test_dir, "book.txt")
        writeFile(book)
        local initiatingUI = {
            file_chooser = { changeToPath = spy.new(function() end) },
        }
        FileManager.instance = initiatingUI

        importer:onImportSucceeded(book, 1, 0, false)
        assert.are.equal(1, #shown)

        local replacementUI = {}
        FileManager.instance = replacementUI
        shown[1].ok_callback()
        assert.stub(FileManager.openFile).was_called_with(replacementUI, book)
    end)
end)
