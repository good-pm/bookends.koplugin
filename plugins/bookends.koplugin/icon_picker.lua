local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local IconPicker = {}

-- Icon catalog: { category_label, { {glyph_or_token, description, is_token}, ... } }
-- is_token: if true, inserts a %token instead of a literal glyph
IconPicker.CATALOG = {
    { _("Dynamic"), {
        { "%B", _("Battery (dynamic level)"), true },
        { "%W", _("Wi-Fi (dynamic on/off)"), true },
        { "%m", _("Memory usage %"), true },
    }},
    { _("Status"), {
        { "\xEF\x82\x97", _("Bookmark") },       -- U+F097
        { "\xEE\xA9\x9A", _("Memory chip") },     -- U+EA5A
    }},
    { _("Time"), {
        { "\xE2\x8C\x9A", _("Watch") },           -- U+231A
        { "\xE2\x8F\xB3", _("Hourglass") },       -- U+23F3
    }},
    { _("Symbols"), {
        { "\xE2\x98\xBC", _("Sun / brightness") }, -- U+263C
    }},
    { _("Arrows"), {
        { "\xE2\x86\x90", _("Arrow left") },            -- U+2190
        { "\xE2\x86\x92", _("Arrow right") },           -- U+2192
        { "\xE2\x86\x91", _("Arrow up") },              -- U+2191
        { "\xE2\x86\x93", _("Arrow down") },            -- U+2193
        { "\xE2\x87\x84", _("Arrows left-right") },     -- U+21C4
        { "\xE2\x87\x89", _("Double arrows right") },   -- U+21C9
        { "\xE2\x86\xA2", _("Arrow left with tail") },  -- U+21A2
        { "\xE2\x86\xA3", _("Arrow right with tail") }, -- U+21A3
        { "\xE2\xA4\x9F", _("Arrow left to bar") },     -- U+291F
        { "\xE2\xA4\xA0", _("Arrow right to bar") },    -- U+2920
        { "\xE2\x96\xB6", _("Triangle right") },        -- U+25B6
        { "\xE2\x97\x80", _("Triangle left") },         -- U+25C0
        { "\xE2\x96\xB2", _("Triangle up") },           -- U+25B2
        { "\xE2\x96\xBC", _("Triangle down") },         -- U+25BC
        { "\xC2\xBB",     _("Double angle right") },    -- U+00BB >>
        { "\xC2\xAB",     _("Double angle left") },     -- U+00AB <<
    }},
    { _("Separators"), {
        { "|",             _("Vertical bar") },          -- U+007C
        { "\xE2\x80\xA2", _("Bullet") },                -- U+2022
        { "\xC2\xB7",     _("Middle dot") },             -- U+00B7
        { "\xE2\x8B\xAE", _("Vertical ellipsis") },     -- U+22EE
        { "\xE2\x97\x86", _("Diamond") },               -- U+25C6
        { "\xE2\x80\x94", _("Em dash") },               -- U+2014
        { "\xE2\x80\x93", _("En dash") },               -- U+2013
        { "\xE2\x80\xA6", _("Horizontal ellipsis") },   -- U+2026
    }},
}

--- Build the flat item list for the Menu widget, with category headers.
function IconPicker:buildItemTable()
    local items = {}
    for _, category in ipairs(self.CATALOG) do
        local label = category[1]
        local icons = category[2]
        table.insert(items, {
            text = "\xE2\x94\x80\xE2\x94\x80 " .. label .. " \xE2\x94\x80\xE2\x94\x80",
            dim = true,
            callback = function() end,
        })
        for _, icon_entry in ipairs(icons) do
            local value = icon_entry[1]
            local desc = icon_entry[2]
            local is_token = icon_entry[3]
            local display
            if is_token then
                display = value .. "  " .. desc
            else
                display = value .. "   " .. desc
            end
            table.insert(items, {
                text = display,
                insert_value = value,
            })
        end
    end
    return items
end

--- Show the icon picker. When user selects an icon, on_select(value) is called.
-- @param on_select function(string) — receives glyph or token to insert
function IconPicker:show(on_select)
    local item_table = self:buildItemTable()
    local Device = require("device")
    local Screen = Device.screen

    local menu
    menu = Menu:new{
        title = _("Insert icon"),
        item_table = item_table,
        width = math.floor(Screen:getWidth() * 0.8),
        height = math.floor(Screen:getHeight() * 0.8),
        items_per_page = 14,
        onMenuChoice = function(_, item)
            if item.insert_value then
                UIManager:close(menu)
                on_select(item.insert_value)
            end
        end,
    }
    UIManager:show(menu)
end

return IconPicker
