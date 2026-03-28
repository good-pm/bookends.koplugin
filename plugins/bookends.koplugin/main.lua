local Device = require("device")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local Screen = Device.screen
local Tokens = require("tokens")
local OverlayWidget = require("overlay_widget")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")

local Bookends = WidgetContainer:extend{
    name = "bookends",
    is_doc_only = true,
}

-- Position keys and their properties
Bookends.POSITIONS = {
    { key = "tl", label = _("Top-left"),      row = "top",    h_anchor = "left",   v_anchor = "top" },
    { key = "tc", label = _("Top-center"),     row = "top",    h_anchor = "center", v_anchor = "top" },
    { key = "tr", label = _("Top-right"),      row = "top",    h_anchor = "right",  v_anchor = "top" },
    { key = "bl", label = _("Bottom-left"),    row = "bottom", h_anchor = "left",   v_anchor = "bottom" },
    { key = "bc", label = _("Bottom-center"),  row = "bottom", h_anchor = "center", v_anchor = "bottom" },
    { key = "br", label = _("Bottom-right"),   row = "bottom", h_anchor = "right",  v_anchor = "bottom" },
}

function Bookends:init()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self.ui.view:registerViewModule("bookends", self)
    self.session_start_time = os.time()
    self.dirty = true
    self.position_cache = {} -- cached expanded text per position key
end

function Bookends:loadSettings()
    local footer_settings = self.ui.view.footer.settings
    self.enabled = G_reader_settings:readSetting("bookends_enabled", false)

    -- Global defaults
    self.defaults = {
        font_face = G_reader_settings:readSetting("bookends_font_face", Font.fontmap["ffont"]),
        font_size = G_reader_settings:readSetting("bookends_font_size", footer_settings.text_font_size),
        font_bold = G_reader_settings:readSetting("bookends_font_bold", false),
        v_offset  = G_reader_settings:readSetting("bookends_v_offset", 35),
        h_offset  = G_reader_settings:readSetting("bookends_h_offset", 10),
        overlap_gap = G_reader_settings:readSetting("bookends_overlap_gap", 10),
    }

    -- Per-position settings (table with format, font_face, font_size, etc.)
    self.positions = {}
    for _, pos in ipairs(self.POSITIONS) do
        self.positions[pos.key] = G_reader_settings:readSetting("bookends_pos_" .. pos.key, {
            format = "",
        })
    end
end

function Bookends:savePositionSetting(key)
    G_reader_settings:saveSetting("bookends_pos_" .. key, self.positions[key])
end

function Bookends:getPositionSetting(key, field)
    local pos = self.positions[key]
    if pos[field] ~= nil then
        return pos[field]
    end
    return self.defaults[field]
end

function Bookends:isPositionActive(key)
    return self.enabled and self.positions[key].format ~= ""
end

function Bookends:markDirty()
    self.dirty = true
    UIManager:setDirty(self.ui, "ui")
end

-- Event handlers
function Bookends:onPageUpdate() self:markDirty() end
function Bookends:onPosUpdate() self:markDirty() end
function Bookends:onReaderFooterVisibilityChange() self:markDirty() end
function Bookends:onSetDimensions() self:markDirty() end
function Bookends:onResume() self:markDirty() end

function Bookends:paintTo(bb, x, y)
    if not self.enabled then return end

    local screen_size = Screen:getSize()
    local screen_w = screen_size.w
    local screen_h = screen_size.h

    -- Phase 1: Expand tokens for all active positions
    local expanded = {} -- key -> expanded text string
    for _, pos in ipairs(self.POSITIONS) do
        if self:isPositionActive(pos.key) then
            local fmt = self.positions[pos.key].format
            -- Convert literal backslash-n to real newline for line splitting
            fmt = fmt:gsub("\\n", "\n")
            expanded[pos.key] = Tokens.expand(fmt, self.ui, self.session_start_time)
        end
    end

    -- Check if anything changed
    if not self.dirty then
        local changed = false
        for key, text in pairs(expanded) do
            if text ~= self.position_cache[key] then
                changed = true
                break
            end
        end
        if not changed then
            -- Repaint existing widgets at their cached positions
            for _, pos in ipairs(self.POSITIONS) do
                local entry = self.widget_cache and self.widget_cache[pos.key]
                if entry then
                    entry.widget:paintTo(bb, x + entry.x, y + entry.y)
                end
            end
            return
        end
    end

    -- Phase 2: Measure all active positions (no truncation yet)
    local measurements = {} -- key -> { width, face, bold }
    for key, text in pairs(expanded) do
        local face = Font:getFace(
            self:getPositionSetting(key, "font_face"),
            self:getPositionSetting(key, "font_size"))
        local bold = self:getPositionSetting(key, "font_bold")
        local w = OverlayWidget.measureTextWidth(text, face, bold)
        measurements[key] = { width = w, face = face, bold = bold }
    end

    -- Phase 3: Calculate overlap limits per row
    local gap = self.defaults.overlap_gap

    -- Free old widgets
    if self.widget_cache then
        OverlayWidget.freeWidgets(self.widget_cache)
    end
    self.widget_cache = {}

    for _, row in ipairs({"top", "bottom"}) do
        local left_key = row == "top" and "tl" or "bl"
        local center_key = row == "top" and "tc" or "bc"
        local right_key = row == "top" and "tr" or "br"

        local left_w = measurements[left_key] and measurements[left_key].width or nil
        local center_w = measurements[center_key] and measurements[center_key].width or nil
        local right_w = measurements[right_key] and measurements[right_key].width or nil

        local left_h_offset = self:getPositionSetting(left_key, "h_offset")
        local right_h_offset = self:getPositionSetting(right_key, "h_offset")
        -- Use the larger h_offset for overlap calc to be safe
        local max_h_offset = math.max(left_h_offset or 0, right_h_offset or 0)

        local limits = OverlayWidget.calculateRowLimits(
            left_w, center_w, right_w, screen_w, gap, max_h_offset)

        -- Phase 4: Build widgets with truncation limits applied
        local row_keys = {
            { key = left_key, limit_key = "left" },
            { key = center_key, limit_key = "center" },
            { key = right_key, limit_key = "right" },
        }
        for _, rk in ipairs(row_keys) do
            local key = rk.key
            if expanded[key] then
                local m = measurements[key]
                local pos_def = nil
                for _, p in ipairs(self.POSITIONS) do
                    if p.key == key then pos_def = p; break end
                end

                local max_width = limits[rk.limit_key] -- nil if no truncation needed
                local widget, w, h = OverlayWidget.buildTextWidget(
                    expanded[key], m.face, m.bold, pos_def.h_anchor, max_width)

                if widget then
                    local v_off = self:getPositionSetting(key, "v_offset")
                    local h_off = self:getPositionSetting(key, "h_offset")
                    local px, py = OverlayWidget.computeCoordinates(
                        pos_def.h_anchor, pos_def.v_anchor,
                        w, h, screen_w, screen_h, v_off, h_off)

                    self.widget_cache[key] = { widget = widget, x = px, y = py }
                    widget:paintTo(bb, x + px, y + py)
                end
            end
        end
    end

    -- Update cache
    self.position_cache = {}
    for key, text in pairs(expanded) do
        self.position_cache[key] = text
    end
    self.dirty = false
end

function Bookends:onCloseWidget()
    if self.widget_cache then
        OverlayWidget.freeWidgets(self.widget_cache)
        self.widget_cache = nil
    end
end

function Bookends:addToMainMenu(menu_items)
    menu_items.bookends = {
        text = _("Bookends"),
        sorting_hint = "setting",
        sub_item_table = self:buildMainMenu(),
    }
end

function Bookends:buildMainMenu()
    local menu = {
        {
            text = _("Enable bookends"),
            checked_func = function()
                return self.enabled
            end,
            callback = function()
                self.enabled = not self.enabled
                G_reader_settings:saveSetting("bookends_enabled", self.enabled)
                self:markDirty()
            end,
        },
    }

    -- Per-position submenus
    for _, pos in ipairs(self.POSITIONS) do
        table.insert(menu, {
            text_func = function()
                local fmt = self.positions[pos.key].format
                if fmt == "" then
                    return pos.label
                else
                    return pos.label .. ": " .. fmt
                end
            end,
            enabled_func = function() return self.enabled end,
            sub_item_table_func = function()
                return self:buildPositionMenu(pos)
            end,
        })
    end

    -- Separator
    table.insert(menu, {
        text = "──────────",
        enabled_func = function() return false end,
    })

    -- Global defaults
    table.insert(menu, {
        text = _("Default font"),
        enabled_func = function() return self.enabled end,
        sub_item_table = self:buildFontMenu(function() return self.defaults.font_face end,
            function(face)
                self.defaults.font_face = face
                G_reader_settings:saveSetting("bookends_font_face", face)
                self:markDirty()
            end),
    })
    table.insert(menu, {
        text = _("Default font size"),
        keep_menu_open = true,
        enabled_func = function() return self.enabled end,
        callback = function()
            self:showSpinner(_("Default font size"), self.defaults.font_size, 8, 36,
                self.ui.view.footer.settings.text_font_size,
                function(val)
                    self.defaults.font_size = val
                    G_reader_settings:saveSetting("bookends_font_size", val)
                    self:markDirty()
                end)
        end,
    })
    table.insert(menu, {
        text = _("Default vertical offset"),
        keep_menu_open = true,
        enabled_func = function() return self.enabled end,
        callback = function()
            self:showSpinner(_("Default vertical offset (px)"), self.defaults.v_offset, 0, 200, 35,
                function(val)
                    self.defaults.v_offset = val
                    G_reader_settings:saveSetting("bookends_v_offset", val)
                    self:markDirty()
                end)
        end,
    })
    table.insert(menu, {
        text = _("Default horizontal offset"),
        keep_menu_open = true,
        enabled_func = function() return self.enabled end,
        callback = function()
            self:showSpinner(_("Default horizontal offset (px)"), self.defaults.h_offset, 0, 200, 10,
                function(val)
                    self.defaults.h_offset = val
                    G_reader_settings:saveSetting("bookends_h_offset", val)
                    self:markDirty()
                end)
        end,
    })
    table.insert(menu, {
        text = _("Overlap gap"),
        keep_menu_open = true,
        enabled_func = function() return self.enabled end,
        callback = function()
            self:showSpinner(_("Minimum gap between texts (px)"), self.defaults.overlap_gap, 0, 100, 10,
                function(val)
                    self.defaults.overlap_gap = val
                    G_reader_settings:saveSetting("bookends_overlap_gap", val)
                    self:markDirty()
                end)
        end,
    })

    return menu
end

function Bookends:buildPositionMenu(pos)
    local is_corner = pos.h_anchor ~= "center"
    local menu = {
        {
            text = _("Edit format string"),
            keep_menu_open = true,
            callback = function()
                self:editFormatString(pos.key)
            end,
        },
        {
            text_func = function()
                if self.positions[pos.key].font_face then
                    return _("Override font (active)")
                end
                return _("Override font")
            end,
            sub_item_table_func = function()
                local items = self:buildFontMenu(
                    function() return self:getPositionSetting(pos.key, "font_face") end,
                    function(face)
                        self.positions[pos.key].font_face = face
                        self:savePositionSetting(pos.key)
                        self:markDirty()
                    end)
                -- Add "Reset to default" at the top
                table.insert(items, 1, {
                    text = _("Reset to default"),
                    callback = function()
                        self.positions[pos.key].font_face = nil
                        self:savePositionSetting(pos.key)
                        self:markDirty()
                    end,
                })
                return items
            end,
        },
        {
            text_func = function()
                if self.positions[pos.key].font_size then
                    return _("Override font size") .. " (" .. self.positions[pos.key].font_size .. ")"
                end
                return _("Override font size")
            end,
            keep_menu_open = true,
            callback = function()
                self:showSpinner(_("Font size for " .. pos.label),
                    self:getPositionSetting(pos.key, "font_size"), 8, 36,
                    self.defaults.font_size,
                    function(val)
                        self.positions[pos.key].font_size = val
                        self:savePositionSetting(pos.key)
                        self:markDirty()
                    end)
            end,
        },
        {
            text_func = function()
                if self.positions[pos.key].v_offset then
                    return _("Override vertical offset") .. " (" .. self.positions[pos.key].v_offset .. ")"
                end
                return _("Override vertical offset")
            end,
            keep_menu_open = true,
            callback = function()
                self:showSpinner(_("Vertical offset for " .. pos.label),
                    self:getPositionSetting(pos.key, "v_offset"), 0, 200,
                    self.defaults.v_offset,
                    function(val)
                        self.positions[pos.key].v_offset = val
                        self:savePositionSetting(pos.key)
                        self:markDirty()
                    end)
            end,
        },
    }

    -- Horizontal offset only for corners
    if is_corner then
        table.insert(menu, {
            text_func = function()
                if self.positions[pos.key].h_offset then
                    return _("Override horizontal offset") .. " (" .. self.positions[pos.key].h_offset .. ")"
                end
                return _("Override horizontal offset")
            end,
            keep_menu_open = true,
            callback = function()
                self:showSpinner(_("Horizontal offset for " .. pos.label),
                    self:getPositionSetting(pos.key, "h_offset"), 0, 200,
                    self.defaults.h_offset,
                    function(val)
                        self.positions[pos.key].h_offset = val
                        self:savePositionSetting(pos.key)
                        self:markDirty()
                    end)
            end,
        })
    end

    -- Reset all overrides
    table.insert(menu, {
        text = _("Reset all overrides"),
        callback = function()
            local fmt = self.positions[pos.key].format
            self.positions[pos.key] = { format = fmt }
            self:savePositionSetting(pos.key)
            self:markDirty()
        end,
    })

    return menu
end

function Bookends:editFormatString(pos_key)
    local IconPicker = require("icon_picker")

    local format_dialog
    format_dialog = InputDialog:new{
        title = _("Format string"),
        input = self.positions[pos_key].format,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(format_dialog)
                    end,
                },
                {
                    text = _("Icons"),
                    callback = function()
                        IconPicker:show(function(glyph)
                            format_dialog:addTextToInput(glyph)
                        end)
                    end,
                },
                {
                    text = _("Tokens"),
                    callback = function()
                        UIManager:show(InfoMessage:new{
                            text = _([[
Tokens:
%c  current page       %t  total pages
%p  book % read        %P  chapter % read
%g  pages read in ch.  %l  pages left in ch.
%L  pages left in book
%h  time left (ch.)    %H  time left (book)
%k  12h clock          %K  24h clock
%R  session reading time
%T  title              %A  author(s)
%S  series             %C  chapter title
%b  battery level      %B  battery icon
%r  separator ( | )
\n  line break]]),
                        })
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        self.positions[pos_key].format = format_dialog:getInputText()
                        self:savePositionSetting(pos_key)
                        UIManager:close(format_dialog)
                        self:markDirty()
                    end,
                },
            },
        },
    }
    UIManager:show(format_dialog)
    format_dialog:onShowKeyboard()
end

function Bookends:buildFontMenu(get_current, on_select)
    local cre = require("document/credocument"):engineInit()
    local FontList = require("fontlist")
    local face_list = cre.getFontFaces()
    local menu = {}
    for _, face_name in ipairs(face_list) do
        local font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(face_name)
        if not font_filename then
            font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(face_name, nil, true)
        end
        if font_filename then
            local display_name = FontList:getLocalizedFontName(font_filename, font_faceindex) or face_name
            table.insert(menu, {
                text = display_name,
                checked_func = function()
                    return get_current() == font_filename
                end,
                callback = function()
                    on_select(font_filename)
                end,
            })
        end
    end
    return menu
end

function Bookends:showSpinner(title, value, min, max, default, on_set)
    UIManager:show(SpinWidget:new{
        value = value,
        value_min = min,
        value_max = max,
        default_value = default,
        title_text = title,
        ok_text = _("Set"),
        callback = function(spin)
            on_set(spin.value)
        end,
    })
end

return Bookends
