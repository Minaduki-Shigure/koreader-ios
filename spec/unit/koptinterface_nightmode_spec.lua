if os.getenv("KO_IOS") ~= "1" then return end

describe("KoptInterface night-mode document setting", function()
    local Document, KoptInterface, Screen
    local original_night_mode

    setup(function()
        require("commonrequire")
        Document = require("document/document")
        KoptInterface = require("document/koptinterface")
        Screen = require("device").screen
    end)

    before_each(function()
        original_night_mode = Screen.night_mode
        Screen.night_mode = true
        stub(Document, "drawPage")
        stub(Document, "drawPageInverted")
    end)

    after_each(function()
        Screen.night_mode = original_night_mode
        Document.drawPage:revert()
        Document.drawPageInverted:revert()
    end)

    local function newDoc(file, nightmode_document)
        return setmetatable({
            configurable = {
                auto_straighten = 0,
                nightmode_document = nightmode_document,
                page_opt = 0,
                text_wrap = 0,
                white_threshold = 255,
            },
            file = file,
            sw_dithering = false,
        }, { __index = Document })
    end

    it("respects the disabled inversion setting for a standalone PNG", function()
        local target = {}
        local doc = newDoc("standalone.png", 0)
        local rect = { x = 0, y = 0, w = 2, h = 2 }

        KoptInterface:drawPage(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)

        assert.spy(Document.drawPage).was_called_with(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)
        assert.spy(Document.drawPageInverted).was.called(0)
    end)

    it("does not apply image compensation to a PDF whose setting is off", function()
        local target = {}
        local doc = newDoc("document.pdf", 0)
        local rect = { x = 0, y = 0, w = 2, h = 2 }

        KoptInterface:drawPage(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)

        assert.spy(Document.drawPage).was_called_with(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)
        assert.spy(Document.drawPageInverted).was.called(0)
    end)

    it("uses the inverted drawing path for a standalone PNG whose setting is on", function()
        local target = {}
        local doc = newDoc("standalone.png", 1)
        local rect = { x = 0, y = 0, w = 2, h = 2 }

        KoptInterface:drawPage(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)

        assert.spy(Document.drawPage).was.called(0)
        assert.spy(Document.drawPageInverted).was_called_with(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)
    end)

    it("keeps the existing inverted drawing path for PDFs whose setting is on", function()
        local target = {}
        local doc = newDoc("document.pdf", 1)
        local rect = { x = 0, y = 0, w = 2, h = 2 }

        KoptInterface:drawPage(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)

        assert.spy(Document.drawPage).was.called(0)
        assert.spy(Document.drawPageInverted).was_called_with(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)
    end)

    it("does not invert outside night mode even when the setting is on", function()
        Screen.night_mode = false
        local target = {}
        local doc = newDoc("standalone.png", 1)
        local rect = { x = 0, y = 0, w = 2, h = 2 }

        KoptInterface:drawPage(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)

        assert.spy(Document.drawPage).was_called_with(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)
        assert.spy(Document.drawPageInverted).was.called(0)
    end)
end)
