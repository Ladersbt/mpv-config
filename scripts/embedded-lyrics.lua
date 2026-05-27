--[[embedded-lyrics.lua
自动提取音乐文件中的内嵌歌词并以字幕形式加载
支持：MP3 / FLAC / OGG / M4A 等内嵌 LRC 歌词
双语歌词（中日/中英/中韩）自动检测语言顺序，始终保持中文在上
依赖：系统需安装 ffmpeg 且在 PATH 中
安装：%APPDATA%\mpv\scripts\（Windows）或 ~/.config/mpv/scripts/（Linux/Mac）

input.conf 绑定示例：
  F8  script-message embedded-lyrics-toggle
  F9  script-message embedded-lyrics-save
]]

local mp = require("mp")
local options = require 'mp.options'

-- ======= 可配置项 =======
local o = {
    font_name      = "Noto Sans CJK SC",  -- 字体名
    enabled        = true,                -- 默认是否启用（false = 启动时不自动加载）
    bilingual_gap  = 2.0,                 -- 双语合并最大时间间隔（秒），超过此值不合并
}

options.read_options(o, "embedded_lyrics")

-- ========================

-- 修复：启动时初始化随机种子，避免快速切歌时产生相同临时文件名
math.randomseed(os.time())

local AUDIO_EXTS = {
    mp3=true, flac=true, ogg=true, oga=true,
    m4a=true, aac=true, opus=true, wav=true,
    wma=true, ape=true, wv=true, mka=true,
}

local tmp_files = {}

-- 当前歌曲的 ASS 内容缓存（用于保存功能）
local current_ass_content = nil
local current_audio_path  = nil
-- 修复：记录已加载的字幕轨 ID，用于精确移除
local loaded_sub_id       = nil

local function is_audio(path)
    local ext = path:match("%.([^%.]+)$")
    return ext and AUDIO_EXTS[ext:lower()]
end

local function get_tmp_dir()
    return os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
end

local function make_tmp_path(suffix)
    local dir  = get_tmp_dir()
    local sep  = package.config:sub(1,1)
    -- 加入 mp.get_time() 的微秒部分提升唯一性
    local uid  = string.format("%d_%d_%d",
        os.time(), math.random(10000, 99999),
        math.floor((mp.get_time() % 1) * 1e6))
    local name = "mpv_lyrics_" .. uid .. suffix
    return dir .. sep .. name
end

local function file_has_content(path)
    local f = io.open(path, "r")
    if not f then return false end
    local c = f:read("*all")
    f:close()
    return c and #c > 5
end

local function has_lrc_timestamps(text)
    return text:match("%[%d+:%d+[%.:%d]*%]") ~= nil
end

-- 从 ffmetadata 提取歌词标签
local function extract_lyrics_via_ffmetadata(path)
    local tmp_meta = make_tmp_path("_meta.txt")
    mp.command_native({
        name = "subprocess",
        args = {"ffmpeg", "-y", "-v", "quiet", "-i", path, "-f", "ffmetadata", tmp_meta},
        capture_stdout = false,
        capture_stderr = false,
        playback_only = false,
    })
    if not file_has_content(tmp_meta) then
        os.remove(tmp_meta)
        return nil
    end
    local f = io.open(tmp_meta, "rb")
    if not f then return nil end
    local raw = f:read("*all")
    f:close()
    os.remove(tmp_meta)

    local joined = raw:gsub("\\\n", "<<NL>>")
    local lyrics = nil
    for line in (joined .. "\n"):gmatch("([^\n]*)\n") do
        if line:lower():match("^lyrics[^=]*=") then
            local val = line:match("^[^=]+=(.*)$") or ""
            val = val:gsub("<<NL>>", "\n")
            val = val:gsub("\\n", "\n")
            val = val:gsub("\\;", ";")
            val = val:gsub("\\#", "#")
            val = val:gsub("\\\\", "\\")
            val = val:match("^%s*(.-)%s*$") or val
            if #val > 5 then
                lyrics = val
                break
            end
        end
    end
    return lyrics
end

-- 解析 LRC，返回 { {time=秒, lines={"行1","行2",...}}, ... }
local function parse_lrc(text)
    local time_to_lines = {}
    local time_order    = {}
    local seen_times    = {}

    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local tags   = {}
        local content = line
        while true do
            local m, rest = content:match("^%[(%d+:%d+[%.%d]*)%](.*)")
            if m then table.insert(tags, m); content = rest
            else break end
        end
        content = content:match("^%s*(.-)%s*$") or ""

        if #tags > 0 and content ~= "" then
            for _, tag in ipairs(tags) do
                local min, sec = tag:match("^(%d+):(%d+%.?%d*)$")
                if not min then min, sec = tag:match("^(%d+):(%d+)$") end
                if min and sec then
                    local t   = tonumber(min) * 60 + tonumber(sec)
                    local key = string.format("%.3f", t)
                    if not seen_times[key] then
                        seen_times[key] = true
                        table.insert(time_order, t)
                        time_to_lines[key] = {}
                    end
                    table.insert(time_to_lines[key], content)
                end
            end
        end
    end

    table.sort(time_order)
    local result = {}
    for _, t in ipairs(time_order) do
        local key = string.format("%.3f", t)
        if time_to_lines[key] then
            table.insert(result, {time = t, lines = time_to_lines[key]})
        end
    end
    return result
end

-- ===== 语言字符统计 =====

-- 统计日文假名（平假名 U+3040-309F，片假名 U+30A0-30FF）
local function count_kana(str)
    local count = 0
    local i = 1
    while i <= #str do
        local b1 = str:byte(i)
        if b1 == 0xE3 and i + 2 <= #str then
            local b2 = str:byte(i+1)
            local b3 = str:byte(i+2)
            if b2 == 0x81 then
                if b3 >= 0x40 then count = count + 1 end        -- 平假名
            elseif b2 == 0x82 then
                if b3 >= 0x80 then count = count + 1 end        -- 平假名尾/片假名头
            elseif b2 == 0x83 then
                count = count + 1                               -- 片假名
            end
            i = i + 3
        elseif b1 >= 0xF0 then i = i + 4
        elseif b1 >= 0xE0 then i = i + 3
        elseif b1 >= 0xC0 then i = i + 2
        else i = i + 1 end
    end
    return count
end

-- 统计韩文字符（谚文音节 U+AC00-D7A3 → EA B0 00 ~ ED 9E A3）
local function count_hangul(str)
    local count = 0
    local i = 1
    while i <= #str do
        local b1 = str:byte(i)
        if b1 >= 0xEA and b1 <= 0xED and i + 2 <= #str then
            local b2 = str:byte(i+1)
            if b1 == 0xEA and b2 >= 0xB0 then count = count + 1
            elseif b1 == 0xEB or b1 == 0xEC then count = count + 1
            elseif b1 == 0xED and b2 <= 0x9E then count = count + 1
            end
            i = i + 3
        elseif b1 >= 0xF0 then i = i + 4
        elseif b1 >= 0xE0 then i = i + 3
        elseif b1 >= 0xC0 then i = i + 2
        else i = i + 1 end
    end
    return count
end

-- 统计 ASCII 字母数量（用于判断是否为英文行）
local function count_ascii_alpha(str)
    local count = 0
    for _ in str:gmatch("[A-Za-z]") do count = count + 1 end
    return count
end

-- 统计中文字符（CJK 统一汉字 U+4E00-9FFF → E4 B8 80 ~ E9 BF BF）
-- 注意：日文汉字也在此范围，所以优先用假名来区分日文
local function count_cjk(str)
    local count = 0
    local i = 1
    while i <= #str do
        local b1 = str:byte(i)
        if b1 >= 0xE4 and b1 <= 0xE9 and i + 2 <= #str then
            count = count + 1
            i = i + 3
        elseif b1 >= 0xF0 then i = i + 4
        elseif b1 >= 0xE0 then i = i + 3
        elseif b1 >= 0xC0 then i = i + 2
        else i = i + 1 end
    end
    return count
end

-- 判断一行的主要语言
-- 返回: "zh"（中文）, "ja"（日文）, "ko"（韩文）, "en"（英文）, "other"
local function detect_lang(line)
    local kana   = count_kana(line)
    local hangul = count_hangul(line)
    local ascii  = count_ascii_alpha(line)
    local cjk    = count_cjk(line)

    if kana >= 2 then return "ja" end
    if hangul >= 2 then return "ko" end
    if cjk >= 2 and kana == 0 then return "zh" end
    if ascii >= 3 then return "en" end
    return "other"
end

-- 合并交替单行双语歌词
-- 处理"日文行/中文行/日文行/中文行"这种每行独立时间戳的格式
-- 修复：将合并间隔从 5.0 秒收紧为可配置的 bilingual_gap（默认 2.0 秒）
local function merge_adjacent_bilingual(entries)
    local single_count = 0
    for _, e in ipairs(entries) do
        if #e.lines == 1 then single_count = single_count + 1 end
    end
    if single_count < #entries * 0.8 then
        return entries
    end

    local merged = {}
    local i = 1
    while i <= #entries do
        local cur = entries[i]
        local nxt = entries[i+1]

        if nxt and #cur.lines == 1 and #nxt.lines == 1 then
            local lang_cur = detect_lang(cur.lines[1])
            local lang_nxt = detect_lang(nxt.lines[1])
            local gap      = nxt.time - cur.time
            -- 修复：间隔阈值收紧，避免跨歌段错误合并
            if lang_cur ~= lang_nxt
                and lang_cur ~= "other" and lang_nxt ~= "other"
                and gap < o.bilingual_gap
            then
                table.insert(merged, {
                    time  = cur.time,
                    lines = { cur.lines[1], nxt.lines[1] }
                })
                i = i + 2
            else
                table.insert(merged, cur)
                i = i + 1
            end
        else
            table.insert(merged, cur)
            i = i + 1
        end
    end
    return merged
end

-- 全局扫描，用投票决定第一行/第二行各是什么语言
-- 返回 swap=true 表示需要交换（第一行不是中文）

local function detect_swap(entries)
    local kana1, kana2     = 0, 0
    local hangul1, hangul2 = 0, 0
    local cjk1, cjk2       = 0, 0
    
    local lang_name = { zh="中文", ja="日文", ko="韩文", en_or_other="英文/其他" }

    for _, entry in ipairs(entries) do
        if #entry.lines >= 2 then
            local l1 = entry.lines[1]
            local l2 = entry.lines[2]
            -- 跳过元数据行（含冒号且较短）和分隔行
            local is_meta = (l1:match("[：:]") and #l1 < 40) or l1:match("^%-%-%-")
            if not is_meta then
                kana1   = kana1   + count_kana(l1)
                kana2   = kana2   + count_kana(l2)
                hangul1 = hangul1 + count_hangul(l1)
                hangul2 = hangul2 + count_hangul(l2)
                cjk1    = cjk1    + count_cjk(l1)
                cjk2    = cjk2    + count_cjk(l2)
            end
        end
    end

    mp.msg.info(string.format(
        "统计 假名1:%d 假名2:%d | 谚文1:%d 谚文2:%d | CJK1:%d CJK2:%d",
        kana1, kana2, hangul1, hangul2, cjk1, cjk2
    ))

    -- 修复：用绝对数量判断语言，而不是纯相对比较，减少 CJK 相近时的误判
    local function classify(kana, hangul, cjk)
        if kana > 5 then return "ja"
        elseif hangul > 5 then return "ko"
        elseif cjk > 3 then return "zh"
        else return "en_or_other" end
    end

    local lang1 = classify(kana1, hangul1, cjk1)
    local lang2 = classify(kana2, hangul2, cjk2)

    mp.msg.info(string.format("语言检测：行1=%s  行2=%s",lang_name[lang1] or lang1,lang_name[lang2] or lang2))

    local swap = (lang1 ~= "zh")
    if swap then
        mp.msg.info("检测第一行语言: " .. (lang_name[lang1] or lang1) .. "，自动交换为中文在上")
        mp.msg.info("行顺序已调整：" .. (lang_name[lang2] or lang2) .. "→上  " .. (lang_name[lang1] or lang1) .. "→下")
    end
    return swap
end

-- 秒数转 ASS 时间格式 H:MM:SS.cc
local function to_ass_time(sec)
    local h  = math.floor(sec / 3600)
    local m  = math.floor((sec % 3600) / 60)
    local s  = math.floor(sec % 60)
    local cs = math.floor((sec - math.floor(sec)) * 100)
    return string.format("%d:%02d:%02d.%02d", h, m, s, cs)
end

local function is_identical(a, b)
    return (a:match("^%s*(.-)%s*$")) == (b:match("^%s*(.-)%s*$"))
end

-- 生成 ASS 文件内容字符串
local function build_ass(entries)
    entries    = merge_adjacent_bilingual(entries)
    local swap = detect_swap(entries)

    local lines = {}
    table.insert(lines, "[Script Info]")
    table.insert(lines, "Title: Embedded Lyrics")
    table.insert(lines, "ScriptType: v4.00+")
    table.insert(lines, "WrapStyle: 0")
    table.insert(lines, "ScaledBorderAndShadow: yes")
    table.insert(lines, "PlayResX: 1920")
    table.insert(lines, "PlayResY: 1080")
    table.insert(lines, "")
    table.insert(lines, "[V4+ Styles]")
    table.insert(lines, "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding")
    table.insert(lines, string.format(
        "Style: Default,%s,95,&H00FFFFFF,&HF0000000,&H00000000,&H32000000,0,0,0,0,78,75,1.5,0.00,1,2,1,2,5,5,75,-1",
        o.font_name
    ))
    -- 为第二行（译文）单独定义一个 Style，避免行内 override tag 残留影响
    table.insert(lines, string.format(
        "Style: Trans,%s,63,&H00EB62A8,&HF0000000,&H00000000,&H32000000,0,0,0,0,78,75,1.5,0.00,1,1,0,2,5,5,31,-1",
        o.font_name
    ))
    table.insert(lines, "")
    table.insert(lines, "[Events]")
    table.insert(lines, "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text")

    for i, entry in ipairs(entries) do
        local end_time
        if i < #entries then end_time = entries[i+1].time
        else end_time = entry.time + 5 end
        if end_time <= entry.time then end_time = entry.time + 0.5 end

        local start_str = to_ass_time(entry.time)
        local end_str   = to_ass_time(end_time)
        local lns       = entry.lines

        if #lns == 1 then
            -- 单行歌词：直接输出一条 Dialogue
            table.insert(lines, string.format(
                "Dialogue: 0,%s,%s,Default,,0,0,0,,%s",
                start_str, end_str, lns[1]
            ))
        elseif #lns >= 2 then
            local raw1  = lns[1]:match("^%s*(.-)%s*$")
            local raw2  = lns[2]:match("^%s*(.-)%s*$")
            local line1 = swap and raw2 or raw1
            local line2 = swap and raw1 or raw2

            if is_identical(line1, line2) then
                -- 两行完全相同，只输出一条
                table.insert(lines, string.format(
                    "Dialogue: 0,%s,%s,Default,,0,0,0,,%s",
                    start_str, end_str, line1
                ))
            else
                -- 修复：拆分为两条独立 Dialogue（Layer 不同），
                -- 用 {\an8} 把主语言放顶部，译文放默认底部（Alignment=2）
                -- 这样彻底避免行内 override tag 残留问题
                table.insert(lines, string.format(
                    "Dialogue: 0,%s,%s,Default,,0,0,0,,%s",
                    start_str, end_str, line1
                ))
                table.insert(lines, string.format(
                    "Dialogue: 1,%s,%s,Trans,,0,0,0,,%s",
                    start_str, end_str, line2
                ))
            end
        end
    end

    return table.concat(lines, "\n") .. "\n"
end

-- 纯文本歌词转 SRT（无时间戳，固定间隔展示）
local function lyrics_to_srt(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then table.insert(lines, line) end
    end
    if #lines == 0 then return nil end
    local srt = {}
    for i, line in ipairs(lines) do
        local s = (i-1) * 3
        local e = i * 3
        local function fmt(sec)
            return string.format("%02d:%02d:%02d,000",
                math.floor(sec/3600), math.floor((sec%3600)/60), sec%60)
        end
        table.insert(srt, tostring(i))
        table.insert(srt, fmt(s) .. " --> " .. fmt(e))
        table.insert(srt, line)
        table.insert(srt, "")
    end
    return table.concat(srt, "\n")
end

-- 修复：加载字幕后记录 sub ID，用于后续精确移除
local function load_subtitle_file(path, title)
    -- 记录加载前的字幕轨数量，以便定位新增轨道
    local count_before = mp.get_property_number("track-list/count") or 0
    mp.commandv("sub-add", path, "select", title, "und")
    table.insert(tmp_files, path)
    -- 找到新增的字幕轨 ID
    local count_after = mp.get_property_number("track-list/count") or 0
    for idx = count_before, count_after - 1 do
        local t = mp.get_property_native("track-list/" .. idx)
        if t and t.type == "sub" then
            loaded_sub_id = t.id
            break
        end
    end
end

-- ===== 核心加载函数 =====
local function load_lyrics(path)
    current_ass_content = nil
    loaded_sub_id       = nil

    -- Step 1: 独立字幕流（如 MKA 内嵌字幕轨）
    local tmp_sub = make_tmp_path(".lrc")
    local r = mp.command_native({
        name = "subprocess",
        args = {"ffmpeg", "-y", "-v", "quiet", "-i", path, "-map", "0:s:0?", tmp_sub},
        capture_stdout = false, capture_stderr = false, playback_only = false,
    })
    if r.status == 0 and file_has_content(tmp_sub) then
        load_subtitle_file(tmp_sub, "内嵌歌词")
        mp.osd_message("♪ 已加载内嵌歌词", 3)
        return
    end
    os.remove(tmp_sub)

    -- Step 2: lyrics 元数据标签
    local lyrics = extract_lyrics_via_ffmetadata(path)
    if not lyrics or #lyrics <= 5 then
        mp.msg.info("未找到内嵌歌词")
        return
    end

    mp.msg.info("找到歌词，长度: " .. #lyrics)

    if has_lrc_timestamps(lyrics) then
        local entries = parse_lrc(lyrics)
        if entries and #entries > 0 then
            local ass = build_ass(entries)
            current_ass_content = ass
            local tmp_ass = make_tmp_path(".ass")
            local f = io.open(tmp_ass, "w")
            if f then
                f:write(ass)
                f:close()
                load_subtitle_file(tmp_ass, "内嵌歌词")
                mp.osd_message("♪ 已加载内嵌歌词", 3)
            end
        end
    else
        -- 纯文本歌词，提示用户这是静态展示
        local srt = lyrics_to_srt(lyrics)
        if srt then
            local tmp_srt = make_tmp_path(".srt")
            local f = io.open(tmp_srt, "w")
            if f then
                f:write(srt)
                f:close()
                load_subtitle_file(tmp_srt, "内嵌歌词")
                mp.osd_message("♪ 已加载内嵌歌词（纯文本，固定间隔展示）", 4)
            end
        end
    end
end

-- ===== 事件与消息注册 =====

mp.register_event("file-loaded", function()
    current_ass_content = nil
    loaded_sub_id       = nil
    local path = mp.get_property("path")
    if not path or not is_audio(path) then return end
    current_audio_path = path
    if o.enabled then
        load_lyrics(path)
    end
end)

-- script-message embedded-lyrics-toggle
-- 切换启用/禁用状态，并对当前文件立即生效
mp.register_script_message("embedded-lyrics-toggle", function()
    o.enabled = not o.enabled
    if o.enabled then
        mp.osd_message("♪ 内嵌歌词：已启用", 3)
        local path = mp.get_property("path")
        if path and is_audio(path) then
            load_lyrics(path)
        end
    else
        mp.osd_message("♪ 内嵌歌词：已禁用", 3)
        -- 修复：精确移除已加载的字幕轨，而不是无参调用 sub-remove
        if loaded_sub_id then
            mp.commandv("sub-remove", tostring(loaded_sub_id))
            loaded_sub_id = nil
        else
            -- 回退：没有记录 ID 时移除当前选中轨
            mp.commandv("sub-remove")
        end
    end
end)

-- script-message embedded-lyrics-save
-- 将当前歌曲的 ASS 歌词保存到歌曲同目录下
mp.register_script_message("embedded-lyrics-save", function()
    if not current_ass_content then
        mp.osd_message("♪ 当前无可保存的歌词（仅支持 LRC 格式内嵌歌词）", 3)
        return
    end
    if not current_audio_path then
        mp.osd_message("♪ 无法获取当前文件路径", 3)
        return
    end

    local save_path = current_audio_path:match("^(.+)%.[^%.]+$")
    if not save_path then save_path = current_audio_path end
    save_path = save_path .. "_lyrics.ass"

    local f = io.open(save_path, "w")
    if not f then
        mp.osd_message("♪ 保存失败，无法写入：" .. save_path, 4)
        return
    end
    f:write(current_ass_content)
    f:close()
    mp.osd_message("♪ 歌词已保存：" .. save_path, 4)
    mp.msg.info("已保存 ASS 歌词字幕到: " .. save_path)
end)

mp.register_event("shutdown", function()
    for _, f in ipairs(tmp_files) do os.remove(f) end
end)