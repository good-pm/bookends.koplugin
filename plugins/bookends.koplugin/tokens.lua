local Device = require("device")
local datetime = require("datetime")

local Tokens = {}

function Tokens.expand(format_str, ui, session_start_time)
    -- Fast path: no tokens
    if not format_str:find("%%") then
        return format_str
    end

    local pageno = ui.view.state.page
    local doc = ui.document

    -- Page numbers (respects hidden flows + pagemap)
    local currentpage
    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        currentpage = ui.pagemap:getCurrentPageLabel(true) or ""
    elseif pageno and doc:hasHiddenFlows() then
        currentpage = doc:getPageNumberInFlow(pageno)
    else
        currentpage = pageno or 0
    end

    local totalpages
    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        totalpages = ui.pagemap:getLastPageLabel(true) or ""
    elseif pageno and doc:hasHiddenFlows() then
        local flow = doc:getPageFlow(pageno)
        totalpages = doc:getTotalPagesInFlow(flow)
    else
        totalpages = doc:getPageCount()
    end

    -- Book percentage
    local percent = ""
    if type(currentpage) == "number" and type(totalpages) == "number" and totalpages > 0 then
        percent = math.floor(currentpage / totalpages * 100)
    end

    -- Chapter progress
    local chapter_pct = ""
    local chapter_pages_done = ""
    local chapter_pages_left = ""
    local chapter_title = ""
    if pageno and ui.toc then
        local done = ui.toc:getChapterPagesDone(pageno)
        local total = ui.toc:getChapterPageCount(pageno)
        if done and total and total > 0 then
            chapter_pages_done = done + 1 -- +1 to include current page
            chapter_pct = math.floor(chapter_pages_done / total * 100)
        end
        local left = ui.toc:getChapterPagesLeft(pageno)
        if left then
            chapter_pages_left = left
        end
        local title = ui.toc:getTocTitleByPage(pageno)
        if title and title ~= "" then
            chapter_title = title
        end
    end

    -- Pages left in book
    local pages_left_book = ""
    if pageno then
        local left = doc:getTotalPagesLeft(pageno)
        if left then
            pages_left_book = left
        end
    end

    -- Time left in chapter / document (via statistics plugin)
    local time_left_chapter = ""
    local time_left_doc = ""
    if pageno and ui.statistics and ui.statistics.getTimeForPages then
        local ch_left = ui.toc and ui.toc:getChapterPagesLeft(pageno, true)
        if not ch_left then
            ch_left = doc:getTotalPagesLeft(pageno)
        end
        if ch_left then
            local result = ui.statistics:getTimeForPages(ch_left)
            if result and result ~= _("N/A") then
                time_left_chapter = result
            end
        end
        local doc_left = doc:getTotalPagesLeft(pageno)
        if doc_left then
            local result = ui.statistics:getTimeForPages(doc_left)
            if result and result ~= _("N/A") then
                time_left_doc = result
            end
        end
    end

    -- Clock
    local time_12h = os.date("%I:%M %p"):gsub("^0", "") -- strip leading zero
    local time_24h = os.date("%H:%M")

    -- Session reading time
    local session_time = ""
    if session_start_time then
        local elapsed = os.time() - session_start_time
        local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
        session_time = datetime.secondsToClockDuration(user_duration_format, elapsed, true)
    end

    -- Document metadata
    local props = doc:getProps()
    local title = props.display_title or ""
    local authors = props.authors or ""
    local series = props.series or ""
    if series ~= "" and props.series_index then
        series = series .. " #" .. props.series_index
    end

    -- Battery
    local powerd = Device:getPowerDevice()
    local batt_lvl = powerd:getCapacity()
    local batt_symbol = ""
    if batt_lvl then
        batt_symbol = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), batt_lvl) or ""
    else
        batt_lvl = ""
    end

    -- Wi-Fi (dynamic icon)
    local NetworkMgr = require("ui/network/manager")
    local wifi_symbol
    if NetworkMgr:isWifiOn() then
        wifi_symbol = "\xEE\xB2\xA8" -- U+ECA8 wifi on
    else
        wifi_symbol = "\xEE\xB2\xA9" -- U+ECA9 wifi off
    end

    -- Memory usage
    local mem_usage = ""
    local meminfo = io.open("/proc/meminfo", "r")
    if meminfo then
        local total, available
        for line in meminfo:lines() do
            if line:match("^MemTotal:") then
                total = tonumber(line:match("(%d+)"))
            elseif line:match("^MemAvailable:") then
                available = tonumber(line:match("(%d+)"))
            end
            if total and available then break end
        end
        meminfo:close()
        if total and available and total > 0 then
            mem_usage = math.floor((total - available) / total * 100)
        end
    end

    local replace = {
        -- Page/Progress
        ["%c"] = tostring(currentpage),
        ["%t"] = tostring(totalpages),
        ["%p"] = tostring(percent),
        ["%P"] = tostring(chapter_pct),
        ["%g"] = tostring(chapter_pages_done),
        ["%l"] = tostring(chapter_pages_left),
        ["%L"] = tostring(pages_left_book),
        -- Time/Reading
        ["%h"] = tostring(time_left_chapter),
        ["%H"] = tostring(time_left_doc),
        ["%k"] = time_12h,
        ["%K"] = time_24h,
        ["%R"] = session_time,
        -- Metadata
        ["%T"] = tostring(title),
        ["%A"] = tostring(authors),
        ["%S"] = tostring(series),
        ["%C"] = tostring(chapter_title),
        -- Device
        ["%b"] = tostring(batt_lvl),
        ["%B"] = tostring(batt_symbol),
        ["%W"] = wifi_symbol,
        ["%m"] = tostring(mem_usage),
        -- Formatting
        ["%r"] = " | ",
    }
    return format_str:gsub("(%%%a)", replace)
end

return Tokens
