# bookends.koplugin - Design Spec

## Summary

A KOReader plugin that renders configurable text overlays at 6 screen positions (four corners + top-center + bottom-center). Each position has an independent format string supporting tokens, literal Nerd Font icons, and line breaks. Text is rendered with smart ellipsis to prevent overlapping. An icon picker UI helps users insert glyphs into format strings.

Supersedes the `footertext.koplugin` prototype.

## Plugin Identity

- **Name:** `bookends`
- **Directory:** `plugins/bookends.koplugin/`
- **Type:** `is_doc_only = true` (reader context only)
- **Files:**
  - `_meta.lua` - plugin metadata
  - `main.lua` - plugin class, settings, event handlers, menu
  - `overlay_widget.lua` - widget rendering, positioning, overlap prevention
  - `tokens.lua` - token expansion engine
  - `icon_picker.lua` - icon browser/inserter UI

## Screen Positions

```
┌──────────────────────────────────┐
│ TL              TC            TR │
│                                  │
│                                  │
│          (reading area)          │
│                                  │
│                                  │
│ BL              BC            BR │
└──────────────────────────────────┘
```

Six positions, each identified by a key:

| Key | Position | Horizontal anchor | Vertical anchor |
|-----|----------|-------------------|-----------------|
| `tl` | Top-left | Left edge | Top edge |
| `tc` | Top-center | Center | Top edge |
| `tr` | Top-right | Right edge | Top edge |
| `bl` | Bottom-left | Left edge | Bottom edge |
| `bc` | Bottom-center | Center | Bottom edge |
| `br` | Bottom-right | Right edge | Bottom edge |

## Settings Architecture

### Global Defaults

All persisted via `G_reader_settings` with prefix `bookends_`.

| Setting | Key | Type | Default |
|---------|-----|------|---------|
| Master enable | `bookends_enabled` | boolean | `false` |
| Font face | `bookends_font_face` | string | status bar font |
| Font size | `bookends_font_size` | integer | status bar font size |
| Bold | `bookends_font_bold` | boolean | `false` |
| Vertical offset | `bookends_v_offset` | integer | `35` |
| Horizontal offset | `bookends_h_offset` | integer | `10` |
| Overlap gap | `bookends_overlap_gap` | integer | `10` |

### Per-Position Settings

Each position stores settings under `bookends_pos_{key}` (e.g., `bookends_pos_tl`). The value is a table:

```lua
{
    format = "",           -- format string (empty = position disabled)
    font_face = nil,       -- nil = use global default
    font_size = nil,       -- nil = use global default
    font_bold = nil,       -- nil = use global default
    v_offset = nil,        -- nil = use global default
    h_offset = nil,        -- nil = use global default (corners only)
}
```

A position is **active** when its format string is non-empty and the master enable is on. Empty format string = position disabled (no separate enable/disable toggle per position needed).

### Offset Semantics

- **Vertical offset:** pixels inward from the screen edge. Positive = further from edge. Applies to all 6 positions.
- **Horizontal offset:** pixels inward from the screen edge. Positive = further from edge. Applies to corner positions only (tl, tr, bl, br). Center positions ignore this.

## Token System

### Token Table

All tokens use `%` prefix followed by a single letter. Expanded at paint time.

| Token | Description | Source |
|-------|-------------|--------|
| **Page/Progress** | | |
| `%c` | Current page number | `view.state.page`, respects hidden flows + pagemap |
| `%t` | Total pages | `document:getPageCount()`, respects hidden flows |
| `%p` | Book percentage read (0-100) | `floor(current/total * 100)` |
| `%P` | Chapter percentage read (0-100) | Calculated from chapter page range via TOC |
| `%g` | Pages read in current chapter | Current page minus chapter start page |
| `%l` | Pages left in chapter | Via `toc:getChapterPagesLeft()` |
| `%L` | Pages left in book | Via `document:getTotalPagesLeft()` |
| **Time/Reading** | | |
| `%h` | Time left in chapter | Via footer `getAvgTimePerPage` |
| `%H` | Time left in document | Via footer `getAvgTimePerPage` |
| `%k` | 12-hour clock (e.g., `2:35 PM`) | `os.date("%I:%M %p")` |
| `%K` | 24-hour clock (e.g., `14:35`) | `os.date("%H:%M")` |
| `%R` | Reading time this session | Self-tracked: records `os.time()` at plugin init, displays elapsed |
| **Metadata** | | |
| `%T` | Document title | `document:getProps().display_title` |
| `%A` | Author(s) | `document:getProps().authors` |
| `%S` | Series with index (e.g., `Dune #1`) | `document:getProps().series` + `series_index` |
| `%C` | Chapter/section title | Via `toc:getTocTitleByPage()` |
| **Device** | | |
| `%b` | Battery level (number) | `powerd:getCapacity()` |
| `%B` | Battery symbol (dynamic icon) | `powerd:getBatterySymbol()` |
| **Formatting** | | |
| `%r` | Separator (renders as ` \| `) | Static string |

### Line Breaks

`\n` in the format string produces a multi-line overlay. Each line is rendered as a separate `TextWidget` within a `VerticalGroup`, inheriting the position's alignment (left-aligned for left positions, right-aligned for right, centered for center).

### Fallback Values

All tokens return `""` (empty string) when unavailable, not `"N/A"`. This prevents ugly "N/A" strings in the overlay — if a token can't resolve, it silently disappears. The user can structure their format strings knowing that missing values won't leave artifacts.

## Widget Architecture

### Per-Position Widget Structure

Each active position builds its own widget tree:

```
OverlayPosition (lightweight container)
├── TextWidget (single-line) OR VerticalGroup (multi-line)
│   ├── TextWidget (line 1)
│   ├── TextWidget (line 2)
│   └── ...
```

The `OverlayPosition` container handles:
- Anchoring to the correct screen edge/corner
- Applying offsets (global + per-position override)
- Reporting its bounding box for overlap calculation

### Rendering Pipeline (per paint cycle)

1. **Expand tokens** for all active positions
2. **Measure text** for all active positions (get width/height)
3. **Detect overlaps** between positions on the same row (top row: tl/tc/tr, bottom row: bl/bc/br)
4. **Truncate with ellipsis** where needed (center gets priority)
5. **Paint** all active positions to the blitbuffer

### Coordinate Calculation

Each position computes its `(x, y)` from screen dimensions and offsets:

| Position | x | y |
|----------|---|---|
| `tl` | `h_offset` | `v_offset` |
| `tc` | `(screen_w - text_w) / 2` | `v_offset` |
| `tr` | `screen_w - text_w - h_offset` | `v_offset` |
| `bl` | `h_offset` | `screen_h - text_h - v_offset` |
| `bc` | `(screen_w - text_w) / 2` | `screen_h - text_h - v_offset` |
| `br` | `screen_w - text_w - h_offset` | `screen_h - text_h - v_offset` |

For multi-line text, `text_h` is the total height of the `VerticalGroup`.

## Smart Ellipsis / Overlap Prevention

### Priority

**Center always wins.** When text would overlap:

1. Center text is measured at full width
2. Left and right texts are allocated the remaining space (screen width minus center text width minus gaps)
3. If left or right text exceeds its allocation, it is truncated with `...`
4. If even center text exceeds screen width, it is truncated

### Algorithm (per row: top or bottom)

```
gap = global overlap_gap setting (default 10px)

if center is active:
    center_w = measure(center_text)
    available_side = (screen_w - center_w) / 2 - gap
    if left is active and measure(left_text) > available_side:
        left_text = truncate(left_text, available_side - h_offset)
    if right is active and measure(right_text) > available_side:
        right_text = truncate(right_text, available_side - h_offset)
else:
    -- no center text: left and right split the screen
    if left is active and right is active:
        half = screen_w / 2 - gap / 2
        if measure(left_text) > half - h_offset:
            left_text = truncate(left_text, half - h_offset)
        if measure(right_text) > half - h_offset:
            right_text = truncate(right_text, half - h_offset)
```

### Truncation

Text is truncated character-by-character from the end until `measure(text .. "...") <= max_width`. This handles variable-width fonts correctly.

For multi-line text, only the longest line participates in overlap detection, and only that line is truncated if needed. Other lines remain untouched.

## Icon Picker UI

### Structure

A scrollable list dialog, invoked from a button in the format string editor. Organized by category with section headers.

### Categories and Icons

Icons sourced from Nerd Fonts (`nerdfonts/symbols.ttf`) which is already in KOReader's font fallback chain:

| Category | Icons (sample) |
|----------|---------------|
| **Battery** | charged, charging, levels 0-100% |
| **Connectivity** | wifi on, wifi off |
| **Status** | bookmark, memory/RAM |
| **Arrows** | left, right, up, down, bidirectional |
| **Symbols** | clock, hourglass, sun/brightness, book |
| **Separators** | vertical bar, bullet, diamond, dash |

Each entry shows: `[icon glyph]  descriptive label`

### Interaction Flow

1. User opens format string editor (InputDialog)
2. User taps "Icons" button
3. Icon picker opens as a scrollable list grouped by category
4. User taps an icon entry
5. The icon's Unicode character is inserted into the format string at the cursor position
6. Picker closes, user is back in the format string editor

### Implementation

Uses KOReader's `Menu` widget (the standard scrollable list) with a custom item rendering that shows the glyph at display size alongside its label.

## Menu Integration

Registered in the reader menu under Settings:

```
Bookends
├── Enable bookends          [checkbox]
├── Position: Top-left             [submenu]
│   ├── Edit format string         [InputDialog + icon picker]
│   ├── Override font              [submenu, optional]
│   ├── Override font size         [SpinWidget, optional]
│   ├── Override vertical offset   [SpinWidget, optional]
│   └── Override horizontal offset [SpinWidget, optional]
├── Position: Top-center           [submenu]
│   ├── Edit format string
│   ├── Override font
│   ├── Override font size
│   └── Override vertical offset
├── Position: Top-right            [submenu]  (same as TL)
├── Position: Bottom-left          [submenu]  (same as TL)
├── Position: Bottom-center        [submenu]  (same as TC)
├── Position: Bottom-right         [submenu]  (same as TL)
├── ── separator ──
├── Default font                   [submenu]
├── Default font size              [SpinWidget]
├── Default vertical offset        [SpinWidget]
├── Default horizontal offset      [SpinWidget]
└── Overlap gap                    [SpinWidget]
```

Each position submenu shows a preview of the current format string (or "Not set") as secondary text.

## Event Handlers

| Event | Action |
|-------|--------|
| `onPageUpdate(page)` | Mark tokens dirty, request repaint |
| `onPosUpdate(pos)` | Mark tokens dirty, request repaint (scroll mode) |
| `onReaderFooterVisibilityChange` | Recalculate offsets, repaint |
| `onSetDimensions(dimen)` | Update screen dimensions, repaint |
| `onCloseWidget` | Free all text widgets |
| `onResume` | Repaint (clock tokens may have changed) |

### Repaint Optimization

Token expansion is only performed at paint time. A simple dirty flag avoids redundant expansion. The expanded text is cached and compared — if unchanged, the widget is not rebuilt.

## Registration

Same approach as the footer text prototype:

```lua
self.ui.view:registerViewModule("bookends", self)
```

View modules paint after the footer, so overlays layer on top.

## File Layout

```
plugins/bookends.koplugin/
├── _meta.lua          -- plugin metadata (~10 lines)
├── main.lua           -- CustomOverlay class, settings, events, menu (~400 lines)
├── overlay_widget.lua -- widget building, positioning, overlap logic (~250 lines)
├── tokens.lua         -- token expansion engine (~150 lines)
└── icon_picker.lua    -- icon browser UI (~150 lines)
```

Estimated total: ~950 lines across 5 files. Split by concern to keep each file focused and maintainable.
