--[[
Bookends colour palette picker.

A grid of 25 curated swatches (5 families of 5 shades) plus a hex input for
custom values. Tap-to-preview: every swatch tap applies immediately via the
apply_callback, so the book repaints around the edges of the dialog; Apply
just closes, Cancel reverts via revert_callback, Default clears the field.

Storage shape is always {hex = "#RRGGBB"} — the palette is pure UX; changing
the palette in a future release doesn't invalidate any stored preset.
]]

local _ = require("bookends_i18n").gettext

local Blitbuffer    = require("ffi/blitbuffer")
local Button        = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device        = require("device")
local FocusManager  = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom          = require("ui/geometry")
local GestureRange  = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText     = require("ui/widget/inputtext")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification  = require("ui/widget/notification")
local Size          = require("ui/size")
local TextWidget    = require("ui/widget/textwidget")
local TitleBar      = require("ui/widget/titlebar")
local UIManager     = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan  = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Font          = require("ui/font")
local Screen        = Device.screen

------------------------------------------------------------
-- Curated palette: 5 rows × 5 columns
------------------------------------------------------------
local PALETTE = {
    { "#000000", "#404040", "#808080", "#BFBFBF", "#FFFFFF" },  -- neutrals
    { "#8B1A1A", "#B8570F", "#6B3E26", "#8B6914", "#5E2B1B" },  -- warm dark
    { "#E8A0B8", "#F4B58C", "#D4A574", "#E8D990", "#E89B8C" },  -- warm light
    { "#1B2A5E", "#2D4A2B", "#1F5E5E", "#4A2B5E", "#2B3A4A" },  -- cool dark
    { "#A0C4E8", "#A0D4B8", "#C4A0E8", "#B8D4E8", "#E8A0C4" },  -- cool light
}

local SWATCH_SIDE  = Screen:scaleBySize(60)
local SWATCH_GAP   = Screen:scaleBySize(6)

------------------------------------------------------------
-- Swatch: a coloured square that renders in true colour via paintRectRGB32.
-- Owns its own dimen (set at paint time); this is NOT a CenterContainer so
-- the feedback_centercontainer_dimen.md constraint does not apply here.
------------------------------------------------------------
local Swatch = WidgetContainer:extend{
    dimen    = nil,
    hex      = nil,
    selected = false,
    side     = nil,
}

function Swatch:init()
    local r = tonumber(self.hex:sub(2, 3), 16)
    local g = tonumber(self.hex:sub(4, 5), 16)
    local b = tonumber(self.hex:sub(6, 7), 16)
    self._fill = Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

function Swatch:getSize()
    return { w = self.side, h = self.side }
end

function Swatch:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.side, h = self.side }
    -- Fill in true colour
    bb:paintRectRGB32(x, y, self.side, self.side, self._fill)
    -- Border: thick black if selected, thin dark-grey otherwise
    local bw = self.selected and Size.border.thick or Size.border.thin
    local bc = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
    bb:paintBorder(x, y, self.side, self.side, bw, bc)
end

------------------------------------------------------------
-- swatchTile: InputContainer wrapping a Swatch for gesture handling.
------------------------------------------------------------
local function swatchTile(hex, selected, side, on_tap)
    local swatch = Swatch:new{ hex = hex, selected = selected, side = side }
    local container = InputContainer:new{
        dimen = Geom:new{ w = side, h = side },
        swatch,
    }
    container.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = container.dimen },
        },
    }
    function container:onTapSelect()
        on_tap(hex)
        return true
    end
    return container
end

------------------------------------------------------------
-- Main dialog
------------------------------------------------------------
local ColourPaletteWidget = FocusManager:extend{
    title            = nil,
    selected_hex     = nil,
    apply_callback   = nil,
    default_callback = nil,
    revert_callback  = nil,
    ok_callback      = nil,
}

function ColourPaletteWidget:init()
    self.screen_width  = Screen:getWidth()
    self.screen_height = Screen:getHeight()

    -- Total palette width: 5 swatches + 6 gaps (one on each side + between each)
    self.palette_width = SWATCH_SIDE * 5 + SWATCH_GAP * 6
    -- Dialog inner width matches the palette plus outer padding on each side
    self.inner_width   = self.palette_width + Size.padding.large * 2
    self.dialog_width  = self.inner_width + 2 * Size.border.window

    -- Swallow all taps so the dialog is non-dismissable from outside
    if Device:isTouchDevice() then
        self.ges_events = {
            TapOutside = {
                GestureRange:new{
                    ges   = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height,
                    },
                },
            },
        }
    end

    self:update()
end

function ColourPaletteWidget:onTapOutside()
    -- Silently consume taps outside the dialog frame (non-dismissable).
    return true
end

function ColourPaletteWidget:update()
    local gap      = SWATCH_GAP
    local side     = SWATCH_SIDE
    local iw       = self.inner_width

    -- Build the palette grid
    local palette_vgroup = VerticalGroup:new{ align = "center" }
    for _row, row_hexes in ipairs(PALETTE) do
        local hgroup = HorizontalGroup:new{ align = "center" }
        -- Left gap
        hgroup[#hgroup + 1] = HorizontalSpan:new{ width = gap }
        for _col, hex in ipairs(row_hexes) do
            local is_selected = (hex == self.selected_hex)
            local tile = swatchTile(hex, is_selected, side, function(tapped_hex)
                self.selected_hex = tapped_hex
                if self.apply_callback then self.apply_callback(tapped_hex) end
                self:update()
            end)
            hgroup[#hgroup + 1] = tile
            hgroup[#hgroup + 1] = HorizontalSpan:new{ width = gap }
        end
        palette_vgroup[#palette_vgroup + 1] = VerticalSpan:new{ height = gap }
        palette_vgroup[#palette_vgroup + 1] = hgroup
    end
    palette_vgroup[#palette_vgroup + 1] = VerticalSpan:new{ height = gap }

    -- Hex input row
    local face = Font:getFace("cfont", 20)
    local label = TextWidget:new{
        text = _("Hex:"),
        face = face,
    }
    local label_size = label:getSize()

    self.hex_input = InputText:new{
        text         = self.selected_hex or "",
        hint         = "#RRGGBB",
        input_type   = "string",
        width        = Screen:scaleBySize(140),
        face         = face,
        focused      = false,
        enter_callback = function()
            self:onHexSubmit()
        end,
    }

    local set_button = Button:new{
        text        = _("Set"),
        show_parent = self,
        callback    = function()
            self:onHexSubmit()
        end,
    }

    local hex_row = HorizontalGroup:new{
        align = "center",
        label,
        HorizontalSpan:new{ width = Size.padding.small },
        self.hex_input,
        HorizontalSpan:new{ width = Size.padding.small },
        set_button,
    }

    -- Three-button row: Cancel | Default | Apply
    local btn_w = math.floor((iw - Size.padding.large * 4) / 3)

    local cancel_button = Button:new{
        text        = _("Cancel"),
        width       = btn_w,
        show_parent = self,
        callback    = function()
            if self.revert_callback then self.revert_callback() end
        end,
    }

    local default_button = Button:new{
        text        = _("Default"),
        width       = btn_w,
        show_parent = self,
        callback    = function()
            if self.default_callback then self.default_callback() end
        end,
    }

    local apply_button = Button:new{
        text        = _("Apply"),
        width       = btn_w,
        show_parent = self,
        callback    = function()
            if self.ok_callback then self.ok_callback() end
        end,
    }

    local button_row = HorizontalGroup:new{
        align = "center",
        cancel_button,
        HorizontalSpan:new{ width = Size.padding.large },
        default_button,
        HorizontalSpan:new{ width = Size.padding.large },
        apply_button,
    }

    local title_bar = TitleBar:new{
        width            = self.dialog_width,
        title            = self.title or _("Pick a color"),
        with_bottom_line = true,
        show_parent      = self,
    }

    local vgroup = VerticalGroup:new{
        align = "center",
        title_bar,
        VerticalSpan:new{ height = Size.padding.large },
        CenterContainer:new{
            dimen = Geom:new{ w = self.dialog_width, h = (side + gap) * 5 + gap },
            palette_vgroup,
        },
        VerticalSpan:new{ height = Size.padding.large },
        CenterContainer:new{
            dimen = Geom:new{
                w = self.dialog_width,
                h = label_size.h + Size.padding.default,
            },
            hex_row,
        },
        VerticalSpan:new{ height = Size.padding.default },
        CenterContainer:new{
            dimen = Geom:new{
                w = self.dialog_width,
                h = Size.item.height_default,
            },
            button_row,
        },
        VerticalSpan:new{ height = Size.padding.default },
    }

    local frame = FrameContainer:new{
        radius     = Size.radius.window,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        vgroup,
    }

    local movable = MovableContainer:new{ frame }

    -- CenterContainer dimen is set once at construction and never reassigned post-paint
    -- (see feedback_centercontainer_dimen.md).
    self[1] = CenterContainer:new{
        dimen = Geom:new{
            x = 0, y = 0,
            w = self.screen_width, h = self.screen_height,
        },
        movable,
    }

    UIManager:setDirty(self, "ui")
end

function ColourPaletteWidget:onHexSubmit()
    local txt = self.hex_input:getText()
    if not txt then return end
    local hex = txt:match("^%s*(#?%x%x%x%x%x%x)%s*$")
    if not hex then
        Notification:notify(_("Invalid hex colour (use #RRGGBB)"))
        return
    end
    if hex:sub(1, 1) ~= "#" then hex = "#" .. hex end
    hex = hex:upper()
    self.selected_hex = hex
    if self.apply_callback then self.apply_callback(hex) end
    self:update()
end

function ColourPaletteWidget:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

------------------------------------------------------------
-- Public entry point
------------------------------------------------------------
local function showColourPicker(bookends, title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance)
    local restoreMenu = bookends:hideMenu(touchmenu_instance)

    local closed = false
    local function finish()
        if closed then return end
        closed = true
        restoreMenu()
    end

    local widget
    widget = ColourPaletteWidget:new{
        title          = title or _("Pick a color"),
        selected_hex   = current_hex,
        apply_callback = on_apply,
        default_callback = function()
            UIManager:close(widget)
            if on_default then on_default() end
            finish()
        end,
        revert_callback = function()
            UIManager:close(widget)
            if on_revert then on_revert() end
            finish()
        end,
        ok_callback = function()
            UIManager:close(widget)
            finish()
        end,
    }
    UIManager:show(widget)
end

local M = {}
function M.attach(Bookends)
    function Bookends:showColourPicker(title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance)
        showColourPicker(self, title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance)
    end
end
return M
