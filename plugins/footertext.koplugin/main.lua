local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local FooterText = WidgetContainer:extend{
    name = "footertext",
    is_doc_only = true,
}

function FooterText:init()
    self.ui.menu:registerToMainMenu(self)
    self:loadSettings()
    self:buildWidget()
    self.ui.view:registerViewModule("footertext", self)
end

function FooterText:loadSettings()
    local footer_settings = self.ui.view.footer.settings
    self.enabled = G_reader_settings:isTrue("footertext_enabled")
    -- Default to enabled if setting doesn't exist yet
    if G_reader_settings:readSetting("footertext_enabled") == nil then
        self.enabled = true
    end
    self.format = G_reader_settings:readSetting("footertext_format", "Page %c")
    self.font_size = G_reader_settings:readSetting("footertext_font_size", footer_settings.text_font_size)
    self.font_face_name = "ffont"
    self.font_bold = footer_settings.text_font_bold or false
    self.vertical_offset = G_reader_settings:readSetting("footertext_vertical_offset", 0)
end

function FooterText:buildWidget()
    local screen_size = Screen:getSize()
    self.text_face = Font:getFace(self.font_face_name, self.font_size)
    self.text_widget = TextWidget:new{
        text = "",
        face = self.text_face,
        bold = self.font_bold,
    }
    self.center_container = CenterContainer:new{
        dimen = Geom:new{ w = screen_size.w, h = self.text_widget:getSize().h },
        self.text_widget,
    }
    self.bottom_container = BottomContainer:new{
        dimen = Geom:new{ w = screen_size.w, h = screen_size.h },
        self.center_container,
    }
end

function FooterText:paintTo(bb, x, y)
    if not self.enabled then return end
    self:updateText()
    self:updatePosition()
    self.bottom_container:paintTo(bb, x, y)
end

function FooterText:onCloseWidget()
    if self.text_widget then
        self.text_widget:free()
    end
end

function FooterText:addToMainMenu(menu_items)
    -- placeholder, implemented in Task 4
end

return FooterText
