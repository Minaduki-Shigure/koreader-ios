describe("hardened iOS document boundary", function()
    local Device, DocumentPathPolicy, DocumentRegistry, ffiUtil, filemanagerutil
    local old_home

    setup(function()
        require("commonrequire")
        Device = require("device")
        DocumentPathPolicy = require("document/documentpathpolicy")
        DocumentRegistry = require("document/documentregistry")
        ffiUtil = require("ffi/util")
        filemanagerutil = require("apps/filemanager/filemanagerutil")
    end)

    before_each(function()
        old_home = Device.home_dir
        Device.home_dir = ffiUtil.realpath("spec/front/unit/data")
        stub(Device, "isHardenedOffline")
        Device.isHardenedOffline.returns(true)
    end)

    after_each(function()
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
end)
