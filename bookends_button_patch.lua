--[[
Defensive patch for Button:_doFeedbackHighlight.

KOReader v2026.03 crashes when frame.background is nil at tap time:
    self[1].background = self[1].background:invert()   -- line 406 of button.lua

Button:init() always sets frame.background = Blitbuffer.COLOR_WHITE, but
something clears it before the tap fires for buttons created without an
explicit background field (the ButtonTable default path). The root cause is
unclear; this patch guards against it so the tap feedback degrades gracefully
to an invert-rect instead of crashing KOReader.

Remove this once upstream resolves the nil-background regression.
]]

local Button = require("ui/widget/button")
local Blitbuffer = require("ffi/blitbuffer")

if not Button._orig_doFeedbackHighlight_bookends then
    Button._orig_doFeedbackHighlight_bookends = Button._doFeedbackHighlight
    function Button:_doFeedbackHighlight()
        -- Guard: if the frame background was cleared by unknown code, restore it
        -- before the invert path runs; otherwise fall through to the safe invert=true path.
        if self.text and self[1] and self[1].background == nil then
            self[1].background = Blitbuffer.COLOR_WHITE
        end
        return Button._orig_doFeedbackHighlight_bookends(self)
    end
end
