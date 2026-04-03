# Inline Formatting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add BBCode-style inline formatting (`[b]`, `[i]`, `[u]`) within status bar lines, with a unified styled-line renderer that handles both text segments and progress bars, and refactor token width limits from `%X[N]` to `%X{N}`.

**Architecture:** A stack-based parser in `overlay_widget.lua` splits text into `{text, bold, italic, uppercase}` segments (including bar placeholder segments). A new `buildStyledLine()` function renders segments as TextWidgets assembled into a HorizontalRowWidget — replacing the separate `buildBarLine` path. Lines without tags or bars use the existing fast path. `findItalicVariant` moves from `main.lua` to `overlay_widget.lua` so inline italic segments can resolve font faces. Token width syntax changes from `[N]` to `{N}` to avoid ambiguity.

**Tech Stack:** Lua, KOReader widget framework (TextWidget, Font, HorizontalRowWidget, BarWidget)

---

## File Structure

| File | Responsibility |
|------|---------------|
| `tokens.lua` | `[N]` → `{N}` syntax refactor in pre-parse, preview, and has_limits guard |
| `overlay_widget.lua` | `parseStyledSegments()` parser, `buildStyledLine()` renderer, `findItalicVariant` moved here |
| `main.lua` | Pass `face_name`/`font_size` through line_configs, remove local `findItalicVariant`, update `resolveLineConfig` |
| `README.md` | Document inline formatting tags, update token width syntax |

---

### Task 1: Refactor token width syntax from `[N]` to `{N}`

**Files:**
- Modify: `tokens.lua:43-108`

- [ ] **Step 1: Update pre-parse patterns from `[N]` to `{N}`**

In `tokens.lua`, replace the pre-parse block (lines 43-69). Change all `[` `]` bracket patterns to `{` `}` curly brace patterns:

Replace:
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
            return "%bar"
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

With:
```lua
    -- Pre-parse %X{N} pixel-width modifiers.
    -- Builds a table of per-occurrence limits keyed by a running counter per token,
    -- and strips {N} from the format string so existing expansion works unchanged.
    local token_limits = {}  -- { ["%C"] = { [1] = 200 }, ["%T"] = { [1] = 300 } }
    local bar_limit_w = nil  -- pixel width for %bar{N}, stored separately
    local has_limits = format_str:find("{%d+}")
    if has_limits then
        -- Extract %bar{N} first (before single-char tokens, to avoid %b matching)
        format_str = format_str:gsub("%%bar{(%d+)}", function(n)
            local px = tonumber(n)
            if px and px > 0 then
                bar_limit_w = px
            end
            return "%bar"
        end)
        -- Extract %X{N} for single-char tokens
        format_str = format_str:gsub("(%%%a){(%d+)}", function(token, n)
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

- [ ] **Step 2: Update preview mode patterns from `[N]` to `{N}`**

Replace the preview gsub section (lines 93-106):

Replace:
```lua
        -- Strip %bar[N] and %X[N] for preview, showing limit in label
        -- %bar[N] must be replaced before %bar (longer pattern first)
        local r = orig_format_str:gsub("%%bar%[(%d+)%]", function(n)
            return preview["%bar"] .. "[<=" .. n .. "]"
        end)
        r = r:gsub("%%bar", preview["%bar"])
        r = r:gsub("(%%%a)%[(%d+)%]", function(token, n)
            local label = preview[token]
            if label then
                -- Turn [chapter] into [chapter<=200]
                return label:sub(1, -2) .. "<=" .. n .. "]"
            end
            return token .. "[" .. n .. "]"
        end)
```

With:
```lua
        -- Strip %bar{N} and %X{N} for preview, showing limit in label
        -- %bar{N} must be replaced before %bar (longer pattern first)
        local r = orig_format_str:gsub("%%bar{(%d+)}", function(n)
            return preview["%bar"] .. "{<=" .. n .. "}"
        end)
        r = r:gsub("%%bar", preview["%bar"])
        r = r:gsub("(%%%a){(%d+)}", function(token, n)
            local label = preview[token]
            if label then
                -- Turn [chapter] into {chapter<=200}
                return "{" .. label:sub(2, -2) .. "<=" .. n .. "}"
            end
            return token .. "{" .. n .. "}"
        end)
```

- [ ] **Step 3: Update README token width syntax**

In `README.md`, find line 152:
```markdown
- **Token width limits** — Append `[N]` to any token to cap its width at N pixels: `%C[200] - %g/%G` truncates the chapter title with ellipsis if it exceeds 200 pixels. Works with `%bar[N]` to set a fixed bar width instead of auto-fill.
```

Replace with:
```markdown
- **Token width limits** — Append `{N}` to any token to cap its width at N pixels: `%C{200} - %g/%G` truncates the chapter title with ellipsis if it exceeds 200 pixels. Works with `%bar{400}` to set a fixed bar width instead of auto-fill.
```

- [ ] **Step 4: Verify syntax**

Run: `luac -p tokens.lua`
Expected: no output (clean parse)

- [ ] **Step 5: Commit**

```bash
git add tokens.lua README.md
git commit -m "refactor: change token width syntax from %X[N] to %X{N} (#8)"
```

---

### Task 2: Move `findItalicVariant` to overlay_widget.lua

**Files:**
- Modify: `main.lua:386-439` (remove function), `main.lua:441-461` (update resolveLineConfig)
- Modify: `overlay_widget.lua` (add function)

The `findItalicVariant` function needs to be accessible from `overlay_widget.lua` for inline italic segments. Move it there and call it from main.lua via the module.

- [ ] **Step 1: Add `findItalicVariant` to overlay_widget.lua**

In `overlay_widget.lua`, after the `textWidgetOpts` function (after line 14) and before the `MultiLineWidget` definition (line 17), add:

```lua
-- Cache for italic font variant lookups (face_name -> italic_path or false)
local _italic_cache = {}

--- Find the italic variant of a font by searching for common naming patterns.
-- Searches installed fonts for variants matching patterns like Regular→Italic.
-- Results are cached per face_name.
-- @param face_name string: path/name of the base font
-- @return string or false: path to italic variant, or false if not found
function OverlayWidget.findItalicVariant(face_name)
    if _italic_cache[face_name] ~= nil then
        return _italic_cache[face_name] -- may be false (no variant found)
    end

    local ok, FontList = pcall(require, "fontlist")
    if not ok then
        _italic_cache[face_name] = false
        return false
    end
    local all_fonts = FontList:getFontList()

    -- Extract the directory and base name without extension
    local dir = face_name:match("^(.*/)") or ""
    local basename = face_name:match("([^/]+)$") or face_name
    local name_no_ext = (basename:gsub("%.[^.]+$", ""))

    -- Common patterns: "Regular" -> "Italic", "Bold" -> "BoldItalic",
    -- or just append "Italic" / "-Italic" / " Italic"
    local candidates = {}
    -- Replace Regular/regular with Italic/italic
    if name_no_ext:match("[Rr]egular") then
        table.insert(candidates, (name_no_ext:gsub("[Rr]egular", "Italic")))
        table.insert(candidates, (name_no_ext:gsub("[Rr]egular", "italic")))
    end
    -- Replace Bold with BoldItalic
    if name_no_ext:match("[Bb]old") and not name_no_ext:match("[Ii]talic") then
        table.insert(candidates, (name_no_ext:gsub("[Bb]old", "BoldItalic")))
        table.insert(candidates, (name_no_ext:gsub("[Bb]old", "Bolditalic")))
    end
    -- Append -Italic, Italic, _Italic, " Italic"
    table.insert(candidates, name_no_ext .. "-Italic")
    table.insert(candidates, name_no_ext .. "Italic")
    table.insert(candidates, name_no_ext .. " Italic")
    table.insert(candidates, name_no_ext .. "-italic")

    -- Search available fonts
    for _, candidate in ipairs(candidates) do
        local pattern = candidate:lower()
        for _, font_path in ipairs(all_fonts) do
            local font_name = font_path:match("([^/]+)$") or ""
            local font_no_ext = font_name:gsub("%.[^.]+$", "")
            if font_no_ext:lower() == pattern then
                _italic_cache[face_name] = font_path
                return font_path
            end
        end
    end

    _italic_cache[face_name] = false
    return false
end
```

- [ ] **Step 2: Update main.lua to use OverlayWidget.findItalicVariant**

In `main.lua`, the file already requires overlay_widget (check for this — if not, it's available via `local OverlayWidget = require("overlay_widget")` or similar). 

First, delete the local `_italic_cache` and `findItalicVariant` function from main.lua (lines ~384-439 — the cache variable and the entire function).

Then update `resolveLineConfig` (line 447, the call to `findItalicVariant`) to use `OverlayWidget.findItalicVariant`:

Replace:
```lua
        local italic = findItalicVariant(face_name)
```
With:
```lua
        local italic = OverlayWidget.findItalicVariant(face_name)
```

- [ ] **Step 3: Add `face_name` and `font_size` to line configs**

In `main.lua`, in the Phase 2 loop where `cfg` is built (around line 752), after `resolveLineConfig` returns `cfg`, add the raw face_name and scaled font_size so `buildStyledLine` can resolve inline italic faces:

After line 752 (`local cfg = self:resolveLineConfig(face_name, font_size, style)`), add:
```lua
            cfg.face_name = face_name
            cfg.font_size = math.max(1, math.floor(font_size * (self.defaults.font_scale or 100) / 100 + 0.5))
```

- [ ] **Step 4: Verify syntax**

Run: `luac -p main.lua && luac -p overlay_widget.lua`
Expected: no output (clean parse)

- [ ] **Step 5: Commit**

```bash
git add main.lua overlay_widget.lua
git commit -m "refactor: move findItalicVariant to overlay_widget for shared access (#8)"
```

---

### Task 3: Implement `parseStyledSegments()` parser

**Files:**
- Modify: `overlay_widget.lua` — add function after `applyTokenLimits` (after line ~403), before `calculateRowLimits`

- [ ] **Step 1: Add the parser function**

```lua
--- Parse BBCode-style formatting tags into styled text segments.
-- Supports [b], [i], [u] tags with proper nesting via a style stack.
-- Bar placeholder characters become special bar segments.
-- If tags are improperly nested or unclosed, returns the original text as a single segment.
-- @param text string: text potentially containing [b], [i], [u] tags and bar placeholder
-- @param base_bold boolean: base bold state from line config
-- @param base_italic boolean: base italic state from line config (true if line style is italic)
-- @param base_uppercase boolean: base uppercase state from line config
-- @return table: array of segments {text=, bold=, italic=, uppercase=} or {bar=true}
-- @return boolean: true if any tags were found and parsed
function OverlayWidget.parseStyledSegments(text, base_bold, base_italic, base_uppercase)
    -- Quick check: no tags present
    if not text:find("%[") then
        return nil, false
    end

    local segments = {}
    local stack = {}  -- style stack: each entry is "b", "i", or "u"
    local pos = 1
    local pending = ""  -- accumulates text between tags
    local found_tags = false

    -- Current style: base style when stack is empty, stack-derived when inside tags.
    -- Tags override base (not combine): [i] inside a Bold line = italic only.
    local function currentStyle()
        if #stack == 0 then
            return base_bold, base_italic, base_uppercase
        end
        local bold, italic, uppercase = false, false, false
        for _, tag in ipairs(stack) do
            if tag == "b" then bold = true
            elseif tag == "i" then italic = true
            elseif tag == "u" then uppercase = true
            end
        end
        return bold, italic, uppercase
    end

    local function flushPending()
        if pending == "" then return end
        local bold, italic, uppercase = currentStyle()
        table.insert(segments, { text = pending, bold = bold, italic = italic, uppercase = uppercase })
        pending = ""
    end

    local len = #text
    while pos <= len do
        -- Check for bar placeholder (3-byte UTF-8: \xEF\xBF\xBC)
        if text:sub(pos, pos + 2) == BAR_PLACEHOLDER then
            flushPending()
            table.insert(segments, { bar = true })
            pos = pos + 3
        -- Check for closing tag [/b], [/i], [/u]
        elseif text:match("^%[/[biu]%]", pos) then
            local tag = text:sub(pos + 2, pos + 2)  -- the letter after /
            local close_len = 4  -- [/b] = 4 chars
            if #stack > 0 and stack[#stack] == tag then
                flushPending()
                table.remove(stack)
                found_tags = true
                pos = pos + close_len
            else
                -- Mismatched close — stop tag processing, emit rest as literal
                -- Flush what we have, then append everything remaining as literal
                flushPending()
                local rest = text:sub(pos)
                local bold, italic, uppercase = currentStyle()
                table.insert(segments, { text = rest, bold = bold, italic = italic, uppercase = uppercase })
                -- Stack is dirty — fall through to unclosed check below
                if #stack > 0 then
                    return nil, false  -- return nil signals: render as plain text
                end
                return segments, found_tags
            end
        -- Check for opening tag [b], [i], [u]
        elseif text:match("^%[[biu]%]", pos) then
            flushPending()
            local tag = text:sub(pos + 1, pos + 1)  -- the letter
            table.insert(stack, tag)
            found_tags = true
            pos = pos + 3  -- [b] = 3 chars
        else
            pending = pending .. text:sub(pos, pos)
            pos = pos + 1
        end
    end

    flushPending()

    -- Unclosed tags — return nil to signal: render entire line as plain text
    if #stack > 0 then
        return nil, false
    end

    if not found_tags then
        return nil, false
    end

    return segments, true
end
```

- [ ] **Step 2: Verify syntax**

Run: `luac -p overlay_widget.lua`
Expected: no output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add overlay_widget.lua
git commit -m "feat: add parseStyledSegments() BBCode parser (#8)"
```

---

### Task 4: Implement `buildStyledLine()` renderer

**Files:**
- Modify: `overlay_widget.lua` — add function after `parseStyledSegments`

- [ ] **Step 1: Add the renderer function**

```lua
--- Build a HorizontalRowWidget from styled segments (text and bar).
-- Replaces both buildBarLine and single-TextWidget path for styled lines.
-- @param segments table: array from parseStyledSegments
-- @param cfg table: line config with .face, .face_name, .font_size, .bold, .bar, .bar_height, .bar_style, .bar_colors
-- @param available_w number: total available width
-- @param max_width number or nil: truncation limit for the whole line
-- @return widget, width, height
function OverlayWidget.buildStyledLine(segments, cfg, available_w, max_width)
    local effective_w = max_width or available_w
    local widgets = {}
    local total_w = 0
    local text_total_w = 0
    local max_h = 0
    local bar_slot = nil  -- index where bar widget should be inserted

    for _, seg in ipairs(segments) do
        if seg.bar then
            -- Remember bar position, insert later after measuring text
            bar_slot = #widgets + 1
        else
            local display = seg.uppercase and seg.text:upper() or seg.text
            if display ~= "" then
                -- Resolve font face for this segment
                local seg_face = cfg.face
                if seg.italic and cfg.face_name then
                    local italic_face = OverlayWidget.findItalicVariant(cfg.face_name)
                    if italic_face then
                        seg_face = Font:getFace(italic_face, cfg.font_size)
                    end
                end

                local tw = TextWidget:new(textWidgetOpts{
                    text = display,
                    face = seg_face,
                    bold = seg.bold,
                })
                local size = tw:getSize()
                table.insert(widgets, { widget = tw, w = size.w, h = size.h })
                total_w = total_w + size.w
                text_total_w = text_total_w + size.w
                if size.h > max_h then max_h = size.h end
            end
        end
    end

    -- Ensure row height from font even if no text segments
    if text_total_w == 0 and cfg.face then
        local ref_tw = TextWidget:new(textWidgetOpts{ text = " ", face = cfg.face, bold = cfg.bold })
        local ref_h = ref_tw:getSize().h
        ref_tw:free()
        if ref_h > max_h then max_h = ref_h end
    end

    -- Handle bar segment if present
    if bar_slot and cfg.bar then
        local bar_info = cfg.bar
        local bar_h = cfg.bar_height or (cfg.face and cfg.face.size) or 5
        local bar_style = cfg.bar_style or "bordered"
        local bar_manual_w = (bar_info and bar_info.width) or 0

        local bar_w
        if bar_manual_w > 0 then
            bar_w = math.min(bar_manual_w, math.max(0, effective_w - text_total_w))
        else
            bar_w = math.max(0, effective_w - text_total_w)
        end

        if bar_w >= 1 then
            local bar_widget = BarWidget:new{
                width = bar_w,
                height = bar_h,
                fraction = bar_info.pct or 0,
                ticks = bar_info.ticks or {},
                style = bar_style,
                colors = cfg.bar_colors,
            }
            table.insert(widgets, bar_slot, { widget = bar_widget, w = bar_w, h = bar_h })
            total_w = total_w + bar_w
            if bar_h > max_h then max_h = bar_h end
        end
    end

    if #widgets == 0 then
        return nil, 0, 0
    end

    local row = HorizontalRowWidget:new{
        segments = widgets,
        width = total_w,
        height = max_h,
    }
    return row, total_w, max_h
end
```

- [ ] **Step 2: Verify syntax**

Run: `luac -p overlay_widget.lua`
Expected: no output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add overlay_widget.lua
git commit -m "feat: add buildStyledLine() unified segment renderer (#8)"
```

---

### Task 5: Integrate styled line rendering into `buildTextWidget`

**Files:**
- Modify: `overlay_widget.lua:249-264` (single-line path) and `overlay_widget.lua:276-301` (multi-line path)

- [ ] **Step 1: Add `cfg.italic` to line config in main.lua**

The `parseStyledSegments` call needs `cfg.italic` to know the base italic state. Currently `resolveLineConfig` doesn't store this — it resolves the italic face but doesn't flag it.

In `main.lua`, in `resolveLineConfig` (line ~457), add `italic` to the returned table:

Replace:
```lua
    return {
        face = Font:getFace(resolved_face, scaled_size),
        bold = bold,
    }
```

With:
```lua
    return {
        face = Font:getFace(resolved_face, scaled_size),
        bold = bold,
        italic = (style == "italic" or style == "bolditalic"),
    }
```

- [ ] **Step 2: Update single-line path**

In `buildTextWidget`, the single-line path (lines 249-263) currently checks for `cfg.bar` and then creates a plain TextWidget. Add styled line handling before the plain TextWidget fallback.

Replace lines 249-263:
```lua
    if #lines == 1 then
        local cfg = getConfig(1)
        if cfg.bar then
            return buildBarLine(lines[1], cfg, available_w or Screen:getWidth(), max_width)
        end
        local display_text = cfg.uppercase and lines[1]:upper() or lines[1]
        local tw = TextWidget:new(textWidgetOpts{
            text = display_text,
            face = cfg.face,
            bold = cfg.bold,
            max_width = max_width,
            truncate_with_ellipsis = max_width ~= nil,
        })
        local size = tw:getSize()
        return tw, size.w, size.h
    end
```

With:
```lua
    if #lines == 1 then
        local cfg = getConfig(1)
        -- Try styled segments (BBCode tags or bar placeholder)
        local segments, has_tags = OverlayWidget.parseStyledSegments(
            lines[1], cfg.bold, cfg.italic or false, cfg.uppercase)
        if segments then
            return OverlayWidget.buildStyledLine(segments, cfg, available_w or Screen:getWidth(), max_width)
        end
        -- Bar line without tags
        if cfg.bar then
            return buildBarLine(lines[1], cfg, available_w or Screen:getWidth(), max_width)
        end
        -- Plain text — fast path
        local display_text = cfg.uppercase and lines[1]:upper() or lines[1]
        local tw = TextWidget:new(textWidgetOpts{
            text = display_text,
            face = cfg.face,
            bold = cfg.bold,
            max_width = max_width,
            truncate_with_ellipsis = max_width ~= nil,
        })
        local size = tw:getSize()
        return tw, size.w, size.h
    end
```

- [ ] **Step 3: Update multi-line path**

In the multi-line loop (lines 276-301), add the same styled-line check before bar and plain paths.

Replace lines 276-292:
```lua
    for i, line in ipairs(lines) do
        local cfg = getConfig(i)
        local widget, w, h
        if cfg.bar then
            widget, w, h = buildBarLine(line, cfg, available_w or Screen:getWidth(), max_width)
        else
            local display_text = cfg.uppercase and line:upper() or line
            widget = TextWidget:new(textWidgetOpts{
                text = display_text,
                face = cfg.face,
                bold = cfg.bold,
                max_width = max_width,
                truncate_with_ellipsis = max_width ~= nil,
            })
            local size = widget:getSize()
            w, h = size.w, size.h
        end
```

With:
```lua
    for i, line in ipairs(lines) do
        local cfg = getConfig(i)
        local widget, w, h
        -- Try styled segments (BBCode tags or bar placeholder)
        local segments, has_tags = OverlayWidget.parseStyledSegments(
            line, cfg.bold, cfg.italic or false, cfg.uppercase)
        if segments then
            widget, w, h = OverlayWidget.buildStyledLine(segments, cfg, available_w or Screen:getWidth(), max_width)
        elseif cfg.bar then
            widget, w, h = buildBarLine(line, cfg, available_w or Screen:getWidth(), max_width)
        else
            local display_text = cfg.uppercase and line:upper() or line
            widget = TextWidget:new(textWidgetOpts{
                text = display_text,
                face = cfg.face,
                bold = cfg.bold,
                max_width = max_width,
                truncate_with_ellipsis = max_width ~= nil,
            })
            local size = widget:getSize()
            w, h = size.w, size.h
        end
```

- [ ] **Step 4: Verify syntax**

Run: `luac -p overlay_widget.lua && luac -p main.lua`
Expected: no output (clean parse)

- [ ] **Step 5: Deploy and test on Kindle**

```bash
scp tokens.lua overlay_widget.lua main.lua kindle:/mnt/us/koreader/plugins/bookends.koplugin/
```

Test cases:
1. `[b]Page[/b] %c of %t` — "Page" bold, rest regular
2. `[i]%C[/i] — %g/%G` — chapter title italic, rest regular
3. `[b][i]%T[/i][/b]` — title bold italic
4. `[u]chapter[/u] %c` — "chapter" uppercase, rest as-is
5. `[b]%p %bar %P[/b] %T` — percentage and chapter % bold, bar between them, title regular
6. `%C{200} [b]%g[/b]/%G` — token limit + bold on same line
7. `[b]unclosed tag` — renders as literal `[b]unclosed tag`
8. `[b]text[i]overlap[/b]end[/i]` — mismatched nesting, renders as plain text
9. Line with per-line Bold + `[i]text[/i]` — text segment italic (override), rest bold
10. Plain line without any tags — renders exactly as before (no regression)
11. `%bar{400}` — curly brace syntax works for bar width

- [ ] **Step 6: Commit**

```bash
git add overlay_widget.lua main.lua
git commit -m "feat: integrate inline formatting into rendering pipeline (#8)"
```

---

### Task 6: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add inline formatting section**

After the "Per-line styling" section (around line 180), add:

```markdown
### Inline formatting

Use BBCode-style tags to format parts of a line independently:

| Tag | Effect | Example |
|-----|--------|---------|
| `[b]...[/b]` | Bold | `[b]Page[/b] %c of %t` |
| `[i]...[/i]` | Italic | `[i]%C[/i] — %g/%G` |
| `[u]...[/u]` | Uppercase | `[u]chapter[/u] %P` |

Tags can be nested: `[b][i]bold italic[/i][/b]`. Tags must be properly nested — overlapping tags like `[b][i]...[/b][/i]` render as literal text. Unclosed tags also render as literal text.

Tags override the line's per-line style. If a line is set to Bold, `[i]text[/i]` renders that segment as italic (not bold italic). Use `[b][i]...[/i][/b]` for explicit bold italic.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document inline formatting tags (#8)"
```
