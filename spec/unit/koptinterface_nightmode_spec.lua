if os.getenv("KO_IOS") ~= "1" then return end

describe("KoptInterface night-mode image compensation", function()
    local Blitbuffer, Document, KoptInterface, Screen
    local original_night_mode

    setup(function()
        require("commonrequire")
        Blitbuffer = require("ffi/blitbuffer")
        Document = require("document/document")
        KoptInterface = require("document/koptinterface")
        Screen = require("device").screen
    end)

    before_each(function()
        original_night_mode = Screen.night_mode
        Screen.night_mode = true
        stub(Document, "drawPageInverted")
    end)

    after_each(function()
        Screen.night_mode = original_night_mode
        Document.drawPageInverted:revert()
    end)

    local function newDoc(file, source, nightmode_document)
        return setmetatable({
            configurable = {
                auto_straighten = 0,
                nightmode_document = nightmode_document,
                page_opt = 0,
                text_wrap = 0,
                white_threshold = 255,
            },
            file = file,
            renderPage = function()
                return {
                    bb = source,
                    excerpt = { x = 0, y = 0 },
                }
            end,
            sw_dithering = false,
        }, { __index = Document })
    end

    it("pre-inverts an existing image even when its legacy sidecar says off", function()
        local source = Blitbuffer.new(2, 2, Blitbuffer.TYPE_BB8)
        local target = Blitbuffer.new(2, 2, Blitbuffer.TYPE_BBRGB32)
        source:fill(Blitbuffer.COLOR_BLACK)
        target:fill(Blitbuffer.COLOR_BLACK)
        target:invert()
        local doc = newDoc("standalone.png", source, 0)
        local rect = { x = 0, y = 0, w = 2, h = 2 }

        KoptInterface:drawPage(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)

        local color = target:getPixelP(0, 0)[0]:getColorRGB32()
        assert.same({ 0xFF, 0xFF, 0xFF }, { color.r, color.g, color.b })
        assert.spy(Document.drawPageInverted).was.called(0)
        source:free()
        target:free()
    end)

    it("does not apply image compensation to a PDF whose setting is off", function()
        local source = Blitbuffer.new(2, 2, Blitbuffer.TYPE_BB8)
        local target = Blitbuffer.new(2, 2, Blitbuffer.TYPE_BBRGB32)
        source:fill(Blitbuffer.COLOR_BLACK)
        target:fill(Blitbuffer.COLOR_BLACK)
        target:invert()
        local doc = newDoc("document.pdf", source, 0)
        local rect = { x = 0, y = 0, w = 2, h = 2 }

        KoptInterface:drawPage(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)

        local color = target:getPixelP(0, 0)[0]:getColorRGB32()
        assert.same({ 0x00, 0x00, 0x00 }, { color.r, color.g, color.b })
        assert.spy(Document.drawPageInverted).was.called(0)
        source:free()
        target:free()
    end)

    it("keeps the existing inverted drawing path for PDFs whose setting is on", function()
        local source = Blitbuffer.new(2, 2, Blitbuffer.TYPE_BB8)
        local target = {}
        local doc = newDoc("document.pdf", source, 1)
        local rect = { x = 0, y = 0, w = 2, h = 2 }

        KoptInterface:drawPage(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)

        assert.spy(Document.drawPageInverted).was_called_with(doc, target, 0, 0, rect, 1, 1, 0, 1, 1)
        source:free()
    end)
end)
