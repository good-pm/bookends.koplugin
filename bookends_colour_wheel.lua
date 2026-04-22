--[[
Bookends colour wheel — HSV wheel + brightness picker widget.

Ported from appearance.koplugin (Euphoriyy, GPL-3.0):
  https://github.com/Euphoriyy/appearance.koplugin
  Source commit: cf11c7ad67b1ef03e772078006d5796c32ac2c6d

Adaptations for Bookends:
- Cancel / Default / Apply button row (plugin-wide dialog convention).
- Writes {hex="#RRGGBB"} into settings via the on_apply callback.
- dismissable = false (plugin-wide dialog convention).
- Outer WidgetContainer shell owns the observer-facing dimen (halo-overlay
  suppression relies on this); inner CenterContainer keeps its own dimen
  untouched (see feedback_centercontainer_dimen.md — never reassign a
  CenterContainer's self.dimen post-paint).

Licence: GPL-3.0 (preserved from upstream). See LICENSE.
]]

local _ = require("bookends_i18n").gettext

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Font = require("ui/font")
local Screen = Device.screen

------------------------------------------------------------

local ColorWheelWidget = FocusManager:extend {
    title_text           = "Pick a color",
    width                = nil,
    width_factor         = 0.6,

    -- HSV values
    hue                  = 0, -- 0..360
    saturation           = 1,
    value                = 1,

    -- Whether to invert colors in night mode for accurate preview (default: true)
    invert_in_night_mode = true,

    -- Render the wheel at this fraction of full size, then scale up.
    -- Lower values are faster but produce more visible color banding.
    --
    -- | draw_scale | pixels rendered | speedup vs 1.0 |
    -- |------------|-----------------|----------------|
    -- | 1.0        | 100%            | 1x             |
    -- | 0.5        | 25%             | 4x             |
    -- | 0.25       | 6.25%           | 16x            |
    -- | 0.125      | 1.56%           | 64x            |
    draw_scale           = 0.5,

    cancel_text          = "Cancel",
    ok_text              = "Apply",
    default_text         = "Default",

    callback             = nil,
    cancel_callback      = nil,
    close_callback       = nil,
    default_callback     = nil,
}

------------------------------------------------------------
-- HSV → RGB
------------------------------------------------------------
local function hsvToRgb(h, s, v)
    local c = v * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local r, g, b
    if h < 60 then
        r, g, b = c, x, 0
    elseif h < 120 then
        r, g, b = x, c, 0
    elseif h < 180 then
        r, g, b = 0, c, x
    elseif h < 240 then
        r, g, b = 0, x, c
    elseif h < 300 then
        r, g, b = x, 0, c
    else
        r, g, b = c, 0, x
    end
    return
        math.floor((r + m) * 255 + 0.5),
        math.floor((g + m) * 255 + 0.5),
        math.floor((b + m) * 255 + 0.5)
end

------------------------------------------------------------
-- RGB → HSV  (inverse of hsvToRgb; used for hex seeding)
-- Returns h (0..360), s (0..1), v (0..1).
------------------------------------------------------------
local function rgbToHsv(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local max_c = math.max(r, g, b)
    local min_c = math.min(r, g, b)
    local delta = max_c - min_c

    local h, s, v
    v = max_c

    if max_c == 0 then
        s = 0
    else
        s = delta / max_c
    end

    if delta == 0 then
        h = 0
    elseif max_c == r then
        h = 60 * (((g - b) / delta) % 6)
    elseif max_c == g then
        h = 60 * (((b - r) / delta) + 2)
    else
        h = 60 * (((r - g) / delta) + 4)
    end

    if h < 0 then h = h + 360 end
    return h, s, v
end

------------------------------------------------------------
-- Hex "#RRGGBB" → h, s, v  (convenience wrapper)
------------------------------------------------------------
local function hexToHsv(hex)
    if not hex or not hex:match("^#%x%x%x%x%x%x$") then
        return 0, 1, 1
    end
    local r = tonumber(hex:sub(2, 3), 16)
    local g = tonumber(hex:sub(4, 5), 16)
    local b = tonumber(hex:sub(6, 7), 16)
    return rgbToHsv(r, g, b)
end

------------------------------------------------------------
-- Per-radius lookup cache: hue + saturation for every pixel.
-- Built once per unique draw_radius, survives widget rebuilds.
-- Pixels outside the circle are marked with sat = -1.
--
-- Cap the cache at MAX_CACHE_ENTRIES entries (LRU eviction).
-- Without a bound the table grows forever if draw_scale or widget
-- size varies across the process lifetime.
------------------------------------------------------------
local _wheel_cache      = {}
local _wheel_cache_keys = {} -- insertion-order list for LRU eviction
local MAX_CACHE_ENTRIES = 8

local function getWheelCache(draw_radius)
    if _wheel_cache[draw_radius] then
        return _wheel_cache[draw_radius]
    end

    -- Evict oldest entry when the cache is full
    if #_wheel_cache_keys >= MAX_CACHE_ENTRIES then
        local oldest = table.remove(_wheel_cache_keys, 1)
        _wheel_cache[oldest] = nil
    end

    local r2    = draw_radius * draw_radius
    local hue_t = {}
    local sat_t = {}
    local idx   = 0

    for py = -draw_radius, draw_radius do
        for px = -draw_radius, draw_radius do
            idx = idx + 1
            local dist2 = px * px + py * py
            if dist2 <= r2 then
                hue_t[idx] = (math.deg(math.atan2(py, px)) + 360) % 360
                sat_t[idx] = math.sqrt(dist2) / draw_radius
            else
                sat_t[idx] = -1
            end
        end
    end

    local cache = { hue = hue_t, sat = sat_t }
    _wheel_cache[draw_radius] = cache
    table.insert(_wheel_cache_keys, draw_radius)
    return cache
end

------------------------------------------------------------
-- ColorWheel: draws the wheel into an off-screen buffer
-- and blits it to the screen. Redraws only when value changes;
-- hue/saturation changes only move the indicator dot.
------------------------------------------------------------
local ColorWheel = WidgetContainer:extend {
    radius               = 0,
    hue                  = 0,
    saturation           = 1,
    value                = 1,
    invert_in_night_mode = true,
    draw_scale           = 0.5,
    _needs_redraw        = true,
    _last_val            = nil,
    _cached_buf          = nil,
}

function ColorWheel:init()
    self.radius      = math.floor(self.dimen.w / 2)
    self.dimen       = Geom:new { x = 0, y = 0, w = self.dimen.w, h = self.dimen.h }
    self.night_mode  = self.invert_in_night_mode and Screen.night_mode
    self.draw_radius = math.max(1, math.floor(self.radius * self.draw_scale))
    -- Pre-warm the cache so the first paint doesn't stutter
    getWheelCache(self.draw_radius)
    self._needs_redraw = true
end

function ColorWheel:free()
    if self._cached_buf then
        self._cached_buf:free()
        self._cached_buf = nil
    end
end

function ColorWheel:_renderToBuffer(x, y)
    local dr      = self.draw_radius
    local side    = dr * 2 + 1
    local buf     = Blitbuffer.new(side, side, Blitbuffer.TYPE_BBRGB32)
    local bgcolor = Screen.bb:getPixel(x - 1, y - 1)
    buf:paintRectRGB32(0, 0, side, side, bgcolor)

    local cache = getWheelCache(dr)
    local hue_t = cache.hue
    local sat_t = cache.sat
    local v     = self.value
    local nm    = self.night_mode
    local idx   = 0

    for py = -dr, dr do
        for px = -dr, dr do
            idx = idx + 1
            local s = sat_t[idx]
            if s >= 0 then
                local r, g, b = hsvToRgb(hue_t[idx], s, v)
                if nm then r, g, b = 255 - r, 255 - g, 255 - b end
                buf:setPixel(dr + 1 + px, dr + 1 + py,
                    Blitbuffer.ColorRGB32(r, g, b, 0xFF))
            end
        end
    end

    -- Free any previous buffer before replacing it
    if self._cached_buf then
        self._cached_buf:free()
    end
    self._cached_buf   = buf
    self._last_val     = v
    self._needs_redraw = false
end

function ColorWheel:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y

    if self._needs_redraw or self._last_val ~= self.value then
        self:_renderToBuffer(x, y)
    end

    local disp_side = self.radius * 2

    if self.draw_scale < 1.0 then
        -- Scale the small buffer up to display size, then free it
        local scaled = self._cached_buf:scale(disp_side, disp_side)
        bb:blitFrom(scaled, x, y, 0, 0, disp_side, disp_side)
        scaled:free()
    else
        bb:blitFrom(self._cached_buf, x, y, 0, 0, disp_side, disp_side)
    end

    -- Selection indicator at full display resolution (always crisp)
    local cx    = x + self.radius
    local cy    = y + self.radius
    local sel_x = cx + math.floor(math.cos(math.rad(self.hue)) * self.saturation * self.radius + 0.5)
    local sel_y = cy + math.floor(math.sin(math.rad(self.hue)) * self.saturation * self.radius + 0.5)

    for py = -4, 4 do
        for px = -4, 4 do
            local d = px * px + py * py
            if d <= 16 then
                bb:setPixelClamped(sel_x + px, sel_y + py, Blitbuffer.COLOR_WHITE)
            end
            if d <= 9 then
                bb:setPixelClamped(sel_x + px, sel_y + py, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

function ColorWheel:updateColor(ges_pos)
    if not self.dimen then return false end

    local cx    = self.dimen.x + self.radius
    local cy    = self.dimen.y + self.radius
    local dx    = ges_pos.x - cx
    local dy    = ges_pos.y - cy
    local dist2 = dx * dx + dy * dy

    if dist2 > self.radius * self.radius then return false end

    self.hue        = (math.deg(math.atan2(dy, dx)) + 360) % 360
    self.saturation = math.min(1, math.sqrt(dist2) / self.radius)

    if self.update_callback then
        self.update_callback()
    end
    return true
end

------------------------------------------------------------
-- Live color preview — reads hue/sat/val at paint time,
-- no widget rebuild needed during drag.
------------------------------------------------------------
local function makeLivePreview(parent, preview_size)
    local LivePreview = WidgetContainer:extend {
        dimen = Geom:new { w = preview_size, h = preview_size },
    }
    function LivePreview:paintTo(bb, x, y)
        local r, g, b = hsvToRgb(parent.hue, parent.saturation, parent.value)
        local nm = parent.invert_in_night_mode
            and G_reader_settings:isTrue("night_mode")
        if nm then r, g, b = 255 - r, 255 - g, 255 - b end
        bb:paintRectRGB32(x, y, self.dimen.w, self.dimen.h,
            Blitbuffer.ColorRGB32(r, g, b, 0xFF))
    end

    return LivePreview:new {}
end

------------------------------------------------------------
-- Live hex label — reads hue/sat/val at paint time.
------------------------------------------------------------
local function makeLiveHexLabel(parent, face)
    local LiveHex = WidgetContainer:extend {
        dimen = Geom:new { w = 0, h = 0 },
        _last_text = "",
        _tw = nil,
    }
    function LiveHex:paintTo(bb, x, y)
        local r, g, b = hsvToRgb(parent.hue, parent.saturation, parent.value)
        local txt = string.format("#%02X%02X%02X", r, g, b)
        -- Rebuild TextWidget only when the hex value actually changes
        if txt ~= self._last_text or not self._tw then
            if self._tw then self._tw:free() end
            self._tw = TextWidget:new { text = txt, face = face }
            self._last_text = txt
            local sz = self._tw:getSize()
            self.dimen.w = sz.w
            self.dimen.h = sz.h
        end
        self._tw:paintTo(bb, x, y)
    end

    return LiveHex:new {}
end

------------------------------------------------------------
-- Main dialog
------------------------------------------------------------
function ColorWheelWidget:init()
    self.screen_width     = Screen:getWidth()
    self.screen_height    = Screen:getHeight()
    self.medium_font_face = Font:getFace("ffont")
    self.hex_font_face    = Font:getFace("infofont", 20)

    if not self.width then
        self.width = math.floor(
            math.min(self.screen_width, self.screen_height) * self.width_factor
        )
    end

    self.inner_width  = self.width - 2 * Size.padding.large
    -- Three-button row: divide width by 3 (Default button added between Cancel and Apply)
    self.button_width = math.floor(self.inner_width / 4)

    if Device:isTouchDevice() then
        self.ges_events = {
            TapColorWheel = {
                GestureRange:new {
                    ges   = "tap",
                    range = Geom:new { x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height }
                }
            },
            PanColorWheel = {
                GestureRange:new {
                    ges   = "pan",
                    range = Geom:new { x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height }
                }
            },
            PanReleaseColorWheel = {
                GestureRange:new {
                    ges   = "pan_release",
                    range = Geom:new { x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height }
                }
            },
        }
    end

    self:update()
end

-- Free all owned FFI/widget resources before rebuilding the widget tree.
function ColorWheelWidget:_freeChildren()
    if self.color_wheel then
        self.color_wheel:free()
        self.color_wheel = nil
    end
    if self._live_hex then
        self._live_hex:free()
        self._live_hex = nil
    end
end

function ColorWheelWidget:onCloseWidget()
    self:_freeChildren()
end

function ColorWheelWidget:update()
    -- Free previous ColorWheel (and its _cached_buf) and LiveHex
    -- before creating new ones, so no orphaned FFI buffers are left behind.
    self:_freeChildren()

    local wheel_size    = self.width - 2 * Size.padding.large
    local preview_size  = math.floor(wheel_size / 4)

    self.color_wheel    = ColorWheel:new {
        dimen                = Geom:new { w = wheel_size, h = wheel_size },
        hue                  = self.hue,
        saturation           = self.saturation,
        value                = self.value,
        invert_in_night_mode = self.invert_in_night_mode,
        draw_scale           = self.draw_scale,
        -- update_callback is NOT set here — pan bypasses update() entirely
    }

    -- Live widgets read parent's hue/sat/val at paint time; no rebuild on drag
    self._live_preview  = makeLivePreview(self, preview_size)
    self._live_hex      = makeLiveHexLabel(self, self.hex_font_face)

    local title_bar     = TitleBar:new {
        width            = self.width,
        title            = self.title_text,
        with_bottom_line = true,
        close_button     = true,
        close_callback   = function() self:onCancel() end,
        show_parent      = self,
    }

    local value_minus   = Button:new {
        text        = "−",
        enabled     = self.value > 0,
        width       = self.button_width,
        show_parent = self,
        callback    = function()
            self.value = math.max(0, self.value - 0.1)
            -- Brightness change requires wheel re-render: use full update()
            self.color_wheel._needs_redraw = true
            self:update()
        end,
    }

    local value_plus    = Button:new {
        text        = "＋",
        enabled     = self.value < 1,
        width       = self.button_width,
        show_parent = self,
        callback    = function()
            self.value = math.min(1, self.value + 0.1)
            self.color_wheel._needs_redraw = true
            self:update()
        end,
    }

    local value_label   = TextWidget:new {
        text = string.format(_("Brightness: %d%%"), math.floor(self.value * 100)),
        face = self.medium_font_face,
    }

    local value_group   = HorizontalGroup:new {
        align = "center",
        value_minus,
        HorizontalSpan:new { width = Size.padding.large },
        value_label,
        HorizontalSpan:new { width = Size.padding.large },
        value_plus,
    }

    local preview_group = HorizontalGroup:new {
        align = "center",
        FrameContainer:new {
            bordersize = Size.border.thick,
            margin     = 0,
            padding    = 0,
            self._live_preview,
        },
        HorizontalSpan:new { width = Size.padding.large },
        self._live_hex,
    }

    -- Three-button row: Cancel | Default | Apply
    -- Button widths are sized to fit three buttons in the dialog's inner_width.
    local btn_w = math.floor((self.width - Size.padding.large * 4) / 3)

    local cancel_button = Button:new {
        text        = _(self.cancel_text),
        width       = btn_w,
        show_parent = self,
        callback    = function() self:onCancel() end,
    }

    local default_button = Button:new {
        text        = _(self.default_text),
        width       = btn_w,
        show_parent = self,
        callback    = function() self:onDefault() end,
    }

    local ok_button     = Button:new {
        text        = _(self.ok_text),
        width       = btn_w,
        show_parent = self,
        callback    = function() self:onApply() end,
    }

    local button_row    = HorizontalGroup:new {
        align = "center",
        cancel_button,
        HorizontalSpan:new { width = Size.padding.large },
        default_button,
        HorizontalSpan:new { width = Size.padding.large },
        ok_button,
    }

    local vgroup        = VerticalGroup:new {
        align = "center",
        title_bar,
        VerticalSpan:new { width = Size.padding.large },
        CenterContainer:new {
            dimen = Geom:new {
                w = self.width,
                h = value_label:getSize().h + Size.padding.default,
            },
            value_group,
        },
        VerticalSpan:new { width = Size.padding.large },
        CenterContainer:new {
            dimen = Geom:new {
                w = self.width,
                h = wheel_size + Size.padding.large * 2,
            },
            self.color_wheel,
        },
        VerticalSpan:new { width = Size.padding.large },
        CenterContainer:new {
            dimen = Geom:new {
                w = self.width,
                h = preview_size + Size.padding.default,
            },
            preview_group,
        },
        VerticalSpan:new { width = Size.padding.large * 2 },
        CenterContainer:new {
            dimen = Geom:new {
                w = self.width,
                h = Size.item.height_default,
            },
            button_row,
        },
        VerticalSpan:new { width = Size.padding.default },
    }

    self.frame          = FrameContainer:new {
        radius     = Size.radius.window,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        vgroup,
    }

    self.movable        = MovableContainer:new { self.frame }

    self[1]             = CenterContainer:new {
        dimen = Geom:new {
            x = 0, y = 0,
            w = self.screen_width, h = self.screen_height,
        },
        self.movable,
    }

    UIManager:setDirty(self, "ui")
end

------------------------------------------------------------
-- Gesture handlers
------------------------------------------------------------

-- Tap: update hue/sat.
-- Tap outside the dialog is intentionally suppressed (dismissable = false).
-- The dialog only closes via the button row.
function ColorWheelWidget:onTapColorWheel(arg, ges_ev)
    if not self.color_wheel.dimen or not self.frame.dimen then return true end

    if ges_ev.pos:intersectWith(self.color_wheel.dimen) then
        if self.color_wheel:updateColor(ges_ev.pos) then
            self.hue        = self.color_wheel.hue
            self.saturation = self.color_wheel.saturation
            UIManager:setDirty(self, "ui")
        end
        return true
    end
    -- Taps outside the dialog frame are silently consumed (no dismiss).
    return true
end

-- Pan: sync values + fast-dirty + periodic ui-dirty only the wheel region.
function ColorWheelWidget:onPanColorWheel(arg, ges_ev)
    if not self.color_wheel or not self.color_wheel.dimen then return false end

    if ges_ev.pos:intersectWith(self.color_wheel.dimen) then
        if self.color_wheel:updateColor(ges_ev.pos) then
            self.hue        = self.color_wheel.hue
            self.saturation = self.color_wheel.saturation

            self._pan_tick  = (self._pan_tick or 0) + 1
            local mode      = (self._pan_tick % 8 == 0) and "ui" or "fast"

            UIManager:setDirty(self, mode)
        end
        return true
    end
    return false
end

-- Pan release: one clean "ui" refresh to fix A2 ghosting,
-- plus a full update() so the hex label and preview sync up.
function ColorWheelWidget:onPanReleaseColorWheel(arg, ges_ev)
    if not self.color_wheel or not self.color_wheel.dimen then return false end

    if ges_ev.pos:intersectWith(self.color_wheel.dimen) then
        self:update() -- rebuilds widget tree with final hue/sat; does "ui" dirty
        return true
    end
    return false
end

function ColorWheelWidget:onApply()
    UIManager:close(self)
    if self.callback then
        local r, g, b = hsvToRgb(self.hue, self.saturation, self.value)
        self.callback(string.format("#%02X%02X%02X", r, g, b))
    end
    if self.close_callback then self.close_callback() end
    return true
end

function ColorWheelWidget:onDefault()
    UIManager:close(self)
    if self.default_callback then
        self.default_callback()
    end
    if self.close_callback then self.close_callback() end
    return true
end

function ColorWheelWidget:onCancel()
    UIManager:close(self)
    if self.cancel_callback then self.cancel_callback() end
    if self.close_callback then self.close_callback() end
    return true
end

function ColorWheelWidget:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

------------------------------------------------------------
-- Bookends entry point
------------------------------------------------------------

--- Show the HSV colour picker for a single field.
--- @param title string: dialog title
--- @param current_hex string|nil: "#RRGGBB" or nil (fall back to default)
--- @param default_hex string|nil: shown behind the "Default" button; when
---        nil, Default clears the field (on_default callback)
--- @param on_apply function(new_hex) — called on Apply
--- @param on_default function()|nil — called on Default (optional; when nil,
---        the picker seeds itself with default_hex but on_apply still fires)
--- @param touchmenu_instance any — forwarded to self:hideMenu() for touchmenu
---        restore on close (matches showNudgeDialog's contract)
local function showColourPicker(bookends, title, current_hex, default_hex, on_apply, on_default, touchmenu_instance)
    local restoreMenu = bookends:hideMenu(touchmenu_instance)

    -- Convert seed hex to HSV; fall back to default_hex, then red (0,1,1)
    local seed_hex = current_hex or default_hex
    local h, s, v = hexToHsv(seed_hex)

    -- close_callback: restore the touchmenu regardless of how dialog closes
    local function close_cb()
        restoreMenu()
    end

    -- default_callback: either call on_default, or seed with default_hex and apply
    local function default_cb()
        if on_default then
            on_default()
        else
            -- Fall back: apply default_hex directly (on_apply handles nil gracefully
            -- if the caller wants to clear the field by passing nil as default_hex)
            if on_apply then
                on_apply(default_hex)
            end
        end
    end

    local wheel = ColorWheelWidget:new {
        title_text       = title or _("Pick a color"),
        hue              = h,
        saturation       = s,
        value            = v,
        callback         = on_apply,
        cancel_callback  = nil,
        default_callback = default_cb,
        close_callback   = close_cb,
    }
    UIManager:show(wheel)
end

------------------------------------------------------------
-- attach() — wires showColourPicker onto the Bookends class
------------------------------------------------------------
local M = {}

function M.attach(Bookends)
    function Bookends:showColourPicker(title, current_hex, default_hex, on_apply, on_default, touchmenu_instance)
        showColourPicker(self, title, current_hex, default_hex, on_apply, on_default, touchmenu_instance)
    end
end

return M
