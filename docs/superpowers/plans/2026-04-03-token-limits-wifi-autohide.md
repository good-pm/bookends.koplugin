# Token Pixel Limits, Wifi Auto-Hide & line_bar_width Cleanup

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `%X[N]` per-token pixel width limits with ellipsis truncation, make `%W` auto-hide when wifi is disabled, and remove orphaned `line_bar_width` plumbing.

**Architecture:** Marker-based post-processing. `tokens.lua` parses `%X[N]` syntax and wraps resolved values with control-character markers (`\x01N\x02value\x03`). A new `applyTokenLimits()` function in `overlay_widget.lua` processes markers using font metrics for UTF-8-safe pixel truncation. `main.lua` calls this between font resolution and widget building. Bar width uses `bar_info.width` instead of per-line `cfg.bar_width`.

**Tech Stack:** Lua, KOReader widget framework (TextWidget, util.splitToChars)

---

### Task 1: Wifi auto-hide (tokens.lua)

**Files:**
- Modify: `tokens.lua:364-372`

This is the simplest change — a self-contained 3-state wifi resolution.

- [ ] **Step 1: Update wifi resolution to three states**

In `tokens.lua`, replace the wifi block (lines 364-372):

```lua
    -- Wi-Fi
    local wifi_symbol = ""
    if needs("W") then
        local NetworkMgr = require("ui/network/manager")
        if NetworkMgr:isWifiOn() then
            if NetworkMgr:isConnected() then
                wifi_symbol = "\xEE\xB2\xA8" -- U+ECA8 wifi connected
            else
                wifi_symbol = "\xEE\xB2\xA9" -- U+ECA9 wifi enabled, not connected
            end
        -- else: wifi disabled, leave as "" (hidden)
        end
    end
```

- [ ] **Step 2: Verify syntax with luac**

Run: `luac -p tokens.lua`
Expected: no output (clean parse)

- [ ] **Step 3: Deploy to Kindle and test**

```bash
scp tokens.lua kindle:/mnt/us/koreader/plugins/bookends.koplugin/
```

Test on device:
1. With wifi off: `%W` icon should not appear, line with only `%W` should auto-hide
2. Toggle wifi on (but not connected): disconnected icon should appear
3. Connect wifi: connected icon should appear

- [ ] **Step 4: Commit**

```bash
git add tokens.lua
git commit -m "feat: auto-hide wifi icon when wifi is disabled (#6)"
```

---

### Task 2: Parse `%X[N]` syntax in tokens.lua

**Files:**
- Modify: `tokens.lua:35-66` (expand function top), `tokens.lua:438-503` (bar placeholder + gsub)

Add pre-parsing of `[N]` modifiers and marker wrapping during token replacement.

- [ ] **Step 1: Add pre-parse for `%X[N]` and `%bar[N]` at the top of `Tokens.expand()`**

After the fast-path check (line 38) and before preview mode (line 42), add a pre-parse phase. This extracts limits, strips `[N]` from the format string, and stores bar width separately.

Insert after line 38 (`return format_str` / `end`):

```lua
    -- Pre-parse %X[N] pixel-width modifiers.
    -- Builds a table of per-occurrence limits keyed by a running counter per token,
    -- and strips [N] from the format string so existing expansion works unchanged.
    local token_limits = {}  -- { ["%C"] = { [1] = 200 }, ["%T"] = { [1] = 300 } }
    local bar_limit_w = nil  -- pixel width for %bar[N], stored separately
    local has_limits = format_str:find("%[%d+%]")
    if has_limits then
        -- Extract %bar[N] first (before single-char tokens, to avoid %b matching)
        format_str = format_str:gsub("%%bar%[(%d+)%]", function(n)
            local px = tonumber(n)
            if px and px > 0 then
                bar_limit_w = px
            end
            return "%%bar"
        end)
        -- Extract %X[N] for single-char tokens
        format_str = format_str:gsub("(%%%a)%[(%d+)%]", function(token, n)
            local px = tonumber(n)
            if px and px > 0 then
                if not token_limits[token] then
                    token_limits[token] = {}
                end
                table.insert(token_limits[token], px)
            end
            return token
        end)
    end
```

- [ ] **Step 2: Update preview mode to show limits**

Replace the preview gsub section (lines 63-65) to handle `[N]` in preview:

```lua
    -- Preview mode: return descriptive labels
    if preview_mode then
        local preview = {
            ["%c"] = "[page]", ["%t"] = "[total]", ["%p"] = "[%]",
            ["%P"] = "[ch%]", ["%g"] = "[ch.read]", ["%G"] = "[ch.total]",
            ["%l"] = "[ch.left]", ["%L"] = "[left]",
            ["%h"] = "[ch.time]", ["%H"] = "[time]",
            ["%k"] = "[12h]", ["%K"] = "[24h]",
            ["%d"] = "[date]", ["%D"] = "[date.long]",
            ["%n"] = "[dd/mm/yy]", ["%w"] = "[weekday]", ["%a"] = "[wkday]",
            ["%R"] = "[session]", ["%s"] = "[pages]",
            ["%T"] = "[title]", ["%A"] = "[author]",
            ["%S"] = "[series]", ["%C"] = "[chapter]",
            ["%N"] = "[file]", ["%i"] = "[lang]",
            ["%o"] = "[format]", ["%q"] = "[highlights]", ["%Q"] = "[notes]", ["%x"] = "[bookmarks]",
            ["%r"] = "[pg/hr]", ["%E"] = "[total]",
            ["%b"] = "[batt]", ["%B"] = "[batt]", ["%W"] = "[wifi]",
            ["%f"] = "[light]", ["%F"] = "[warmth]",
            ["%m"] = "[mem]", ["%M"] = "[rss]",
            ["%v"] = "[disk]",
            ["%bar"] = "\xE2\x96\xB0\xE2\x96\xB0\xE2\x96\xB1\xE2\x96\xB1",  -- ▰▰▱▱
        }
        -- Strip %bar[N] and %X[N] for preview, showing limit in label
        local r = format_str:gsub("%%bar%[(%d+)%]", preview["%bar"])
        r = r:gsub("%%bar", preview["%bar"])
        r = r:gsub("(%%%a)%[(%d+)%]", function(token, n)
            local label = preview[token]
            if label then
                -- Turn [chapter] into [chapter<=200]
                return label:sub(1, -2) .. "<=" .. n .. "]"
            end
            return token .. "[" .. n .. "]"
        end)
        r = r:gsub("(%%%a)", preview)
        return r
    end
```

- [ ] **Step 3: Wrap limited token values with markers during gsub**

Replace the gsub block (lines 492-503) with marker-aware version:

```lua
    -- Track whether all tokens in the string resolved to empty or "0"
    local has_token = false
    local all_empty = true
    -- Per-token occurrence counters for matching limits
    local token_occurrence = {}
    local result = result_str:gsub("(%%%a)", function(token)
        local val = replace[token]
        if val == nil then return token end -- unknown token, leave as-is
        has_token = true
        if val ~= "" and val ~= "0" then
            all_empty = false
        end
        -- Wrap with markers if this occurrence has a pixel limit
        if token_limits[token] then
            token_occurrence[token] = (token_occurrence[token] or 0) + 1
            local px = token_limits[token][token_occurrence[token]]
            if px then
                -- \x01 N \x02 value \x03
                return "\x01" .. tostring(px) .. "\x02" .. val .. "\x03"
            end
        end
        return val
    end)
```

- [ ] **Step 4: Pass bar_limit_w through bar_info**

After the bar_info construction (after line 211, where `bar_info.chapter = ...`), add:

```lua
        if bar_limit_w then
            bar_info.width = bar_limit_w
        end
```

- [ ] **Step 5: Verify syntax**

Run: `luac -p tokens.lua`
Expected: no output (clean parse)

- [ ] **Step 6: Commit**

```bash
git add tokens.lua
git commit -m "feat: parse %X[N] pixel-width modifiers in token expansion (#6)"
```

---

### Task 3: Implement `applyTokenLimits()` in overlay_widget.lua

**Files:**
- Modify: `overlay_widget.lua` (add new function after line 342, before `calculateRowLimits`)

- [ ] **Step 1: Add the `applyTokenLimits` function**

Insert after the `measureTextWidth` function (after line 342):

```lua
--- Apply per-token pixel-width limits encoded as \x01N\x02value\x03 markers.
-- Measures each marked value with the given font; if wider than N pixels,
-- truncates to the longest UTF-8 prefix that fits and appends "...".
-- @param text string: text potentially containing markers
-- @param face table: font face for measurement
-- @param bold boolean: bold flag for measurement
-- @param uppercase boolean: whether text will be rendered uppercase
-- @return string: text with markers replaced by (possibly truncated) values
function OverlayWidget.applyTokenLimits(text, face, bold, uppercase)
    if not text:find("\x01") then return text end
    local util = require("util")
    return text:gsub("\x01(%d+)\x02(.-)\x03", function(limit_str, value)
        local max_px = tonumber(limit_str)
        if not max_px or max_px <= 0 or value == "" then return value end
        local display = uppercase and value:upper() or value
        -- Measure full value
        local tw = TextWidget:new(textWidgetOpts{
            text = display, face = face, bold = bold,
        })
        local w = tw:getSize().w
        tw:free()
        if w <= max_px then return value end
        -- Need to truncate — measure ellipsis width
        local ellipsis = "\xE2\x80\xA6" -- U+2026 …
        local ew = TextWidget:new(textWidgetOpts{
            text = ellipsis, face = face, bold = bold,
        })
        local ellipsis_w = ew:getSize().w
        ew:free()
        local target_px = max_px - ellipsis_w
        if target_px <= 0 then return ellipsis end
        -- Split into UTF-8 characters and binary search for max fitting prefix
        local chars = util.splitToChars(display)
        local lo, hi = 0, #chars
        while lo < hi do
            local mid = math.ceil((lo + hi) / 2)
            local sub = table.concat(chars, "", 1, mid)
            local stw = TextWidget:new(textWidgetOpts{
                text = sub, face = face, bold = bold,
            })
            local sw = stw:getSize().w
            stw:free()
            if sw <= target_px then
                lo = mid
            else
                hi = mid - 1
            end
        end
        if lo == 0 then return ellipsis end
        -- If uppercase was applied for measurement, we need to return the
        -- original-case prefix (same char count) so buildTextWidget can
        -- apply uppercase again without double-transforming.
        local orig_chars = util.splitToChars(value)
        return table.concat(orig_chars, "", 1, lo) .. ellipsis
    end)
end
```

- [ ] **Step 2: Verify syntax**

Run: `luac -p overlay_widget.lua`
Expected: no output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add overlay_widget.lua
git commit -m "feat: add applyTokenLimits() for per-token pixel truncation (#6)"
```

---

### Task 4: Integrate token limits into main.lua rendering pipeline

**Files:**
- Modify: `main.lua:786-797` (between Phase 2 font resolution and widget building)

- [ ] **Step 1: Apply token limits per-line after font resolution**

In the Phase 2 loop, after `line_configs` is fully built (after line 784 `table.insert(line_configs, cfg)`) and before the widget is built (line 794), add token limit processing.

Replace lines 792-796 (the comment and widget build):

```lua
        -- Apply per-token pixel limits (markers from tokens.lua) using resolved font.
        -- Must happen before widget building so text is clean.
        local limited_text = text
        if text:find("\x01") then
            local limited_lines = {}
            local li = 0
            for line in text:gmatch("([^\n]+)") do
                li = li + 1
                local cfg = line_configs[li] or line_configs[#line_configs]
                line = OverlayWidget.applyTokenLimits(line, cfg.face, cfg.bold, cfg.uppercase)
                table.insert(limited_lines, line)
            end
            limited_text = table.concat(limited_lines, "\n")
        end

        -- Build without truncation to measure natural text width.
        -- For bar positions, Phase 4 will rebuild with the correct row-aware available_w.
        local pos_available_w = screen_w
        local widget, w, h = OverlayWidget.buildTextWidget(limited_text, line_configs, pos_def.h_anchor, nil, pos_available_w)
        pre_built[key] = { widget = widget, w = w, h = h, line_configs = line_configs, pos_def = pos_def, text = limited_text }
```

Note: we store `limited_text` in `pre_built` so Phase 4 rebuilds use the truncated text too.

- [ ] **Step 2: Update Phase 3 and Phase 4 to use limited_text instead of expanded[key]**

There are three places after Phase 2 that reference `expanded[key]` for the text content. All must use `pb.text` (the marker-processed version) instead.

**Phase 3 — `getOverlapWidth` (around line 812-818):** Replace `expanded[key]` with `pb.text`:

```lua
        local function getOverlapWidth(key)
            local pb = pre_built[key]
            if not pb then return nil end
            if bar_data[key] then
                return OverlayWidget.measureTextWidth(pb.text, pb.line_configs)
            end
            return pb.w
        end
```

**Phase 4 — truncation rebuild (line 851):** Replace:
```lua
                    widget, w, h = OverlayWidget.buildTextWidget(
                        expanded[key], pb.line_configs, pb.pos_def.h_anchor, max_width, max_width)
```
with:
```lua
                    widget, w, h = OverlayWidget.buildTextWidget(
                        pb.text, pb.line_configs, pb.pos_def.h_anchor, max_width, max_width)
```

**Phase 4 — bar rebuild (line 902-903):** Replace:
```lua
                    widget, w, h = OverlayWidget.buildTextWidget(
                        expanded[key], pb.line_configs, pb.pos_def.h_anchor, nil, bar_avail)
```
with:
```lua
                    widget, w, h = OverlayWidget.buildTextWidget(
                        pb.text, pb.line_configs, pb.pos_def.h_anchor, nil, bar_avail)
```

- [ ] **Step 3: Verify syntax**

Run: `luac -p main.lua`
Expected: no output (clean parse)

- [ ] **Step 4: Deploy and test on Kindle**

```bash
scp tokens.lua overlay_widget.lua main.lua kindle:/mnt/us/koreader/plugins/bookends.koplugin/
```

Test cases:
1. Set a line to `%C[200] - %g/%G` — chapter title should truncate with "..." if wider than 200px
2. Set a line to `%T[100]` — very short limit, title should show just a few chars + "..."
3. Set a line to `%C[0]` — should behave as no limit (full text)
4. Set a line to `%C[200]` with a short chapter name — no truncation, no ellipsis
5. Verify preview mode shows `[chapter<=200]` style labels
6. Verify normal tokens without `[N]` still work exactly as before

- [ ] **Step 5: Commit**

```bash
git add main.lua
git commit -m "feat: integrate per-token pixel limits into rendering pipeline (#6)"
```

---

### Task 5: Wire `%bar[N]` width through buildBarLine

**Files:**
- Modify: `overlay_widget.lua:168` (buildBarLine bar_manual_w)
- Modify: `main.lua:758-783` (propagate bar_info.width into cfg.bar)

**Data flow context:** `tokens.lua` sets `bar_info.width = N` on the top-level `bar_info` table. In main.lua Phase 2, `all_bars` is that `bar_info`. But `cfg.bar` is assigned from a sub-table (`all_bars.book` or `all_bars.chapter`), not from `all_bars` directly. So `all_bars.width` must be copied onto `cfg.bar` after assignment.

- [ ] **Step 1: Propagate bar_info.width to cfg.bar in main.lua Phase 2**

In main.lua, after `cfg.bar` is assigned (the block at lines 758-783), add width propagation. After line 778 (`cfg.bar = all_bars.chapter`), but before line 779 (`cfg.bar_height = ...`), the existing `cfg.bar_width` line (780) will be replaced in Task 6. For now, add after the bar type selection block (after the `else` / `end` that closes the bar_type branches):

After the `end` that closes `if bar_type == "book_ticks_all"` (after line 778), before `cfg.bar_height` (line 779), add:

```lua
                if all_bars.width then
                    cfg.bar.width = all_bars.width
                end
```

- [ ] **Step 2: Update buildBarLine to use bar_info.width**

In `overlay_widget.lua`, replace line 168:

```lua
    local bar_manual_w = cfg.bar_width or 0
```

with:

```lua
    local bar_manual_w = (bar_info and bar_info.width) or 0
```

This reads `width` from `bar_info` (which is `cfg.bar` — the local assigned on line 130).

- [ ] **Step 2: Verify syntax**

Run: `luac -p overlay_widget.lua`
Expected: no output (clean parse)

- [ ] **Step 3: Deploy and test bar width on Kindle**

```bash
scp tokens.lua overlay_widget.lua main.lua kindle:/mnt/us/koreader/plugins/bookends.koplugin/
```

Test cases:
1. `%bar[400]` — bar should be exactly 400px wide (or less if text takes up space)
2. `%p %bar[300] %P` — bar fixed at 300px between percentage tokens
3. `%bar` (no bracket) — bar should auto-fill as before
4. `%bar[0]` — should auto-fill (treated as no limit)

- [ ] **Step 4: Commit**

```bash
git add overlay_widget.lua
git commit -m "feat: support %bar[N] for inline bar width (#6)"
```

---

### Task 6: Remove orphaned `line_bar_width` plumbing

**Files:**
- Modify: `main.lua` (multiple locations)

- [ ] **Step 1: Remove cfg.bar_width from Phase 2 config building**

Delete line 780:
```lua
                cfg.bar_width = (pos_settings.line_bar_width and pos_settings.line_bar_width[i]) or nil
```

- [ ] **Step 2: Remove from line settings dialog**

Delete the initialization at line 1834:
```lua
    pos_settings.line_bar_width = pos_settings.line_bar_width or {}
```

Delete the snapshot at line 1849:
```lua
    local line_bar_width = pos_settings.line_bar_width[line_idx] -- nil/0 = auto-fill
```

Delete the applyLivePreview write-back at line 1863:
```lua
        pos_settings.line_bar_width[line_idx] = line_bar_width
```

- [ ] **Step 3: Remove from line deletion**

Delete from the first sparseRemove block (line 2174):
```lua
                        sparseRemove(pos_settings.line_bar_width, line_idx)
```

Delete from the `removeLine()` function (line 2231):
```lua
        sparseRemove(ps.line_bar_width, line_idx)
```

- [ ] **Step 4: Remove from swap logic**

Delete lines 2267-2269:
```lua
        if ps.line_bar_width then
            ps.line_bar_width[a], ps.line_bar_width[b] = ps.line_bar_width[b], ps.line_bar_width[a]
        end
```

- [ ] **Step 5: Remove from moveToRegion**

Delete line 2312:
```lua
        target.line_bar_width = target.line_bar_width or {}
```

Delete line 2326:
```lua
        target.line_bar_width[ti] = ps.line_bar_width and ps.line_bar_width[line_idx] or nil
```

- [ ] **Step 6: Verify syntax**

Run: `luac -p main.lua`
Expected: no output (clean parse)

- [ ] **Step 7: Deploy and verify no regressions**

```bash
scp main.lua kindle:/mnt/us/koreader/plugins/bookends.koplugin/
```

Test: open a book with existing bar lines configured. Bars should still render and auto-fill. Line editing, moving, swapping, deleting should all work without errors.

- [ ] **Step 8: Commit**

```bash
git add main.lua
git commit -m "refactor: remove orphaned line_bar_width plumbing"
```

---

### Task 7: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add token width limits documentation**

In the "Smart features" section (after the auto-hide bullet, around line 152), add a new bullet:

```markdown
- **Token width limits** — Append `[N]` to any token to cap its width at N pixels: `%C[200] - %g/%G` truncates the chapter title with ellipsis if it exceeds 200 pixels. Works with `%bar[N]` to set a fixed bar width instead of auto-fill.
```

- [ ] **Step 2: Update wifi token description**

In the Device tokens table (line 119), update the `%W` description:

```markdown
| `%W` | Wi-Fi icon (dynamic) | Hidden when off, changes when connected/disconnected |
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document token width limits and wifi auto-hide behaviour"
```
