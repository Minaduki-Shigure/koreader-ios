describe("PicDocument iOS night mode", function()
    local Document, PicDocument

    setup(function()
        require("commonrequire")
        Document = require("document/document")
        PicDocument = require("document/picdocument")
    end)

    before_each(function()
        stub(os, "getenv")
        os.getenv.returns("1")
        stub(Document, "drawPage")
    end)

    after_each(function()
        os.getenv:revert()
        Document.drawPage:revert()
    end)

    it("pre-inverts images on an inverse iOS framebuffer", function()
        local rect = { w = 10, h = 20 }
        local target = {
            getInverse = function() return 1 end,
            invertRect = spy.new(function() end),
        }

        PicDocument:drawPage(target, 2, 3, rect, 1, 1, 0, 1, 1)

        assert.spy(Document.drawPage).was_called_with(PicDocument, target, 2, 3, rect, 1, 1, 0, 1, 1)
        assert.spy(target.invertRect).was_called_with(target, 2, 3, 10, 20)
    end)

    it("keeps normal rendering outside iOS night mode", function()
        local target = { getInverse = function() return 0 end }
        PicDocument:drawPage(target, 0, 0, {}, 1, 1, 0, 1, 1)
        assert.spy(Document.drawPage).was.called(1)

        Document.drawPage:clear()
        os.getenv.returns(nil)
        target.getInverse = function() return 1 end
        PicDocument:drawPage(target, 0, 0, {}, 1, 1, 0, 1, 1)
        assert.spy(Document.drawPage).was.called(1)
    end)
end)
