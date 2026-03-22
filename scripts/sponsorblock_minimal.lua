-- sponsorblock_minimal.lua
-- This script skip/mute sponsored segments of YouTube and bilibili videos
-- using data from https://github.com/ajayyy/SponsorBlock
-- and https://github.com/hanydd/BilibiliSponsorBlock
--
-- Added: manual mode with ASS button overlay, countdown progress bar,
--        mouse click and keyboard (y/n) support.
-- Added: Bilibili bangumi (ep) support via ep_id → BVID conversion.

local opt = require 'mp.options'
local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'

local options = {
    youtube_sponsor_server = "https://sponsor.ajay.app/api/skipSegments",
    bilibili_sponsor_server = "https://bsbsb.top/api/skipSegments",
    categories = '"sponsor"',
    mode = "auto",
    timeout = 10,
    button_font_size = 24,
    button_padding_x = 20,
    button_padding_y = 15,
    button_margin = 60,
    button_border = 2,
    button_radius = 13,
    button_progress_color = "2442F4",
    button_remaining_color = "FFFFFF",
    button_progress_hover_color = "1830C0",
    button_remaining_hover_color = "111111",
    button_text_color = "000000",
    button_text_hover_color = "FFFFFF",
    button_border_color = "FFFFFF",
}

opt.read_options(options)

local ranges = nil
local video_id = nil
local sponsor_server = nil
local cache = {}
local mute = false
local ON = false

-- ─── Button UI state ───────────────────────────────────────────────────────

local button_state = {
    overlay             = nil,
    visible             = false,
    message             = "",
    mouse_hover         = false,
    countdown_timer     = nil,
    countdown_remaining = 0,
    countdown_total     = 0,
    action              = nil,
    seg                 = nil,
}

local hide_button
local render_button
local bind_button_click
local unbind_button_click

local function init_button_overlay()
    if not button_state.overlay then
        button_state.overlay = mp.create_osd_overlay("ass-events")
        if button_state.overlay then
            button_state.overlay.z = 2000
        end
    end
end

local function is_mouse_in_button(bx, by, bw, bh, mx, my)
    return mx >= bx and mx <= bx + bw and my >= by and my <= by + bh
end

render_button = function()
    if not button_state.visible then return end
    init_button_overlay()

    local dims = mp.get_property_native("osd-dimensions")
    local screen_w = dims and dims.w or 1920
    local screen_h = dims and dims.h or 1080
    local scale    = screen_h / 1080

    local pad_x    = options.button_padding_x * scale
    local pad_y    = options.button_padding_y * scale
    local font_size = options.button_font_size * scale
    local margin   = options.button_margin * scale
    local radius   = options.button_radius * scale
    local border   = options.button_border * scale

    local btn_w = #button_state.message * font_size * 0.6 + pad_x * 2
    local btn_h = font_size + pad_y * 2
    local btn_x = screen_w - btn_w - margin
    local btn_y = screen_h - btn_h - margin - (80 * scale)

    local pos = mp.get_property_native("mouse-pos")
    local mx = pos and pos.x or 0
    local my = pos and pos.y or 0
    local hovering = pos and pos.hover and
                     is_mouse_in_button(btn_x, btn_y, btn_w, btn_h, mx, my)
    button_state.mouse_hover = hovering

    local progress = 0
    if button_state.countdown_total > 0 then
        progress = 1 - (button_state.countdown_remaining / button_state.countdown_total)
    end
    if button_state.countdown_remaining <= 0 then progress = 1 end

    local prog_color = hovering and options.button_progress_hover_color or options.button_progress_color
    local rem_color  = hovering and options.button_remaining_hover_color or options.button_remaining_color
    local txt_color  = hovering and options.button_text_hover_color     or options.button_text_color

    local ass = assdraw.ass_new()

    ass:new_event(); ass:pos(0, 0)
    ass:append("{\\blur0\\bord0\\1c&H000000&\\3c&H" .. options.button_border_color .. "&\\bord" .. border .. "}")
    ass:draw_start()
    ass:round_rect_cw(btn_x, btn_y, btn_x + btn_w, btn_y + btn_h, radius)
    ass:draw_stop()

    if progress > 0 then
        local pw = btn_w * progress
        ass:new_event(); ass:pos(0, 0)
        ass:append("{\\blur0\\bord0\\1c&H" .. prog_color .. "&}")
        ass:draw_start()
        if progress >= 1 then
            ass:round_rect_cw(btn_x, btn_y, btn_x + btn_w, btn_y + btn_h, radius)
        else
            ass:round_rect_cw(btn_x, btn_y, btn_x + pw, btn_y + btn_h, radius, 0)
        end
        ass:draw_stop()
    end

    if progress < 1 then
        local pw = btn_w * progress
        ass:new_event(); ass:pos(0, 0)
        ass:append("{\\blur0\\bord0\\1c&H" .. rem_color .. "&}")
        ass:draw_start()
        if progress > 0 then
            ass:round_rect_cw(btn_x + pw, btn_y, btn_x + btn_w, btn_y + btn_h, 0, radius)
        else
            ass:round_rect_cw(btn_x, btn_y, btn_x + btn_w, btn_y + btn_h, radius)
        end
        ass:draw_stop()
    end

    ass:new_event()
    ass:append("{\\an5\\fs" .. font_size .. "\\b1\\bord0\\shad0\\1c&H" .. txt_color .. "&}")
    ass:pos(btn_x + btn_w / 2, btn_y + btn_h / 2)
    ass:append(button_state.message)

    button_state.overlay.res_x = screen_w
    button_state.overlay.res_y = screen_h
    button_state.overlay.data  = ass.text
    button_state.overlay:update()
end

bind_button_click = function()
    mp.add_forced_key_binding("MBTN_LEFT", "sponsorblock-btn-click", function()
        local pos = mp.get_property_native("mouse-pos")
        if not pos then return end
        if button_state.mouse_hover then
            if button_state.action then button_state.action() end
            hide_button()
        else
            if button_state.seg then button_state.seg.cancelled = true end
            hide_button()
        end
    end)
end

unbind_button_click = function()
    mp.remove_key_binding("sponsorblock-btn-click")
end

hide_button = function()
    if button_state.countdown_timer then
        button_state.countdown_timer:kill()
        button_state.countdown_timer = nil
    end
    button_state.visible             = false
    button_state.message             = ""
    button_state.action              = nil
    button_state.seg                 = nil
    button_state.countdown_remaining = 0
    button_state.countdown_total     = 0
    button_state.mouse_hover         = false
    if button_state.overlay then button_state.overlay:remove() end
    unbind_button_click()
    mp.remove_key_binding("sponsorblock-confirm")
    mp.remove_key_binding("sponsorblock-cancel")
end

local function show_button(message, action, seg)
    hide_button()
    button_state.visible             = true
    button_state.message             = message
    button_state.action              = action
    button_state.seg                 = seg
    button_state.countdown_remaining = options.timeout
    button_state.countdown_total     = options.timeout
    render_button()
    bind_button_click()
    mp.add_forced_key_binding("y", "sponsorblock-confirm", function()
        if button_state.action then button_state.action() end
        hide_button()
    end)
    mp.add_forced_key_binding("n", "sponsorblock-cancel", function()
        if button_state.seg then button_state.seg.cancelled = true end
        hide_button()
    end)
    if options.timeout > 0 then
        button_state.countdown_timer = mp.add_periodic_timer(1, function()
            button_state.countdown_remaining = button_state.countdown_remaining - 1
            if button_state.countdown_remaining <= 0 then
                if button_state.seg then button_state.seg.cancelled = true end
                hide_button()
            else
                render_button()
            end
        end)
    end
end

mp.observe_property("mouse-pos", "native", function()
    if button_state.visible then render_button() end
end)

-- ─── Category label helper ─────────────────────────────────────────────────

local category_labels = {
    sponsor        = "跳过赞助商",
    selfpromo      = "跳过自我宣传",
    interaction    = "跳过互动引导",
    intro          = "跳过片头",
    outro          = "跳过片尾",
    preview        = "跳过预览",
    music_offtopic = "跳过非音乐片段",
    filler         = "跳过填充内容",
}

local function skip_label(category)
    return category_labels[category] or ("Skip " .. (category or "Segment"))
end

-- ─── Prompt queue ──────────────────────────────────────────────────────────

local prompt_queue = {}

local function process_queue()
    if button_state.visible or #prompt_queue == 0 then return end
    local item = table.remove(prompt_queue, 1)
    show_button(item.message, item.action, item.seg)
end

local function enqueue_prompt(message, action, seg)
    if button_state.visible then
        table.insert(prompt_queue, {message = message, action = action, seg = seg})
    else
        show_button(message, action, seg)
    end
end

-- ─── API helpers ───────────────────────────────────────────────────────────

local function curl_get(url)
    local res = mp.command_native{
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = { "curl", "-L", "-s", "-g", url }
    }
    if res.status ~= 0 then return nil end
    return res.stdout
end

local function getranges(url)
    local res = mp.command_native{
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = {
            "curl", "-L", "-s", "-g",
            "-H", "origin: mpv-script/skip_sponsorblock",
            "-H", "x-ext-version: 0.6.1",
            url
        }
    }
    if res.status ~= 0 then return nil end
    return utils.parse_json(res.stdout)
end

-- ▼▼▼ 新增函数：通过 ep_id 调 B 站 API 取回 BVID ▼▼▼
local function get_bvid_from_epid(ep_id)
    local body = curl_get("https://api.bilibili.com/pgc/view/web/season?ep_id=" .. ep_id)
    if not body then return nil end
    local data = utils.parse_json(body)
    if not data or data.code ~= 0 then return nil end
    local episodes = data.result and data.result.episodes
    if not episodes then return nil end
    for _, ep in ipairs(episodes) do
        if tostring(ep.ep_id) == tostring(ep_id) then
            return ep.bvid
        end
    end
    return nil
end
-- ▲▲▲ 新增函数结束 ▲▲▲

-- ─── Chapter injection ─────────────────────────────────────────────────────

local function make_chapter(r)
    local chapters_time  = {}
    local chapters_title = {}
    local chapter_index  = 0
    local all_chapters   = mp.get_property_native("chapter-list")
    for _, v in pairs(r) do
        table.insert(chapters_time,  v.segment[1])
        table.insert(chapters_title, v.category)
        table.insert(chapters_time,  v.segment[2])
        table.insert(chapters_title, "normal")
    end
    for i = 1, #chapters_time do
        chapter_index = chapter_index + 1
        all_chapters[chapter_index] = {
            title = chapters_title[i] or ("Chapter " .. string.format("%02.f", chapter_index)),
            time  = chapters_time[i]
        }
    end
    table.sort(all_chapters, function(a, b) return a['time'] < b['time'] end)
    mp.set_property_native("chapter-list", all_chapters)
end

-- ─── Core playback watcher ─────────────────────────────────────────────────

local function do_skip(v)
    mp.osd_message(string.format("[sponsorblock] skipping %s", v.category or "segment"))
    mp.set_property("time-pos", v.segment[2] + 0.01)
end

local function skip_ads(_, pos)
    if pos == nil or ranges == nil then return end
    for _, v in pairs(ranges) do
        if v.actionType == "skip" and v.segment[1] <= pos and v.segment[2] > pos then
            if options.mode == "auto" then
                local secs = math.floor(v.segment[2] - pos)
                mp.osd_message(string.format("[sponsorblock] skipping forward %ds", secs))
                mp.set_property("time-pos", v.segment[2] + 0.01)
            elseif options.mode == "manual" and not v.prompted and not v.cancelled then
                v.prompted = true
                enqueue_prompt(skip_label(v.category), function() do_skip(v) end, v)
            end
        elseif v.actionType == "mute" then
            if v.segment[1] <= pos and v.segment[2] >= pos then
                cache[v.segment[2]] = nil
                mp.set_property_bool("mute", true)
            elseif pos > v.segment[2] and not cache[v.segment[2]] and mute ~= false then
                cache[v.segment[2]] = true
                mp.set_property_bool("mute", false)
            end
        end
    end
    if button_state.visible and button_state.seg then
        local s = button_state.seg
        if s.segment and pos > s.segment[2] then
            s.cancelled = true
            hide_button()
            process_queue()
        end
    end
end

local function on_seek()
    if ranges == nil then return end
    local pos = mp.get_property_number("time-pos") or 0
    for _, v in pairs(ranges) do
        if v.segment and pos < v.segment[1] then
            v.prompted  = false
            v.cancelled = false
        end
    end
end

-- ─── 公共的启动逻辑（拿到 video_id 后执行）─────────────────────────────────

local function start_with_id(vid, srv)
    local url = ("%s?videoID=%s&categories=[%s]"):format(srv, vid, options.categories)
    ranges = getranges(url)
    if ranges ~= nil then
        make_chapter(ranges)
        ON = true
        mp.observe_property("time-pos", "native", skip_ads)
        mp.register_event("seek", on_seek)
    end
end

-- ─── File loaded ───────────────────────────────────────────────────────────

local function file_loaded()
    cache    = {}
    video_id = nil
    mute     = mp.get_property_bool("mute")

    local video_path    = mp.get_property("path", "")
    local video_referer = mp.get_property("http-header-fields", ""):match("[Rr]eferer:%s*([^,\r\n]+)") or ""
    local purl          = mp.get_property("metadata/by-key/PURL", "")

    -- ▼▼▼ 新增：优先检测 bangumi URL，提取 ep_id 并转换为 BVID ▼▼▼
    local ep_id = video_path:match("bilibili%.com/bangumi/play/ep(%d+)") or
                  video_referer:match("bilibili%.com/bangumi/play/ep(%d+)")
    if ep_id then
        local bvid = get_bvid_from_epid(ep_id)
        if bvid then
            start_with_id(bvid, options.bilibili_sponsor_server)
        end
        return  -- bangumi 路径到此结束，不走下面的通用逻辑
    end
    -- ▲▲▲ 新增结束 ▲▲▲

    -- 以下为原有逻辑，未改动
    local bilibili = video_path:match("bilibili.com/video") or
                     video_referer:match("bilibili.com/video") or false

    local urls = {
        "ytdl://youtu%.be/([%w-_]+).*",
        "ytdl://w?w?w?%.?youtube%.com/v/([%w-_]+).*",
        "ytdl://w?w?w?%.?bilibili%.com/video/([%w-_]+).*",
        "https?://youtu%.be/([%w-_]+).*",
        "https?://w?w?w?%.?youtube%.com/v/([%w-_]+).*",
        "https?://w?w?w?%.?bilibili%.com/video/([%w-_]+).*",
        "/watch.*[?&]v=([%w-_]+).*",
        "/embed/([%w-_]+).*",
        "^ytdl://([%w-_]+)$",
        "-([%w-_]+)%."
    }

    for _, url in ipairs(urls) do
        video_id = video_id or video_path:match(url) or
                   video_referer:match(url) or purl:match(url)
    end

    if not video_id or string.len(video_id) < 11 then return end

    if bilibili then
        sponsor_server = options.bilibili_sponsor_server
        video_id       = string.sub(video_id, 1, 12)
    else
        sponsor_server = options.youtube_sponsor_server
        video_id       = string.sub(video_id, 1, 11)
    end

    start_with_id(video_id, sponsor_server)
end

local function end_file()
    if not ON then return end
    mp.unobserve_property(skip_ads)
    mp.unregister_event(on_seek)
    hide_button()
    prompt_queue = {}
    cache  = nil
    ranges = nil
    ON     = false
end

mp.register_event("file-loaded", file_loaded)
mp.register_event("end-file",    end_file)
