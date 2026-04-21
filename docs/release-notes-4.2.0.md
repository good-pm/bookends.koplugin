# Bookends 4.2.0 — release notes

## New: metro progress bar has a visible read portion

A new **Metro read color** setting (under Colors → Progress bar colors and tick marks) paints the part of the metro trunk the reader has passed in a distinct colour, recolours the chapter ticks already reached, and applies the same colour to the start-cap ring. Metro's track colour is preserved as before.

When unset (default), metro renders identically to 4.1.0 — no visual change for existing users.

The setting is also available per-bar, under Progress bars → Bar N → Colors → Metro read color, so individual bars can use different metro read colours. Existing presets continue to work unchanged; they simply lack the new field and fall back to the uniform-trunk rendering.
