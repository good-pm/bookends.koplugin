# footertext.koplugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone KOReader plugin that renders a configurable format-string label (default "Page %c") centered at the bottom of the reading screen, independent of but aware of the status bar.

**Architecture:** A `WidgetContainer` plugin registered as a ReaderView view module. Uses `BottomContainer` + `CenterContainer` + `TextWidget` to render centered text at the screen bottom. Repositions vertically based on status bar visibility. Token expansion is self-contained within the plugin.

**Tech Stack:** Lua, KOReader widget framework (`TextWidget`, `BottomContainer`, `CenterContainer`), `G_reader_settings` for persistence.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `plugins/footertext.koplugin/_meta.lua` | Plugin metadata (name, description) |
| `plugins/footertext.koplugin/main.lua` | Plugin class: init, settings, token expansion, widget tree, event handlers, menu, painting |

---

### Task 1: Create plugin skeleton with metadata

**Files:**
- Create: `plugins/footertext.koplugin/_meta.lua`
- Create: `plugins/footertext.koplugin/main.lua`

- [ ] **Step 1: Create _meta.lua**

```lua
local _ = require("gettext")
return {
    name = "footertext",
    fullname = _("Footer text"),
    description = _([[Display a configurable text label centered at the bottom of the reading screen, independent of the status bar.]]),
}
```

- [ ] **Step 2: Create main.lua with plugin skeleton**

```lua
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
```

- [ ] **Step 3: Commit**

```bash
git add plugins/footertext.koplugin/_meta.lua plugins/footertext.koplugin/main.lua
git commit -m "feat(footertext): add plugin skeleton with widget tree and settings"
```

---

### Task 2: Implement token expansion

**Files:**
- Modify: `plugins/footertext.koplugin/main.lua`

- [ ] **Step 1: Add the expandTokens function**

Add this function to `main.lua`, after `loadSettings` and before `buildWidget`:

```lua
function FooterText:expandTokens(format_str)
    if not format_str:find("%%") then
        return format_str
    end

    local pageno = self.ui.view.state.page
    local doc = self.ui.document

    -- %c - current page (respects pagemap and hidden flows)
    local currentpage
    if self.ui.pagemap and self.ui.pagemap:wantsPageLabels() then
        currentpage = self.ui.pagemap:getCurrentPageLabel(true) or "N/A"
    elseif pageno and doc:hasHiddenFlows() then
        currentpage = doc:getPageNumberInFlow(pageno)
    else
        currentpage = pageno or 0
    end

    -- %t - total pages (respects hidden flows)
    local totalpages
    if self.ui.pagemap and self.ui.pagemap:wantsPageLabels() then
        totalpages = self.ui.pagemap:getLastPageLabel(true) or "N/A"
    elseif pageno and doc:hasHiddenFlows() then
        local flow = doc:getPageFlow(pageno)
        totalpages = doc:getTotalPagesInFlow(flow)
    else
        totalpages = doc:getPageCount()
    end

    -- %p - percentage
    local percent
    if type(currentpage) == "number" and type(totalpages) == "number" and totalpages > 0 then
        percent = math.floor(currentpage / totalpages * 100)
    else
        percent = 0
    end

    -- %T, %A, %S - document metadata
    local props = doc:getProps()
    local title = props.display_title or "N/A"
    local authors = props.authors or "N/A"
    local series = props.series or "N/A"
    if series ~= "N/A" and props.series_index then
        series = series .. " #" .. props.series_index
    end

    -- %h - time left in chapter, %H - time left in document
    local time_left_chapter = "N/A"
    local time_left_doc = "N/A"
    local avg_time = self.ui.view.footer:getAvgTimePerPage()
    if avg_time and avg_time == avg_time and pageno then
        local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
        local datetime = require("datetime")
        local chapter_pages_left = self.ui.toc:getChapterPagesLeft(pageno)
            or doc:getTotalPagesLeft(pageno)
        time_left_chapter = datetime.secondsToClockDuration(
            user_duration_format, chapter_pages_left * avg_time, true)
        local doc_pages_left = doc:getTotalPagesLeft(pageno)
        time_left_doc = datetime.secondsToClockDuration(
            user_duration_format, doc_pages_left * avg_time, true)
    end

    -- %b, %B - battery
    local powerd = Device:getPowerDevice()
    local batt_lvl = powerd:getCapacity() or "N/A"
    local batt_symbol = powerd:getBatterySymbol(
        powerd:isCharged(), powerd:isCharging(), batt_lvl) or "N/A"

    local replace = {
        ["%%T"] = tostring(title),
        ["%%A"] = tostring(authors),
        ["%%S"] = tostring(series),
        ["%%c"] = tostring(currentpage),
        ["%%t"] = tostring(totalpages),
        ["%%p"] = tostring(percent),
        ["%%h"] = tostring(time_left_chapter),
        ["%%H"] = tostring(time_left_doc),
        ["%%b"] = tostring(batt_lvl),
        ["%%B"] = tostring(batt_symbol),
    }
    return format_str:gsub("(%%%a)", replace)
end
```

- [ ] **Step 2: Add the updateText function**

Add after `expandTokens`:

```lua
function FooterText:updateText()
    local new_text = self:expandTokens(self.format)
    if new_text ~= self.current_text then
        self.current_text = new_text
        self.text_widget:setText(new_text)
        -- Update center container width to match new text size
        self.center_container.dimen.h = self.text_widget:getSize().h
    end
end
```

- [ ] **Step 3: Commit**

```bash
git add plugins/footertext.koplugin/main.lua
git commit -m "feat(footertext): implement format token expansion"
```

---

### Task 3: Implement positioning and event handlers

**Files:**
- Modify: `plugins/footertext.koplugin/main.lua`

- [ ] **Step 1: Add updatePosition function**

Add after `updateText`:

```lua
function FooterText:updatePosition()
    local screen_size = Screen:getSize()
    local footer_height = 0
    if self.ui.view.footer_visible then
        footer_height = self.ui.view.footer:getHeight()
    end
    self.bottom_container.dimen.w = screen_size.w
    self.bottom_container.dimen.h = screen_size.h - footer_height - self.vertical_offset
    self.center_container.dimen.w = screen_size.w
end
```

- [ ] **Step 2: Add event handlers**

Add after `updatePosition`:

```lua
function FooterText:onPageUpdate(pageno)
    if self.enabled then
        UIManager:setDirty(self.ui, "ui")
    end
end

function FooterText:onPosUpdate(pos)
    if self.enabled then
        UIManager:setDirty(self.ui, "ui")
    end
end

function FooterText:onReaderFooterVisibilityChange()
    if self.enabled then
        UIManager:setDirty(self.ui, "ui")
    end
end

function FooterText:onSetDimensions(dimen)
    if self.enabled then
        UIManager:setDirty(self.ui, "ui")
    end
end
```

- [ ] **Step 3: Commit**

```bash
git add plugins/footertext.koplugin/main.lua
git commit -m "feat(footertext): add positioning logic and event handlers"
```

---

### Task 4: Implement menu integration

**Files:**
- Modify: `plugins/footertext.koplugin/main.lua`

- [ ] **Step 1: Add required imports for menu widgets**

Add to the imports at the top of `main.lua`:

```lua
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
```

- [ ] **Step 2: Implement addToMainMenu**

Replace the placeholder `addToMainMenu` with:

```lua
function FooterText:addToMainMenu(menu_items)
    menu_items.footer_text = {
        text = _("Footer text"),
        sub_item_table = {
            {
                text = _("Enable footer text"),
                checked_func = function()
                    return self.enabled
                end,
                callback = function()
                    self.enabled = not self.enabled
                    if self.enabled then
                        G_reader_settings:makeTrue("footertext_enabled")
                    else
                        G_reader_settings:makeFalse("footertext_enabled")
                    end
                    UIManager:setDirty(self.ui, "ui")
                end,
            },
            {
                text = _("Edit format string"),
                keep_menu_open = true,
                enabled_func = function()
                    return self.enabled
                end,
                callback = function()
                    self:editFormatString()
                end,
            },
            {
                text = _("Font size"),
                keep_menu_open = true,
                enabled_func = function()
                    return self.enabled
                end,
                callback = function()
                    self:editFontSize()
                end,
            },
            {
                text = _("Vertical offset"),
                keep_menu_open = true,
                enabled_func = function()
                    return self.enabled
                end,
                callback = function()
                    self:editVerticalOffset()
                end,
            },
        },
    }
end
```

- [ ] **Step 3: Implement editFormatString**

Add after `addToMainMenu`:

```lua
function FooterText:editFormatString()
    local format_dialog
    format_dialog = InputDialog:new{
        title = _("Footer text format string"),
        input = self.format,
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
                    text = _("Info"),
                    callback = function()
                        UIManager:show(InfoMessage:new{
                            text = _([[
Available tokens:
%T  title
%A  author(s)
%S  series
%c  current page number
%t  total page number
%p  percentage read
%h  time left in chapter
%H  time left in document
%b  battery level
%B  battery symbol]]),
                        })
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        self.format = format_dialog:getInputText()
                        G_reader_settings:saveSetting("footertext_format", self.format)
                        UIManager:close(format_dialog)
                        UIManager:setDirty(self.ui, "ui")
                    end,
                },
            },
        },
    }
    UIManager:show(format_dialog)
    format_dialog:onShowKeyboard()
end
```

- [ ] **Step 4: Implement editFontSize**

Add after `editFormatString`:

```lua
function FooterText:editFontSize()
    local spin = SpinWidget:new{
        value = self.font_size,
        value_min = 8,
        value_max = 36,
        default_value = self.ui.view.footer.settings.text_font_size,
        title_text = _("Footer text font size"),
        ok_text = _("Set"),
        callback = function(spin)
            self.font_size = spin.value
            G_reader_settings:saveSetting("footertext_font_size", self.font_size)
            self:rebuildWidget()
        end,
    }
    UIManager:show(spin)
end
```

- [ ] **Step 5: Implement editVerticalOffset**

Add after `editFontSize`:

```lua
function FooterText:editVerticalOffset()
    local spin = SpinWidget:new{
        value = self.vertical_offset,
        value_min = -100,
        value_max = 100,
        default_value = 0,
        title_text = _("Vertical offset (pixels up)"),
        ok_text = _("Set"),
        callback = function(spin)
            self.vertical_offset = spin.value
            G_reader_settings:saveSetting("footertext_vertical_offset", self.vertical_offset)
            UIManager:setDirty(self.ui, "ui")
        end,
    }
    UIManager:show(spin)
end
```

- [ ] **Step 6: Add rebuildWidget function**

Add after `buildWidget`:

```lua
function FooterText:rebuildWidget()
    if self.text_widget then
        self.text_widget:free()
    end
    self:buildWidget()
    UIManager:setDirty(self.ui, "ui")
end
```

- [ ] **Step 7: Commit**

```bash
git add plugins/footertext.koplugin/main.lua
git commit -m "feat(footertext): add menu integration with format editor, font size, and offset"
```

---

### Task 5: Update README and final review

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add plugin to README table**

In the Plugins table in `README.md`, add a new row after the existing `displaymodehomefolder.koplugin` entry:

```markdown
| [footertext.koplugin](plugins/footertext.koplugin) | Display a configurable text label centered at the bottom of the reading screen, independent of the status bar. Default: "Page 28". Uses the same format tokens as the sleep screen message (`%c`, `%t`, `%T`, etc.). |
```

- [ ] **Step 2: Test on device**

Install the plugin by copying `plugins/footertext.koplugin/` to the device's KOReader `plugins/` directory. Verify:

1. Plugin loads without errors (check `crash.log` if issues)
2. "Page X" displays centered at bottom when reading an EPUB
3. Label updates on page turn
4. Label stays visible when status bar is hidden (long-press bottom)
5. Label repositions when status bar toggles
6. Menu items work: enable/disable, format string, font size, vertical offset
7. Format tokens expand correctly (try `"Page %c of %t"`, `"%T — %p%%"`)
8. Settings persist across KOReader restarts

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add footertext plugin to README"
```
