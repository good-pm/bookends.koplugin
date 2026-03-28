local Device = require("device")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local Screen = Device.screen

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
    -- Will delegate to overlay_widget in Task 3
end

function Bookends:onCloseWidget()
    -- Will free widgets in Task 3
end

function Bookends:addToMainMenu(menu_items)
    -- Will be implemented in Task 5
    menu_items.bookends = {
        text = _("Bookends"),
        sorting_hint = "setting",
        sub_item_table = {},
    }
end

return Bookends
