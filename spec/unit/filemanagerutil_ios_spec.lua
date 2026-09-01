describe("hardened iOS document boundary", function()
    local Device, DocumentPathPolicy, DocumentRegistry, FileSearcher
    local ffiUtil, filemanagerutil, lfs
    local old_home

    setup(function()
        require("commonrequire")
        Device = require("device")
        DocumentPathPolicy = require("document/documentpathpolicy")
        DocumentRegistry = require("document/documentregistry")
        FileSearcher = require("apps/filemanager/filemanagerfilesearcher")
        ffiUtil = require("ffi/util")
        filemanagerutil = require("apps/filemanager/filemanagerutil")
        lfs = require("libs/libkoreader-lfs")
    end)

    before_each(function()
        old_home = Device.home_dir
        Device.home_dir = ffiUtil.realpath("spec/front/unit/data")
        stub(Device, "isHardenedOffline")
        Device.isHardenedOffline.returns(true)
    end)

    after_each(function()
        FileSearcher.search_path = nil
        FileSearcher.search_string = nil
        Device.isHardenedOffline:revert()
        Device.home_dir = old_home
    end)

    it("keeps canonical descendants inside Books", function()
        local file = ffiUtil.realpath("spec/front/unit/data/sample.txt")
        assert.is_true(filemanagerutil.isPathInsideHome(file))
        assert.equals(file, filemanagerutil.constrainToHome(file))
    end)

    it("resets an outside or stale path to Books", function()
        assert.is_false(filemanagerutil.isPathInsideHome("/"))
        assert.equals(Device.home_dir, filemanagerutil.constrainToHome("/"))
        assert.equals(Device.home_dir, filemanagerutil.constrainToHome("/not/a/real/path"))

        FileSearcher.search_path = "/"
        FileSearcher.search_string = "*"
        FileSearcher.include_subfolders = false
        FileSearcher.include_metadata = false
        FileSearcher:getList()
        assert.equals(Device.home_dir, FileSearcher.search_path)
    end)

    it("fails closed when the Books root cannot be canonicalized", function()
        Device.home_dir = "/not/a/real/books/root"
        assert.is_false(filemanagerutil.isPathInsideHome("/"))
        assert.equals(Device.home_dir, filemanagerutil.constrainToHome("/"))
        assert.is_nil(DocumentPathPolicy:resolveDocument("/etc/hosts"))
    end)

    it("rejects direct document registry opens outside Books", function()
        local outside = ffiUtil.realpath("/")
        local sentinel = {}
        DocumentRegistry.registry[outside] = { doc = sentinel, refs = 1 }

        assert.is_nil(DocumentRegistry:openDocument(outside))
        assert.equals(1, DocumentRegistry.registry[outside].refs)

        DocumentRegistry.registry[outside] = nil
    end)

    it("does not allow an internal-document exception outside Books", function()
        local outside = ffiUtil.realpath("frontend/document/documentregistry.lua")
        assert.is_nil(DocumentPathPolicy:resolveDocument(outside))
    end)

    it("only resolves mutable and new paths below Books", function()
        local file = ffiUtil.realpath("spec/front/unit/data/sample.txt")
        local new_file = ffiUtil.joinPath(Device.home_dir, "new-document.txt")
        assert.equals(file, DocumentPathPolicy:resolveMutablePath(file))
        assert.is_nil(DocumentPathPolicy:resolveMutablePath(Device.home_dir))
        assert.equals(new_file, DocumentPathPolicy:resolveWritePath(new_file))
        assert.is_nil(DocumentPathPolicy:resolveWritePath("/tmp/new-document.txt"))
    end)

    it("rejects leaf and intermediate symlinks without redirecting mutation", function()
        local root = os.tmpname()
        os.remove(root)
        assert(lfs.mkdir(root))
        local real_dir = ffiUtil.joinPath(root, "real")
        assert(lfs.mkdir(real_dir))
        local victim = ffiUtil.joinPath(real_dir, "victim.txt")
        local file = assert(io.open(victim, "w"))
        assert(file:write("keep"))
        assert(file:close())
        local file_alias = ffiUtil.joinPath(root, "file-alias.txt")
        local dir_alias = ffiUtil.joinPath(root, "dir-alias")
        assert(lfs.link(victim, file_alias, true))
        assert(lfs.link(real_dir, dir_alias, true))

        Device.home_dir = assert(ffiUtil.realpath(root))
        assert.is_nil(DocumentPathPolicy:resolveDocument(file_alias))
        assert.is_nil(DocumentPathPolicy:resolveMutablePath(file_alias))
        assert.is_nil(DocumentPathPolicy:resolveMutablePath(
            ffiUtil.joinPath(dir_alias, "victim.txt")))
        assert.is_nil(DocumentPathPolicy:resolveWritePath(
            ffiUtil.joinPath(dir_alias, "new.txt")))
        assert.are.equal("file", lfs.attributes(victim, "mode"))

        FileSearcher.search_path = Device.home_dir
        FileSearcher.search_string = "*"
        FileSearcher.include_subfolders = true
        FileSearcher.include_metadata = false
        local dirs, files = FileSearcher:getList()
        for _, entry in ipairs(dirs) do
            assert.are_not.equal(dir_alias, entry[2])
        end
        for _, entry in ipairs(files) do
            assert.are_not.equal(file_alias, entry[2])
        end

        os.remove(file_alias)
        os.remove(dir_alias)
        os.remove(victim)
        os.remove(real_dir)
        os.remove(root)
    end)
end)
