describe("ReaderGlobalStyle", function()
    local ReaderGlobalStyle

    local function newSettings(data)
        return {
            data = data or {},
            readSetting = function(self, key, default)
                local value = self.data[key]
                if value == nil then return default end
                return value
            end,
            saveSetting = function(self, key, value)
                self.data[key] = value
            end,
            delSetting = function(self, key)
                self.data[key] = nil
            end,
            isTrue = function(self, key)
                return self.data[key] == true
            end,
        }
    end

    setup(function()
        require("commonrequire")
        ReaderGlobalStyle = require("apps/reader/readerglobalstyle")
    end)

    it("keeps global style values while loading document-specific behavior", function()
        local configurable = {
            font_size = 30,
            view_mode = 0,
            word_spacing = { 100, 90 },
        }
        local document_settings = newSettings{
            copt_font_size = 18,
            copt_view_mode = 1,
            copt_word_spacing = { 75, 50 },
        }

        ReaderGlobalStyle:loadDocumentSettings(configurable, document_settings, "copt_")

        assert.are.equal(30, configurable.font_size)
        assert.are.equal(1, configurable.view_mode)
        assert.same({ 100, 90 }, configurable.word_spacing)
    end)

    it("updates global style without overwriting old per-document style", function()
        local configurable = {
            font_size = 32,
            view_mode = 1,
            word_spacing = { 100, 90 },
        }
        local document_settings = newSettings{
            copt_font_size = 18,
            copt_view_mode = 0,
            copt_word_spacing = { 75, 50 },
        }
        local global_settings = newSettings()

        ReaderGlobalStyle:saveSettings(
            configurable, document_settings, "copt_", global_settings)

        assert.are.equal(32, global_settings.data.copt_font_size)
        assert.same({ 100, 90 }, global_settings.data.copt_word_spacing)
        assert.are.equal(18, document_settings.data.copt_font_size)
        assert.same({ 75, 50 }, document_settings.data.copt_word_spacing)
        assert.are.equal(1, document_settings.data.copt_view_mode)

        configurable.word_spacing[1] = 10
        assert.same({ 100, 90 }, global_settings.data.copt_word_spacing)
    end)

    it("detaches table values loaded from global settings", function()
        local global_word_spacing = { 100, 90 }
        local configurable = { word_spacing = global_word_spacing }

        ReaderGlobalStyle:detachCurrentStyle(configurable)
        configurable.word_spacing[1] = 75

        assert.same({ 100, 90 }, global_word_spacing)
        assert.same({ 75, 90 }, configurable.word_spacing)
    end)

    it("limits synchronization to the reviewed style whitelist", function()
        assert.is_true(ReaderGlobalStyle:isStyleKey("font_size"))
        assert.is_true(ReaderGlobalStyle:isStyleKey("cjk_width_scaling"))
        assert.is_true(ReaderGlobalStyle:isStyleKey("h_page_margins"))
        assert.is_false(ReaderGlobalStyle:isStyleKey("block_rendering_mode"))
        assert.is_false(ReaderGlobalStyle:isStyleKey("embedded_css"))
        assert.is_false(ReaderGlobalStyle:isStyleKey("view_mode"))
    end)

    it("uses an explicit opt-in setting", function()
        local settings = newSettings()
        assert.is_false(ReaderGlobalStyle:isEnabled(settings))

        ReaderGlobalStyle:setEnabled(true, settings)
        assert.is_true(ReaderGlobalStyle:isEnabled(settings))

        ReaderGlobalStyle:setEnabled(false, settings)
        assert.is_false(ReaderGlobalStyle:isEnabled(settings))
    end)
end)

describe("ReaderConfig global style routing", function()
    local CreOptions, Device, KoptOptions, ReaderConfig, ReaderGlobalStyle

    setup(function()
        require("commonrequire")
        Device = require("device")
        CreOptions = require("ui/data/creoptions")
        KoptOptions = require("ui/data/koptoptions")
        ReaderConfig = require("apps/reader/modules/readerconfig")
        ReaderGlobalStyle = require("apps/reader/readerglobalstyle")
    end)

    before_each(function()
        stub(Device, "isIOS")
        Device.isIOS.returns(true)
        stub(ReaderGlobalStyle, "isEnabled")
        ReaderGlobalStyle.isEnabled.returns(true)
        stub(ReaderGlobalStyle, "detachCurrentStyle")
        stub(ReaderGlobalStyle, "loadDocumentSettings")
        stub(ReaderGlobalStyle, "saveCurrentStyle")
        stub(ReaderGlobalStyle, "saveSettings")
        stub(ReaderGlobalStyle, "setEnabled")
        stub(G_reader_settings, "flush")
    end)

    after_each(function()
        Device.isIOS:revert()
        ReaderGlobalStyle.isEnabled:revert()
        ReaderGlobalStyle.detachCurrentStyle:revert()
        ReaderGlobalStyle.loadDocumentSettings:revert()
        ReaderGlobalStyle.saveCurrentStyle:revert()
        ReaderGlobalStyle.saveSettings:revert()
        ReaderGlobalStyle.setEnabled:revert()
        G_reader_settings.flush:revert()
    end)

    local function newConfig(options)
        local configurable = {
            loadSettings = spy.new(function() end),
            saveSettings = spy.new(function() end),
        }
        local doc_settings = {
            readSetting = function() return nil end,
            saveSetting = spy.new(function() end),
        }
        local config = setmetatable({
            configurable = configurable,
            last_panel_index = 1,
            options = options,
            ui = {
                doc_settings = doc_settings,
                font = { saveGlobalStyleFont = spy.new(function() end) },
            },
        }, { __index = ReaderConfig })
        return config, configurable, doc_settings
    end

    it("persists the complete style before flushing the enabled state", function()
        local config, configurable = newConfig(CreOptions)
        local font_saved = false
        config.ui.font.saveGlobalStyleFont = spy.new(function()
            font_saved = true
        end)
        G_reader_settings.flush:revert()
        stub(G_reader_settings, "flush", function()
            assert.is_true(font_saved)
        end)

        assert.is_true(config:setGlobalStyleEnabled(true))

        assert.stub(ReaderGlobalStyle.detachCurrentStyle).was_called_with(
            ReaderGlobalStyle, configurable)
        assert.stub(ReaderGlobalStyle.saveCurrentStyle).was_called_with(
            ReaderGlobalStyle, configurable, "copt_")
        assert.spy(config.ui.font.saveGlobalStyleFont).was.called(1)
        assert.stub(ReaderGlobalStyle.setEnabled).was_called_with(
            ReaderGlobalStyle, true)
        assert.stub(G_reader_settings.flush).was.called(1)
    end)

    it("uses global style routing only for iOS reflowable documents", function()
        local config, configurable, doc_settings = newConfig(CreOptions)

        config:onReadSettings(doc_settings)
        config:onSaveSettings()

        assert.stub(ReaderGlobalStyle.loadDocumentSettings).was.called(1)
        assert.stub(ReaderGlobalStyle.saveSettings).was.called(1)
        assert.spy(configurable.loadSettings).was.called(0)
        assert.spy(configurable.saveSettings).was.called(0)

        ReaderGlobalStyle.loadDocumentSettings:clear()
        ReaderGlobalStyle.saveSettings:clear()
        config, configurable, doc_settings = newConfig(KoptOptions)

        config:onReadSettings(doc_settings)
        config:onSaveSettings()

        assert.stub(ReaderGlobalStyle.loadDocumentSettings).was.called(0)
        assert.stub(ReaderGlobalStyle.saveSettings).was.called(0)
        assert.spy(configurable.loadSettings).was.called(1)
        assert.spy(configurable.saveSettings).was.called(1)
    end)
end)
