local util = require("util")

local ReaderGlobalStyle = {
    setting_name = "ios_global_reading_style",
}

local style_keys = {
    b_page_margin = true,
    cjk_width_scaling = true,
    font_base_weight = true,
    font_gamma = true,
    font_hinting = true,
    font_kerning = true,
    font_size = true,
    h_page_margins = true,
    line_spacing = true,
    status_line = true,
    sync_t_b_page_margins = true,
    t_page_margin = true,
    word_expansion = true,
    word_spacing = true,
}

local function copyValue(value)
    if type(value) == "table" then
        return util.tableDeepCopy(value)
    end
    return value
end

local function isSavable(value)
    local value_type = type(value)
    return value_type == "number" or value_type == "string" or value_type == "table"
end

function ReaderGlobalStyle:isEnabled(settings)
    return (settings or G_reader_settings):isTrue(self.setting_name)
end

function ReaderGlobalStyle:setEnabled(enabled, settings)
    settings = settings or G_reader_settings
    if enabled then
        settings:saveSetting(self.setting_name, true)
    else
        settings:delSetting(self.setting_name)
    end
end

function ReaderGlobalStyle:isStyleKey(key)
    return style_keys[key] == true
end

function ReaderGlobalStyle:detachCurrentStyle(configurable)
    for key, value in pairs(configurable) do
        if self:isStyleKey(key) and type(value) == "table" then
            configurable[key] = copyValue(value)
        end
    end
end

function ReaderGlobalStyle:loadDocumentSettings(configurable, document_settings, prefix, settings)
    settings = settings or G_reader_settings
    for key, value in pairs(configurable) do
        if isSavable(value) then
            local setting_key = prefix .. key
            if self:isStyleKey(key) then
                -- A newly global style key has no global value on upgrade.
                -- Seed it once from the first opened document, preserving the
                -- user's current choice; the global key is the migration flag.
                if not settings:has(setting_key) then
                    local saved_value = document_settings:readSetting(setting_key)
                    if saved_value ~= nil then
                        configurable[key] = copyValue(saved_value)
                    end
                    settings:saveSetting(setting_key, copyValue(configurable[key]))
                end
            else
                local saved_value = document_settings:readSetting(setting_key)
                if saved_value ~= nil then
                    configurable[key] = copyValue(saved_value)
                end
            end
        end
    end
end

function ReaderGlobalStyle:saveStyleSetting(key, value, prefix, settings)
    if not self:isStyleKey(key) or not isSavable(value) then return false end
    (settings or G_reader_settings):saveSetting(prefix .. key, copyValue(value))
    return true
end

function ReaderGlobalStyle:saveCurrentStyle(configurable, prefix, settings)
    for key, value in pairs(configurable) do
        self:saveStyleSetting(key, value, prefix, settings)
    end
end

function ReaderGlobalStyle:saveSettings(configurable, document_settings, prefix, settings)
    settings = settings or G_reader_settings
    for key, value in pairs(configurable) do
        if isSavable(value) then
            if self:isStyleKey(key) then
                settings:saveSetting(prefix .. key, copyValue(value))
            else
                document_settings:saveSetting(prefix .. key, copyValue(value))
            end
        end
    end
end

return ReaderGlobalStyle
