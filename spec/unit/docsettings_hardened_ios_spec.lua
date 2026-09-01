if os.getenv("KO_HARDENED_OFFLINE") ~= "1" or os.getenv("KO_IOS") ~= "1"
        or os.getenv("KO_BOOKS_HOME") == nil then return end

describe("DocSettings hardened iOS boundary", function()

    local DataStorage, Device, DocSettings, ffiutil, lfs, sha256, util
    local test_dir, book, marker, metadata_symlink
    local old_metadata_location

    local function writeFile(path, contents)
        local parent = path:match("^(.*)/[^/]+$")
        if parent then util.makePath(parent) end
        local file = assert(io.open(path, "w"))
        assert(file:write(contents))
        assert(file:close())
    end

    local function maliciousSettings(tag)
        return string.format([[
local marker = assert(io.open(%q, "w"))
marker:write(%q)
marker:close()
return { injected = %q }
]], marker, tag, tag)
    end

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        Device = require("device")
        DocSettings = require("docsettings")
        ffiutil = require("ffi/util")
        lfs = require("libs/libkoreader-lfs")
        sha256 = require("ffi/sha2").sha256
        util = require("util")

        test_dir = Device.home_dir .. "/docsettings-boundary-spec"
        book = test_dir .. "/book.pdf"
        marker = test_dir .. "/executed"
        old_metadata_location = G_reader_settings:readSetting("document_metadata_folder")
    end)

    before_each(function()
        metadata_symlink = nil
        ffiutil.purgeDir(test_dir)
        writeFile(book, "not a real PDF")
        G_reader_settings:saveSetting("document_metadata_folder", "doc")
    end)

    after_each(function()
        local settings = DocSettings:open(book)
        settings:purge()
        if metadata_symlink then
            os.remove(metadata_symlink)
            os.remove(ffiutil.dirname(metadata_symlink))
        end
        ffiutil.purgeDir(test_dir)
        if old_metadata_location == nil then
            G_reader_settings:delSetting("document_metadata_folder")
        else
            G_reader_settings:saveSetting("document_metadata_folder", old_metadata_location)
        end
    end)

    it("ignores executable adjacent and legacy sidecars without migrating them", function()
        local adjacent_dir = test_dir .. "/book.sdr"
        local sidecars = {
            adjacent_dir .. "/metadata.pdf.lua",
            adjacent_dir .. "/book.pdf.lua",
            book .. ".kpdfview.lua",
            DocSettings:getHistoryPath(book),
        }
        for i, path in ipairs(sidecars) do
            writeFile(path, maliciousSettings("sidecar-" .. i))
        end

        local settings = DocSettings:open(book)
        assert.is_nil(settings:readSetting("injected"))
        assert.is_nil(lfs.attributes(marker))

        settings:saveSetting("trusted", "private")
        local written_dir = assert(settings:flush())
        local hash_root = DataStorage:getDocSettingsHashDir()
        assert.are.equal(hash_root .. "/", written_dir:sub(1, #hash_root + 1))

        local reopened = DocSettings:open(book)
        assert.are.equal("private", reopened:readSetting("trusted"))
        assert.is_nil(reopened:readSetting("injected"))
        assert.is_nil(lfs.attributes(marker))
        for _, path in ipairs(sidecars) do
            assert.are.equal("file", lfs.attributes(path, "mode"))
            os.remove(path)
        end
    end)

    it("loads private metadata as bounded data instead of executing it", function()
        local hash_dir = DocSettings:getSidecarDir(book, "hash")
        local hash_file = hash_dir .. "/" .. DocSettings.getSidecarFilename(book)
        writeFile(hash_file, maliciousSettings("private"))

        local settings = DocSettings:open(book)
        assert.is_nil(settings:readSetting("injected"))
        assert.is_nil(lfs.attributes(marker))
        assert.is_nil(lfs.attributes(hash_file))
    end)

    it("does not follow hash metadata directory symlinks outside private storage", function()
        local hash_dir = DocSettings:getSidecarDir(book, "hash")
        local external_dir = test_dir .. "/external-metadata"
        local external_file = external_dir .. "/" .. DocSettings.getSidecarFilename(book)
        util.makePath(ffiutil.dirname(hash_dir))
        writeFile(external_file, "return { external = true }\n")
        assert(lfs.link(external_dir, hash_dir, true))
        metadata_symlink = hash_dir

        local settings = DocSettings:open(book)
        assert.is_nil(settings:readSetting("external"))
        assert.are.equal("file", lfs.attributes(external_file, "mode"))

        settings.candidates = { { path = hash_dir .. "/" .. DocSettings.getSidecarFilename(book) } }
        settings:purge()
        assert.are.equal("file", lfs.attributes(external_file, "mode"))
    end)

    it("keys metadata by canonical Books-relative path, independent of contents", function()
        local canonical_book = assert(ffiutil.realpath(book))
        local books_root = assert(ffiutil.realpath(Device.home_dir))
        local relative_path = canonical_book:sub(#books_root + 2)
        local hsh = sha256(relative_path)
        local expected = string.format("%s/%s/%s.sdr",
            DataStorage:getDocSettingsHashDir(), hsh:sub(1, 2), hsh)

        local before = DocSettings:getSidecarDir(book, "hash")
        writeFile(book, "changed document contents")
        local after = DocSettings:getSidecarDir(book, "hash")

        assert.are.equal(expected, before)
        assert.are.equal(before, after)
    end)

    it("disables custom cover storage", function()
        local settings = DocSettings:open(book)
        assert.is_nil(settings:findCustomCoverFile())
        assert.is_false(settings:getCustomCoverFile())
        assert.is_false(settings:flushCustomCover(book, book))
    end)

    it("writes custom metadata only into private hash storage", function()
        local settings = DocSettings.openSettingsFile()
        settings:saveSetting("custom_props", { title = "Private" })
        assert.is_true(settings:flushCustomMetadata(book))

        local custom_file = assert(settings:findCustomMetadataFile(book))
        local hash_root = DataStorage:getDocSettingsHashDir()
        assert.are.equal(hash_root .. "/", custom_file:sub(1, #hash_root + 1))
    end)

end)
