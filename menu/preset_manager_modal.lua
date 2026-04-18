--- Preset Manager: central-aligned modal with Local/Gallery tabs.
-- Local tab renders Personal presets + virtual "(No overlay)" row,
-- supports preview/apply, star toggle for cycle membership, and
-- overflow actions (rename/edit description/duplicate/delete).
-- Gallery tab is a stub until Phase 2.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local util = require("util")
local _ = require("i18n").gettext
local T = require("ffi/util").template

local Screen = Device.screen

local PresetManagerModal = {}

--- Open the manager modal. Single entry point from menu / gesture.
function PresetManagerModal.show(bookends)
    local self = {
        bookends = bookends,
        tab = "local",
        previewing = nil,
        original_settings = nil,
        modal_widget = nil,
    }

    self.original_settings = util.tableDeepCopy({
        enabled   = bookends.enabled,
        positions = bookends.positions,
        defaults  = bookends.defaults,
        active_filename = bookends:getActivePresetFilename(),
    })

    self.rebuild = function() PresetManagerModal._rebuild(self) end
    self.close = function(restore) PresetManagerModal._close(self, restore) end
    self.setTab = function(tab)
        if self.tab ~= tab then self.tab = tab; self.rebuild() end
    end
    self.previewLocal = function(p) PresetManagerModal._previewLocal(self, p) end
    self.previewBlank = function() PresetManagerModal._previewBlank(self) end
    self.applyCurrent = function() PresetManagerModal._applyCurrent(self) end
    self.toggleStar = function(key) PresetManagerModal._toggleStar(self, key) end

    self.rebuild()
end

function PresetManagerModal._close(self, restore)
    if restore and self.previewing then
        local snap = self.original_settings
        self.bookends.enabled   = snap.enabled
        self.bookends.positions = util.tableDeepCopy(snap.positions)
        self.bookends.defaults  = util.tableDeepCopy(snap.defaults)
        self.bookends:setActivePresetFilename(snap.active_filename)
    end
    self.bookends._previewing = false
    self.previewing = nil
    if self.modal_widget then
        UIManager:close(self.modal_widget)
        self.modal_widget = nil
    end
    self.bookends:markDirty()
end

function PresetManagerModal._previewLocal(self, entry)
    self.bookends._previewing = true
    local ok = pcall(self.bookends.loadPreset, self.bookends, entry.preset)
    if not ok then
        Notification:notify(_("Could not preview preset"))
        self.bookends._previewing = false
        return
    end
    self.previewing = { kind = "local", name = entry.name, filename = entry.filename, data = entry.preset }
    self.bookends:markDirty()
    self.rebuild()
end

function PresetManagerModal._previewBlank(self)
    self.bookends._previewing = true
    for _, pos in pairs(self.bookends.positions) do pos.lines = {} end
    self.previewing = { kind = "blank", name = _("(No overlay)") }
    self.bookends:markDirty()
    self.rebuild()
end

function PresetManagerModal._applyCurrent(self)
    if not self.previewing then return end
    if self.previewing.kind == "local" then
        self.bookends:setActivePresetFilename(self.previewing.filename)
    elseif self.previewing.kind == "blank" then
        self.bookends:setActivePresetFilename(nil)
    end
    self.bookends._previewing = false
    self.previewing = nil
    if self.modal_widget then
        UIManager:close(self.modal_widget)
        self.modal_widget = nil
    end
    self.bookends:markDirty()
end

function PresetManagerModal._toggleStar(self, entry_key)
    local cycle = self.bookends.settings:readSetting("preset_cycle") or {}
    local found_idx
    for i, f in ipairs(cycle) do if f == entry_key then found_idx = i; break end end
    if found_idx then
        table.remove(cycle, found_idx)
    else
        table.insert(cycle, entry_key)
    end
    self.bookends.settings:saveSetting("preset_cycle", cycle)
    self.rebuild()
end

local function isStarred(bookends, key)
    local cycle = bookends.settings:readSetting("preset_cycle") or {}
    for _, f in ipairs(cycle) do if f == key then return true end end
    return false
end

function PresetManagerModal._rebuild(self)
    if self.modal_widget then
        UIManager:close(self.modal_widget)
        self.modal_widget = nil
    end

    local width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
    local row_height = Screen:scaleBySize(42)
    local font_size = 18
    local baseline = math.floor(row_height * 0.65)
    local left_pad = Size.padding.large

    local vg = VerticalGroup:new{ align = "left" }

    -- Title + tab switcher
    local title_face = Font:getFace("infofont", 20)
    local title = TextWidget:new{
        text = _("Preset Manager"),
        face = title_face,
        bold = true,
        forced_height = row_height,
        forced_baseline = baseline,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local tabs_text = "[" .. (self.tab == "local" and _("Local") or " " .. _("Local") .. " ") .. "] [" ..
                      (self.tab == "gallery" and _("Gallery") or " " .. _("Gallery") .. " ") .. "]"
    local tabs = TextWidget:new{
        text = tabs_text,
        face = Font:getFace("infofont", 16),
        forced_height = row_height,
        forced_baseline = baseline,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local tabs_ic = InputContainer:new{
        dimen = Geom:new{ w = tabs:getWidth(), h = row_height },
        tabs,
    }
    tabs_ic.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = tabs_ic.dimen } },
    }
    tabs_ic.onTapSelect = function()
        self.setTab(self.tab == "local" and "gallery" or "local")
        return true
    end

    table.insert(vg, LeftContainer:new{
        dimen = Geom:new{ w = width, h = row_height },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = left_pad },
            title,
            HorizontalSpan:new{ width = Screen:scaleBySize(20) },
            tabs_ic,
        },
    })
    table.insert(vg, LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = width, h = Size.line.thick },
    })

    -- State header
    local active_fn = self.bookends:getActivePresetFilename()
    local active_name = _("(No overlay)")
    if active_fn then
        local presets = self.bookends:readPresetFiles()
        for _, p in ipairs(presets) do
            if p.filename == active_fn then active_name = p.name; break end
        end
    end
    local state_line = T(_("Currently editing: %1"), active_name)
    if self.previewing then
        state_line = state_line .. "  //  " .. T(_("Previewing: %1"), self.previewing.name)
    end
    table.insert(vg, LeftContainer:new{
        dimen = Geom:new{ w = width, h = row_height },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = left_pad },
            TextWidget:new{
                text = state_line,
                face = Font:getFace("cfont", 14),
                forced_height = row_height,
                forced_baseline = baseline,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
    })

    -- Body
    if self.tab == "local" then
        PresetManagerModal._renderLocalRows(self, vg, width, row_height, font_size, baseline, left_pad)
    else
        table.insert(vg, LeftContainer:new{
            dimen = Geom:new{ w = width, h = row_height * 3 },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = left_pad },
                TextWidget:new{
                    text = _("Gallery — coming soon"),
                    face = Font:getFace("infofont", 16),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
            },
        })
    end

    -- Footer buttons
    local btn_close = TextWidget:new{
        text = _("Close"),
        face = Font:getFace("infofont", 16),
        forced_height = row_height,
        forced_baseline = baseline,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local btn_close_ic = InputContainer:new{
        dimen = Geom:new{ w = math.floor(width / 2), h = row_height },
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor(width / 2), h = row_height },
            btn_close,
        },
    }
    btn_close_ic.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = btn_close_ic.dimen } },
    }
    btn_close_ic.onTapSelect = function() self.close(true); return true end

    local apply_text = _("Apply")
    if self.previewing and self.previewing.kind == "gallery" then
        apply_text = _("Install")
    end
    local btn_apply = TextWidget:new{
        text = apply_text,
        face = Font:getFace("infofont", 16),
        forced_height = row_height,
        forced_baseline = baseline,
        bold = true,
        fgcolor = self.previewing and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
    }
    local btn_apply_ic = InputContainer:new{
        dimen = Geom:new{ w = math.floor(width / 2), h = row_height },
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor(width / 2), h = row_height },
            btn_apply,
        },
    }
    btn_apply_ic.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = btn_apply_ic.dimen } },
    }
    btn_apply_ic.onTapSelect = function()
        if self.previewing then self.applyCurrent() end
        return true
    end

    table.insert(vg, LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = width, h = Size.line.thick },
    })
    table.insert(vg, HorizontalGroup:new{ btn_close_ic, btn_apply_ic })

    -- Outer frame + center
    local frame = FrameContainer:new{
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        vg,
    }
    local wc = CenterContainer:new{
        dimen = Screen:getSize(),
        frame,
    }
    self.modal_widget = wc
    UIManager:show(wc)
end

function PresetManagerModal._renderLocalRows(self, vg, width, row_height, font_size, baseline, left_pad)
    -- "+ Save current as preset"
    local plus = TextWidget:new{
        text = "+ " .. _("Save current as preset"),
        face = Font:getFace("infofont", 16),
        forced_height = row_height,
        forced_baseline = baseline,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local plus_ic = InputContainer:new{
        dimen = Geom:new{ w = width, h = row_height },
        HorizontalGroup:new{ HorizontalSpan:new{ width = left_pad }, plus },
    }
    plus_ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = plus_ic.dimen } } }
    plus_ic.onTapSelect = function() PresetManagerModal._saveCurrentAsPreset(self); return true end
    table.insert(vg, plus_ic)

    -- Virtual "(No overlay)" row
    PresetManagerModal._addRow(self, vg, width, row_height, font_size, baseline, left_pad, {
        display = _("(No overlay)"),
        star_key = "_empty",
        on_preview = function() self.previewBlank() end,
    })

    -- Real presets
    local presets = self.bookends:readPresetFiles()
    for _, p in ipairs(presets) do
        local by = p.preset.author and (" — " .. p.preset.author) or ""
        PresetManagerModal._addRow(self, vg, width, row_height, font_size, baseline, left_pad, {
            display = p.name .. by,
            star_key = p.filename,
            on_preview = function() self.previewLocal(p) end,
        })
    end
end

function PresetManagerModal._addRow(self, vg, width, row_height, font_size, baseline, left_pad, opts)
    local starred = isStarred(self.bookends, opts.star_key)
    local star_widget = TextWidget:new{
        text = starred and "\xE2\x98\x85" or "\xE2\x98\x86",
        face = Font:getFace("infofont", 18),
        forced_height = row_height,
        forced_baseline = baseline,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local star_width = Screen:scaleBySize(40)
    local star_ic = InputContainer:new{
        dimen = Geom:new{ w = star_width, h = row_height },
        CenterContainer:new{ dimen = Geom:new{ w = star_width, h = row_height }, star_widget },
    }
    star_ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = star_ic.dimen } } }
    local key = opts.star_key
    star_ic.onTapSelect = function() self.toggleStar(key); return true end

    local name_widget = TextWidget:new{
        text = opts.display,
        face = Font:getFace("cfont", font_size),
        forced_height = row_height,
        forced_baseline = baseline,
        max_width = width - 2 * left_pad - star_width,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local name_ic = InputContainer:new{
        dimen = Geom:new{ w = width - 2 * left_pad - star_width, h = row_height },
        name_widget,
    }
    name_ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = name_ic.dimen } } }
    name_ic.onTapSelect = function() opts.on_preview(); return true end

    table.insert(vg, HorizontalGroup:new{
        HorizontalSpan:new{ width = left_pad },
        star_ic,
        name_ic,
    })
end

function PresetManagerModal._saveCurrentAsPreset(self)
    local dlg
    dlg = InputDialog:new{
        title = _("Save preset"),
        input = "",
        input_hint = _("Preset name"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = dlg:getInputText()
                if name and name ~= "" then
                    local preset = self.bookends:buildPreset()
                    preset.name = name
                    local filename = self.bookends:writePresetFile(name, preset)
                    self.bookends:setActivePresetFilename(filename)
                    local cycle = self.bookends.settings:readSetting("preset_cycle") or {}
                    table.insert(cycle, filename)
                    self.bookends.settings:saveSetting("preset_cycle", cycle)
                end
                UIManager:close(dlg)
                self.rebuild()
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

return PresetManagerModal
