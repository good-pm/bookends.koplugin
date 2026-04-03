# Token Pixel Width Limits & Wifi Auto-Hide

**Date:** 2026-04-03
**Issues:** #6 (token limits, auto-hide wifi), #8 (formatting syntax — considered for compatibility)

## Overview

Two features for the bookends overlay:

1. **Token pixel width limits** — `%X[N]` syntax to cap individual token values at N pixels, with ellipsis on truncation
2. **Wifi auto-hide** — `%W` hides entirely when wifi is disabled, shows disconnected icon when enabled but not connected

Plus cleanup of orphaned `line_bar_width` per-line setting (UI button was removed, plumbing remained).

## Syntax: `%X[N]`

A pixel width modifier that follows any single-letter token or `%bar`:

| Example | Meaning |
|---------|---------|
| `%C[200] - %g/%G` | Chapter title capped at 200px |
| `%T[300]` | Book title capped at 300px |
| `%bar[400]` | Progress bar fixed at 400px |
| `%C[0]` or no bracket | No limit (normal behaviour) |

### Syntax compatibility with issue #8

Issue #8 requests inline formatting (bold/italic) that wraps arbitrary spans of text and tokens, e.g. `[b]some text %C[/b]`. This is a range-based syntax — fundamentally different from the per-token `%X[N]` modifier. The two do not conflict:

- `%X[N]` — always follows a `%` token, bracket contains a number
- `[b]...[/b]` (or whatever range syntax is chosen) — standalone tags wrapping arbitrary content

No forward-compatibility concerns.

## Feature 1: Token pixel width limits

### tokens.lua changes

**Pre-parse phase** (before expansion):

1. Scan `format_str` for `%X[N]` patterns (single-letter tokens) and `%bar[N]`
2. Extract a `limits` table mapping token occurrences to pixel values
3. Strip `[N]` from the format string so existing expansion logic works unchanged

For `%bar[N]`: store the width in `bar_info.width` rather than using markers, since bar width is handled separately in `buildBarLine`. Strip `[N]` before the existing `%bar` to placeholder substitution.

**During gsub replacement:**

If a token has a pixel limit, wrap its resolved value with control-character markers:

```
\x01 + N (as decimal string) + \x02 + resolved_value + \x03
```

Characters `\x01`-`\x03` cannot appear in real token values or user-entered text. These markers survive through to the rendering stage where font context is available.

**Preview mode:**

Show limits in preview labels, e.g. `%C[200]` previews as `[chapter<=200]`.

**`needs()` function:**

No change needed — `%C[200]` already matches the pattern `%C` followed by non-alpha `[`.

### overlay_widget.lua changes

**New function: `applyTokenLimits(text, face, bold)`**

1. Scan `text` for `\x01N\x02value\x03` markers
2. For each marker:
   - Use `util.splitToChars()` to split `value` into UTF-8 characters (safe for multi-byte icons)
   - Create a temporary `TextWidget` to measure the full value width
   - If width <= N: replace marker with the value unchanged
   - If width > N: binary search on character count to find the longest prefix that fits within (N - ellipsis_width) pixels, append "..." ellipsis
   - Free temporary widgets after measurement
3. Return the cleaned text with all markers replaced

**UTF-8 safety:** All truncation operates on whole UTF-8 characters via `util.splitToChars()`, never on raw bytes. This prevents splitting multi-byte icon glyphs (3-4 bytes for Nerd Font symbols like U+ECA8) which would produce invalid UTF-8 and rendering glitches.

**`buildBarLine` changes:**

Use `bar_info.width` (from `%bar[N]`) instead of `cfg.bar_width` for manual bar width. In Phase 2 of main.lua, `cfg.bar` is assigned from `bar_info`, so `cfg.bar.width` is the access path in `buildBarLine`. Behaviour is identical — just sourced from inline syntax rather than orphaned per-line setting.

### main.lua changes

**Between Phase 2 and widget building:**

After font resolution produces `line_configs` with face/bold per line, apply token limits to each line of expanded text before passing to `buildTextWidget`:

```
for each line in expanded text:
    line = applyTokenLimits(line, line_config.face, line_config.bold)
```

This must happen:
- After font resolution (needs face for pixel measurement)
- Before uppercase transform (so limit applies to displayed text — uppercase is applied inside applyTokenLimits or afterward in buildTextWidget)
- Before widget building (so the widget receives clean text)

**Ordering with uppercase:** The `uppercase` flag is currently applied inside `buildTextWidget`. Since uppercase can change character widths (e.g., "i" vs "I"), `applyTokenLimits` must receive the `uppercase` flag and apply it to marker text before measuring. The final uppercase transform in `buildTextWidget` then operates on already-truncated text. This ensures the pixel limit matches what's actually rendered.

### Edge cases

- `%X[0]` or `%X[-1]` — treated as no limit, markers not emitted
- Token value shorter than limit — no truncation, no ellipsis added
- Token value is empty — marker wraps empty string, resolves to empty (no ellipsis for nothing)
- Multiple limited tokens on one line — each gets independent markers and limits
- `%bar[N]` where N > available width — bar capped at available width (existing buildBarLine logic)

## Feature 2: Wifi auto-hide

### tokens.lua changes

Replace the `%W` resolution block:

**Current** (two states):
- WiFi on -> connected icon (U+ECA8)
- WiFi off -> disconnected icon (U+ECA9)

**New** (three states):
- WiFi off -> empty string (hidden)
- WiFi on, not connected -> disconnected icon (U+ECA9)
- WiFi on, connected -> connected icon (U+ECA8)

```lua
if NetworkMgr:isWifiOn() then
    if NetworkMgr:isConnected() then
        wifi_symbol = "\xEE\xB2\xA8" -- U+ECA8 wifi connected
    else
        wifi_symbol = "\xEE\xB2\xA9" -- U+ECA9 wifi enabled, not connected
    end
else
    wifi_symbol = "" -- wifi disabled, hide icon
end
```

### Auto-hide interaction

When `wifi_symbol` is `""`:
- The existing `all_empty` logic treats it like any other empty/zero token
- If `%W` is the only token on a line, the line auto-hides
- If alongside other tokens (e.g., `%W %b`), just the wifi icon disappears

### No changes needed

- `icon_picker.lua` — description "Wi-Fi (changes with status)" still accurate
- `needs()` function — unchanged
- Preview mode — still shows `[wifi]`

## Cleanup: remove orphaned `line_bar_width`

The per-line `line_bar_width` setting had its UI button removed but plumbing remained. With `%bar[N]` replacing it, remove the plumbing.

### Files and locations

**main.lua — remove `line_bar_width` from:**
- Phase 2 config building: `cfg.bar_width = (pos_settings.line_bar_width ...)` (~line 780)
- Line settings dialog: initialization (~line 1834), snapshot (~line 1849), `applyLivePreview` write-back (~line 1863)
- Line deletion: `sparseRemove(pos_settings.line_bar_width, ...)` (~line 2174, ~line 2231)
- Line swap: `ps.line_bar_width[a], ps.line_bar_width[b] = ...` (~line 2267-2268)
- Line copy/move: `target.line_bar_width` initialization and assignment (~line 2312, ~line 2326)

**overlay_widget.lua — update `buildBarLine`:**
- Replace `cfg.bar_width` reference (~line 168) with `cfg.bar.width` (from `bar_info.width`)

### Migration

No migration needed. Existing saved configs with `line_bar_width` values will have those keys ignored — they sit inert in the settings table. No errors produced.
