# Inline Formatting (BBCode Tags)

**Date:** 2026-04-03
**Issue:** #8

## Overview

Add inline formatting within status bar lines using BBCode-style tags. Allows bold, italic, and uppercase to be applied to arbitrary spans of text and tokens within a single line, rather than only per-line styling.

Also refactors the `%X[N]` token width limit syntax to `%X{N}` (curly braces) to avoid ambiguity with square-bracket tags.

## Syntax

### Formatting tags

| Tag | Effect |
|-----|--------|
| `[b]...[/b]` | Bold |
| `[i]...[/i]` | Italic |
| `[u]...[/u]` | Uppercase |

Tags can be nested for combined effects:

```
[b][i]bold italic[/i][/b]
[b]bold [u]bold uppercase[/u] bold[/b]
```

### Nesting rules

- Tags must be properly nested: `[b][i]...[/i][/b]` is valid
- Overlapping tags are invalid: `[b][i]...[/b][/i]` — when the parser encounters `[/b]` but the most recent unclosed tag is `[i]`, parsing stops and remaining tags render as literal text
- Unclosed tags render as literal text
- Orphaned closing tags render as literal text

### Style override behaviour

Tags override the line's per-line style (set in the editor). If a line is configured as Bold:
- Untagged text renders bold (the base style)
- `[i]text[/i]` renders italic (override, not combine)
- `[b][i]text[/i][/b]` renders bold italic (explicit nesting)

### Token width syntax change

To avoid ambiguity between `[b]` tags and `[N]` width brackets:
- `%C{200}` replaces `%C[200]`
- `%bar{400}` replaces `%bar[400]`
- `%C{0}` or no braces = no limit (unchanged behaviour)

Preview labels update accordingly: `[chapter<=200]` becomes `{chapter<=200}`.

## Architecture

### Processing pipeline order

1. **Token expansion** (`tokens.lua`) — `%C` → "Chapter Title", `%X{N}` → marker-wrapped values
2. **Token limit processing** (`overlay_widget.lua`) — markers → truncated text
3. **BBCode parsing** (`overlay_widget.lua`) — `[b]text[/b]` → styled segments
4. **Rendering** (`overlay_widget.lua`) — segments → TextWidgets → HorizontalRowWidget

BBCode parsing happens after token expansion, so `[b]%C[/b]` works — the token expands first, then the tag wraps the result.

### Parser: `parseStyledSegments(text)`

A flat left-to-right parser using a style stack.

**Input:** Expanded text string, potentially containing `[b]`, `[i]`, `[u]`, `[/b]`, `[/i]`, `[/u]`, and the bar placeholder character.

**Output:** A list of segments:
- Text segments: `{text = "...", bold = bool, italic = bool, uppercase = bool}`
- Bar segments: `{bar = true, bold = false, italic = false, uppercase = false}`

**Algorithm:**
1. Initialise empty style stack and empty segments list
2. Scan left-to-right for `[b]`, `[i]`, `[u]`, `[/b]`, `[/i]`, `[/u]`, and bar placeholder
3. On opening tag: flush pending text as a segment with current stack state, push tag onto stack
4. On closing tag: if it matches the top of the stack, flush pending text, pop stack. If it doesn't match the top, stop parsing — emit remaining text (including the mismatched tag) as a literal segment
5. On bar placeholder: flush pending text, emit a bar segment
6. At end of string: flush remaining text. If stack is non-empty, the tags were unclosed — reparse the entire string without tag processing (render all tags as literal text)

**Unclosed tag handling:** If the stack is non-empty at end of input, return the original text as a single unstyled segment (all tags rendered as literal text). This ensures unclosed `[b]` doesn't silently bold the rest of the line — it renders as literal `[b]`.

### Renderer: unified `buildStyledLine()`

Replaces both `buildTextWidget` (single-line) and `buildBarLine` for lines that contain tags or bars. Produces one `HorizontalRowWidget`.

**Input:** Parsed segments list, base line config (face_name, font_size, style, scale), bar_info, available_w, max_width.

**Per-segment font resolution:**
- Base face and size come from the line config
- `bold` flag: passed to TextWidget's `bold` parameter
- `italic` flag: resolves italic font variant via `findItalicVariant(face_name)`
- `uppercase` flag: applies `.upper()` to segment text before creating TextWidget
- Combined: `bold=true` + italic face for bold-italic segments

**Bar segment handling:**
- Same logic as current `buildBarLine`: calculate bar width from available space minus total text width
- Bar manual width from `bar_info.width` (the `%bar{N}` value)

**Returns:** widget, width, height — same interface as `buildTextWidget`.

### Integration into `buildTextWidget`

`buildTextWidget` currently handles single-line and multi-line cases. For each line:

1. If line contains `[` or the bar placeholder → parse with `parseStyledSegments()`
2. If parsing produces multiple segments → `buildStyledLine()`
3. Otherwise → existing single-TextWidget path (zero overhead for plain lines)

For multi-line positions, each line is checked independently.

### Font resolution

`findItalicVariant()` and font scaling currently live in `main.lua` as part of `resolveLineConfig()`. For inline italic segments, `buildStyledLine` needs access to:
- The base font face name (not the resolved Face object — we need the name to find italic variants)
- The font scale setting
- The `findItalicVariant` function

Options:
- Pass `face_name` and `font_scale` through `line_configs` (they're already computed in Phase 2)
- Move or expose `findItalicVariant` from `main.lua` to a shared location

The line config already has `cfg.face` (the resolved Face object). We need to add `cfg.face_name` (the string) and `cfg.font_size` (the scaled size) so `buildStyledLine` can resolve variant faces for italic segments.

## Token width syntax refactor

### tokens.lua changes

Replace all `[N]` bracket patterns with `{N}` curly brace patterns:

- Pre-parse: `%X[N]` → `%X{N}` patterns
- Bar: `%bar[N]` → `%bar{N}`
- Preview: `[chapter<=200]` → `{chapter<=200}`
- The `has_limits` guard: `%[%d+%]` → `%{%d+%}`

### Edge cases

- `%C{200}` with `[b]...[/b]` on same line — no ambiguity, different bracket types
- `[b]%C{200}[/b]` — token limit applied first (markers processed), then BBCode wraps the truncated value
- `%bar{400}` inside `[b]...[/b]` — bar width applies, bold doesn't affect the bar widget itself (it's a graphical element)

## Preview mode

Tags are shown as-is in the editor preview — they're meaningful formatting instructions. The preview already shows expanded token labels, so `[b][chapter][/b]` is clear.

## Scope

### This release
- `[b]`, `[i]`, `[u]` tags with proper nesting
- Unified `buildStyledLine` renderer
- `%X{N}` syntax refactor

### Future
- `[sN]...[/sN]` — font size override
- Additional modifiers as needed

## Files affected

- `tokens.lua` — `[N]` → `{N}` syntax change
- `overlay_widget.lua` — `parseStyledSegments()`, `buildStyledLine()`, integration into `buildTextWidget`
- `main.lua` — pass `face_name` and `font_size` through line configs, `[N]` → `{N}` in preview if needed
- `README.md` — document inline formatting, update token width syntax
