-- sponsorblock_minimal.lua v 0.6.4
-- skip_sponsorblock.lua
-- This script skip/mute sponsored segments of YouTube and bilibili videos
-- using data from https://github.com/ajayyy/SponsorBlock
-- and https://github.com/hanydd/BilibiliSponsorBlock
--
-- Added: manual mode with ASS button overlay, countdown progress bar,
--        mouse click and keyboard (y/n) support.
-- Added: Bilibili bangumi (ep) support via ep_id → BVID conversion.
-- Fixed: tail-end segment no longer pushes playback to EOF (clamped seek);
--        existing chapter list is preserved (append instead of overwrite);
--        prompt queue dequeues on every exit path; mute restores the user's
--        original state after the segment; bangumi passes cid to bsbsb;
--        HTTP/JSON layer guards (--fail/--max-time/type check); chapters
--        and OSD messages follow the repo's Chinese wording convention.
--        clamped seeks never land before the segment start (no seek loop);
--        prompt queue rejects duplicate entries for the same segment.
--        sponsor start-chapters carry a `SponsorBlock: ` prefix so uosc's
--        hardcoded ad-range detection (`^sponsors?`) keeps working with
--        Chinese titles.

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
local ON = false
-- mute 会话状态：进入首个 mute 段前记录用户原静音值，离开全部 mute 段后恢复。
-- 用会话制而非逐段记录——重叠 mute 段（A 段未出又进 B 段）时，逐段记录会把
-- 段内被脚本置真的值误存为「用户原值」，恢复必错
local mute_forced = false
local mute_orig   = nil

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
-- 前置声明：hide_button 尾部要调 process_queue 出队（队列段在后面才定义）
local process_queue

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
    -- 隐藏与出队一体（chapterskip cancel_skip_prompt 的形态）：确认/取消/超时/段过期
    -- 四条结束路径都经过这里，出队挂在此处才能全覆盖，且不会双重出队
    process_queue()
end

local function show_button(message, action, seg)
    -- 不在此处调 hide_button：调用方（enqueue_prompt/process_queue）均已保证非可见态，
    -- 且 hide_button 尾部会出队，这里再进 hide 会递归出队并互相覆盖按钮状态
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

-- 类别中文名：按钮文案 = 「跳过」+ 此名；章节标题与 OSD 直接用此名
local category_names = {
    sponsor        = "赞助商",
    selfpromo      = "自我宣传",
    interaction    = "互动引导",
    intro          = "片头",
    outro          = "片尾",
    preview        = "预览",
    music_offtopic = "非音乐片段",
    filler         = "填充内容",
}

local function category_name(category)
    return category_names[category] or (category or "片段")
end

local function skip_label(category)
    return "跳过" .. category_name(category)
end

-- ─── Prompt queue ──────────────────────────────────────────────────────────

local prompt_queue = {}

process_queue = function()
    if button_state.visible or #prompt_queue == 0 then return end
    local item = table.remove(prompt_queue, 1)
    show_button(item.message, item.action, item.seg)
end

local function enqueue_prompt(message, action, seg)
    if button_state.visible then
        -- 查重：on_seek 回退会重置 prompted，重入段会对已在队列/正在提示的段
        -- 再次入队，堆积重复项（确认时毫秒级 show/hide 级联闪烁）；
        -- 引用相等判定不会误杀不同段，出队消费后再入队（回看重提示）不受影响
        if seg == button_state.seg then return end
        for _, item in ipairs(prompt_queue) do
            if item.seg == seg then return end
        end
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
        -- --fail：HTTP 4xx/5xx 转为非零退出码（否则 curl 照常退出 0，状态检查形同虚设）
        -- --max-time：请求超时上限，防止端点无响应时长时间无反馈
        args = { "curl", "-L", "-s", "-g", "--fail", "--max-time", "10", url }
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
            "curl", "-L", "-s", "-g", "--fail", "--max-time", "10",
            "-H", "origin: mpv-script/skip_sponsorblock",
            "-H", "x-ext-version: 0.6.4",
            url
        }
    }
    if res.status ~= 0 then return nil end
    local result = utils.parse_json(res.stdout)
    -- 自建/中转端点可能返回非 JSON 正文（裸数字、HTML 错误页），parse 出
    -- nil/number/string 一律按失败处理，避免下游 pairs() 直接抛错
    if type(result) ~= "table" then return nil end
    return result
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
            -- 同步带回 cid：bsbsb 按 cid 索引，分P 型番剧各集共用同一 BVID，
            -- 只按 BVID 查询会拿到全部分P 片段的并集
            return ep.bvid, ep.cid
        end
    end
    return nil
end
-- ▲▲▲ 新增函数结束 ▲▲▲

-- ─── Chapter injection ─────────────────────────────────────────────────────

-- 需要在 uosc 时间轴上按 ads 染色的类别。uosc 识别 ads 范围的章节命名是
-- 硬编码的（uosc/lib/utils.lua：`[sponsorblock]:` 前缀 / `^sponsors?` 开头 /
-- Segment Start/End 配对三种），chapter_range_patterns 只能扩展 openings 等
-- 四类、扩展不了 ads，故由脚本侧给起始章节标题加 `SponsorBlock: ` 前缀命中
-- `^sponsors?`（uosc 对标题 lower 后匹配，「SponsorBlock: 赞助商」以 sponsor
-- 开头；`[sponsorblock]:` 前缀路线行为等价，取显示观感更好的形式）；染色
-- 范围终点由紧随其后的「正片」章节（段终点时刻）划定。终止章节不能带前缀
-- ——带了会被 uosc 认成新的 ads 起点。日后想给其他类别（如 selfpromo）也
-- 染 ads 色，往此表加类别名即可
local ads_categories = {
    sponsor = true,
}

local function make_chapter(r)
    local all_chapters = mp.get_property_native("chapter-list") or {}
    for _, v in pairs(r) do
        -- actionType="full" 的段 segment=[0,0]（整片赞助标记），写成章节只会
        -- 产生两个 0 时刻垃圾章节，直接略过
        if v.actionType ~= "full" then
            -- 追加而非覆盖：从索引 1 写入会静默吞掉视频自带章节
            all_chapters[#all_chapters + 1] = {
                title = (ads_categories[v.category] and "SponsorBlock: " or "")
                    .. category_name(v.category),
                time  = v.segment[1],
            }
            all_chapters[#all_chapters + 1] = {
                title = "正片",
                time  = v.segment[2],
            }
        end
    end
    table.sort(all_chapters, function(a, b) return a['time'] < b['time'] end)
    mp.set_property_native("chapter-list", all_chapters)
end

-- ─── Core playback watcher ─────────────────────────────────────────────────

-- 贴尾段钳制：部分段终点与视频时长完全重合（outro/sponsor 贴尾），无钳制会把
-- 播放直接推到 EOF——跳转目标最迟落在「时长 - 0.5s」，剩余半秒自然播完，
-- 同时不早于段起点（防钳制落点回退到段前、on_seek 重置状态后无限循环）。
-- duration 未知时不钳制，保持原行为。
local function clamp_skip_target(v)
    local target   = v.segment[2] + 0.01
    local duration = mp.get_property_number("duration")
    if duration then
        target = math.min(target, duration - 0.5)
    end
    -- 下限保底：落点不得早于段起点，否则 on_seek（pos < 段起点）会重置
    -- skipped/prompted，重入段后再跳形成无限 seek 循环（贴尾短段/时长漂移段）；
    -- 正常几何下段终点+0.01 本就不小于段起点+0.01，此 max 无操作
    return math.max(target, v.segment[1] + 0.01)
end

local function do_skip(v)
    mp.osd_message(string.format("[sponsorblock] 已跳过：%s", category_name(v.category)))
    mp.set_property("time-pos", clamp_skip_target(v))
end

local function skip_ads(_, pos)
    if pos == nil or ranges == nil then return end
    local in_mute = false
    for _, v in pairs(ranges) do
        if v.actionType == "skip" and v.segment[1] <= pos and v.segment[2] > pos then
            if options.mode == "auto" then
                if not v.skipped then
                    v.skipped = true
                    local secs = math.floor(v.segment[2] - pos)
                    mp.osd_message(string.format("[sponsorblock] 快进 %d 秒（%s）",
                        secs, category_name(v.category)))
                    mp.set_property("time-pos", clamp_skip_target(v))
                end
            elseif options.mode == "manual" and not v.prompted and not v.cancelled then
                v.prompted = true
                enqueue_prompt(skip_label(v.category), function() do_skip(v) end, v)
            end
        elseif v.actionType == "mute" then
            if v.segment[1] <= pos and v.segment[2] >= pos then
                in_mute = true
            end
        elseif v.actionType == "full" and v.segment[1] <= pos and not v.full_hinted then
            -- 整片赞助段（segment=[0,0]）：不跳、仅提示一次；
            -- 若无此分支，为修贴尾钳制而简单按段跳全会 seek 到 0.01s 死循环
            v.full_hinted = true
            mp.osd_message("[sponsorblock] 本片被标记为全程赞助，不做片段跳过", 3)
        end
    end
    if in_mute then
        if not mute_forced then
            -- 进入首个 mute 段前捕获用户原静音值（此后脚本强制 true）
            mute_orig   = mp.get_property_bool("mute") or false
            mute_forced = true
        end
        mp.set_property_bool("mute", true)
    elseif mute_forced then
        -- 离开全部 mute 段：恢复用户原值
        mp.set_property_bool("mute", mute_orig)
        mute_forced = false
        mute_orig   = nil
    end
    if button_state.visible and button_state.seg then
        local s = button_state.seg
        if s.segment and pos > s.segment[2] then
            s.cancelled = true
            -- 出队已并入 hide_button 尾部，此处不重复调 process_queue
            hide_button()
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
            v.skipped   = false
        end
    end
end

-- ─── 公共的启动逻辑（拿到 video_id 后执行）─────────────────────────────────

local function start_with_id(vid, srv, cid)
    -- 显式请求 skip+mute：官方服务端 actionTypes 默认只下发 skip，不传则
    -- mute 段根本拿不到（bsbsb 不过滤，传参后行为一致）
    local url = ("%s?videoID=%s&categories=[%s]&actionTypes=[%s]")
        :format(srv, vid, options.categories, '"skip","mute"')
    if cid then
        url = url .. "&cid=" .. cid
    end
    ranges = getranges(url)
    if ranges ~= nil then
        -- bsbsb 不传 cid 时返回该 BV 全部分P 片段并集：bangumi 路径已透传 cid
        -- 精确过滤，这里再按片段自带 videoDuration 与本文件时长比对兜底（仅
        -- B 站路径；YT 的 videoID 唯一，无此问题）。容差 2s：同番剧各集时长差
        -- 远大于此，而同集元数据抖动小于此；时长极接近的不同分P 无法靠时长
        -- 区分，属已知局限
        if srv == options.bilibili_sponsor_server then
            local duration = mp.get_property_number("duration")
            if duration then
                local filtered = {}
                for _, v in pairs(ranges) do
                    if v.videoDuration == nil or math.abs(v.videoDuration - duration) <= 2 then
                        filtered[#filtered + 1] = v
                    end
                end
                ranges = filtered
            end
        end
        make_chapter(ranges)
        ON = true
        mp.observe_property("time-pos", "native", skip_ads)
        mp.register_event("seek", on_seek)
    else
        -- 请求失败（网络 / HTTP 4xx 5xx / 响应非 JSON）时给出可见反馈；
        -- 服务端正常返回的空数据（[]）不算失败，不提示
        mp.osd_message("[sponsorblock] 片段数据获取失败", 2)
    end
end

-- ─── File loaded ───────────────────────────────────────────────────────────

local function file_loaded()
    video_id    = nil
    mute_forced = false
    mute_orig   = nil

    local video_path    = mp.get_property("path", "")
    local video_referer = mp.get_property("http-header-fields", ""):match("[Rr]eferer:%s*([^,\r\n]+)") or ""
    local purl          = mp.get_property("metadata/by-key/PURL", "")

    -- ▼▼▼ 新增：优先检测 bangumi URL，提取 ep_id 并转换为 BVID ▼▼▼
    local ep_id = video_path:match("bilibili%.com/bangumi/play/ep(%d+)") or
                  video_referer:match("bilibili%.com/bangumi/play/ep(%d+)")
    if ep_id then
        local bvid, cid = get_bvid_from_epid(ep_id)
        if bvid then
            start_with_id(bvid, options.bilibili_sponsor_server, cid)
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
    -- 先清队列再隐藏：hide_button 尾部会出队弹下一个提示，换文件间隙不能弹窗
    prompt_queue = {}
    hide_button()
    if mute_forced then
        -- 文件在 mute 段内结束：先把用户原静音值恢复，再清理会话
        mp.set_property_bool("mute", mute_orig)
        mute_forced = false
        mute_orig   = nil
    end
    ranges = nil
    ON     = false
end

mp.register_event("file-loaded", file_loaded)
mp.register_event("end-file",    end_file)