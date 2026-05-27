-- cut_sub.lua
-- 功能：在 mpv 中标记 A/B 时间点，裁剪对应时间段的外挂 .ass 字幕和弹幕文件
-- 优化点：
--   1. 修复 gsub 时间戳替换的通配符 bug，改用精确位置拼接
--   2. A/B 顺序校验，B <= A 时自动提示并重置
--   3. OSD 消息合并输出，避免互相覆盖
--   4. 统一扫描同目录 .ass 文件，按关键词分类为弹幕 / 字幕，互不干扰
--   5. 控制台日志分类打印，不再混淆

local mp    = require 'mp'
local msg   = require 'mp.msg'
local utils = require 'mp.utils'

local a_time, b_time = nil, nil

-- 格式化秒数为 MMmSSs
local function fmt_ms(t)
    local m = math.floor(t / 60)
    local s = math.floor(t % 60)
    return string.format("%02dm%02ds", m, s)
end

local function clear_marks()
    a_time, b_time = nil, nil
    msg.info("已清除 A/B 标记")
    mp.osd_message("清除标记", 1)
end

-- 将 ASS 时间戳字符串转换为秒数
local function ts_to_sec(t)
    local h, m, s = t:match("(%d+):(%d+):(%d+%.%d+)")
    if not h then return nil end
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
end

-- 将秒数转换为 ASS 时间戳字符串（H:MM:SS.cc）
local function sec_to_ts(x)
    local h = math.floor(x / 3600)
    local m = math.floor((x % 3600) / 60)
    local s = x % 60
    return string.format("%d:%02d:%05.2f", h, m, s)
end

-- 安全替换 Dialogue 行中的时间戳（按字节位置定位，避免 gsub pattern 通配符问题）
local function replace_timestamps(line, old_sh, old_eh, new_sh, new_eh)
    -- Dialogue 行格式：Dialogue: Layer,Start,End,...
    -- 找到第一个逗号后的 Start 时间戳位置
    local after_first_comma = line:find(",", 1, true)
    if not after_first_comma then return line end

    local s_start = after_first_comma + 1
    local s_end   = s_start + #old_sh - 1

    -- 验证位置是否确实是 old_sh
    if line:sub(s_start, s_end) ~= old_sh then return line end

    local after_second_comma = s_end + 1  -- 应该是逗号
    if line:sub(after_second_comma, after_second_comma) ~= "," then return line end

    local e_start = after_second_comma + 1
    local e_end   = e_start + #old_eh - 1

    if line:sub(e_start, e_end) ~= old_eh then return line end

    -- 重新拼接
    return line:sub(1, s_start - 1) .. new_sh
        .. "," .. new_eh
        .. line:sub(e_end + 1)
end

-- 裁剪 ASS 文件，保留 ab_start ~ ab_end 之间的字幕行，并将时间轴偏移到从 0 开始
local function cut_ass(input_path, output_path, ab_start, ab_end)
    local infile = io.open(input_path, "r")
    if not infile then return false, "无法打开: " .. input_path end

    local pre_event_lines = {}
    local event_lines     = {}
    local in_events       = false

    for line in infile:lines() do
        -- 去除行尾 \r（Windows 换行兼容）
        line = line:gsub("\r$", "")

        if line:match("^%[Events%]") then
            in_events = true
            table.insert(event_lines, line)
        elseif in_events then
            if line:match("^Dialogue:") then
                local sh, eh = line:match("^Dialogue:%s*%d+,(%d+:%d+:%d+%.%d+),(%d+:%d+:%d+%.%d+)")
                if sh and eh then
                    local st = ts_to_sec(sh)
                    local et = ts_to_sec(eh)
                    if st and et and et >= ab_start and st <= ab_end then
                        local new_sh = sec_to_ts(math.max(0, st - ab_start))
                        local new_eh = sec_to_ts(math.max(0, et - ab_start))
                        local newline = replace_timestamps(line, sh, eh, new_sh, new_eh)
                        table.insert(event_lines, newline)
                    end
                end
            else
                table.insert(event_lines, line)
            end
        else
            table.insert(pre_event_lines, line)
        end
    end
    infile:close()

    local outfile = io.open(output_path, "w")
    if not outfile then return false, "无法写入: " .. output_path end

    for _, l in ipairs(pre_event_lines) do outfile:write(l, "\n") end
    for _, l in ipairs(event_lines)    do outfile:write(l, "\n") end
    outfile:close()

    return true
end

-- 弹幕关键词（匹配文件名中出现这些词则认为是弹幕）
local DANMU_KEYWORDS = { "danmu", "弹幕", "danmaku", "comment", "barrages" }

local function is_danmu_file(name)
    local lc = name:lower()
    for _, kw in ipairs(DANMU_KEYWORDS) do
        if lc:find(kw, 1, true) then return true end
    end
    return false
end

-- 字幕优先级规则（越靠前分数越低，优先级越高）
-- 分组：双语 > 简体 > 繁体 > 其他中文 > 日语 > 英语 > 其他已知语言
-- 匹配方式：关键词前后必须是 . _ - 或字符串边界，避免误匹配文件名主体部分
-- 每条规则：{ pattern, score }，score 越小优先级越高
-- 规则表里统一写原始字符串，转义由 sub_priority_score 统一处理，不要在这里预转义
local SUB_RULES = {
    -- 双语（含中文+其他语言组合）
    { "zh.chs",         1 },
    { "chs.zh",         1 },
    { "sc.jp",          1 },
    { "jp.sc",          1 },
    { "zh-jp",          1 },
    { "jp-zh",          1 },
    { "chs&jpn",        1 },
    { "jpn&chs",        1 },
    { "zh-en",          1 },
    { "en-zh",          1 },
    { "chs&eng",        1 },
    { "eng&chs",        1 },
    { "bilingual",      1 },
    { "双语",           1 },
    { "简繁",           2 },   -- 简繁双语略低于纯双语
    { "繁简",           2 },
    { "chs.cht",        2 },
    { "cht.chs",        2 },

    -- 简体中文
    { "sc",             3 },
    { "chs",            3 },
    { "zh-hans",        3 },
    { "zh-cn",          3 },
    { "zh-sg",          3 },
    { "简体",           3 },
    { "简中",           3 },
    { "国语",           3 },

    -- 繁体中文
    { "tc",             4 },
    { "cht",            4 },
    { "zh-hant",        4 },
    { "zh-tw",          4 },
    { "zh-hk",          4 },
    { "zh-mo",          4 },
    { "繁体",           4 },
    { "繁中",           4 },
    { "粤语",           4 },

    -- 泛中文（无法区分简繁）
    { "zh",             5 },
    { "chi",            5 },
    { "chinese",        5 },
    { "中文",           5 },
    { "中字",           5 },

    -- 日语
    { "jp",             6 },
    { "jpn",            6 },
    { "japanese",       6 },
    { "日语",           6 },
    { "日文",           6 },
    { "日本語",         6 },

    -- 英语
    { "en",             7 },
    { "eng",            7 },
    { "english",        7 },

    -- 其他常见语言（韩、法、德、西、葡、俄、阿拉伯等）
    { "ko",             8 },  { "kor",    8 },  { "korean",     8 },
    { "fr",             8 },  { "fre",    8 },  { "french",     8 },
    { "de",             8 },  { "ger",    8 },  { "german",     8 },
    { "es",             8 },  { "spa",    8 },  { "spanish",    8 },
    { "pt",             8 },  { "por",    8 },  { "portuguese", 8 },
    { "ru",             8 },  { "rus",    8 },  { "russian",    8 },
    { "ar",             8 },  { "ara",    8 },  { "arabic",     8 },
    { "it",             8 },  { "ita",    8 },  { "italian",    8 },
    { "th",             8 },  { "tha",    8 },  { "thai",       8 },
    { "vi",             8 },  { "vie",    8 },  { "vietnamese", 8 },
    { "id",             8 },  { "ind",    8 },  { "indonesian", 8 },
    { "ms",             8 },  { "may",    8 },  { "malay",      8 },
}


-- 将 pattern 中的 % 转义为 lua pattern 安全形式，并包裹分隔符边界
--local function make_boundary_pattern(kw)
--    -- 转义 lua pattern 特殊字符（kw 中可能有 - . 等）
--    local escaped = kw:gsub("([%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
--    -- 边界：前后是 . _ - 或字符串开头/结尾
--    return "[%.%_%-%s]" .. escaped .. "[%.%_%-%s]"
--        .. "|^" .. escaped .. "[%.%_%-%s]"
--        .. "|[%.%_%-%s]" .. escaped .. "$"
--        .. "|^" .. escaped .. "$"
--end

local function sub_priority_score(name)
    local lc = name:lower()
    -- 在文件名两端加分隔符，简化边界匹配
    local padded = "." .. lc .. "."
    local best = #SUB_RULES + 10  -- 默认最低优先级
    for _, rule in ipairs(SUB_RULES) do
        local kw, score = rule[1], rule[2]
        local escaped = kw:gsub("([%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
        -- 匹配：分隔符 + 关键词 + 分隔符（padded 已在两端加了 .）
        local pat = "[%.%_%- ]" .. escaped .. "[%.%_%- ]"
        if padded:match(pat) and score < best then
            best = score
        end
    end
    return best
end

-- 扫描视频同目录下的所有关联 .ass 文件，分类为弹幕列表和字幕列表
-- 关联规则：文件名以 video_base 开头，且以 .ass 结尾
local function scan_ass_files(video_path)
    local dir, fname = utils.split_path(video_path)
    -- 取主文件名（去掉最后一个后缀）
    local base = fname:match("^(.+)%.[^%.]+$") or fname

    local danmu_files = {}
    local sub_files   = {}

    local all = utils.readdir(dir, "files") or {}
    for _, name in ipairs(all) do
        local lc = name:lower()
        -- 必须以 base 开头（忽略大小写）且以 .ass 结尾，且不是视频文件本身
        if lc:find(base:lower(), 1, true) == 1 and lc:match("%.ass$") then
            local full = utils.join_path(dir, name)
            if is_danmu_file(name) then
                table.insert(danmu_files, { name = name, path = full })
                msg.info("[弹幕候选] " .. name)
            else
                table.insert(sub_files, { name = name, path = full, score = sub_priority_score(name) })
                msg.info("[字幕候选] " .. name)
            end
        end
    end

    -- 字幕按优先级排序
    table.sort(sub_files, function(a, b) return a.score < b.score end)

    return danmu_files, sub_files
end

-- 主逻辑
mp.register_script_message("cut_sub_ab", function()
    local t = mp.get_property_number("time-pos", 0)

    -- 第一次：标记 A
    if not a_time then
        a_time = t
        mp.osd_message("标记起点: " .. fmt_ms(t), 1)
        msg.info("标记起点: " .. t)
        return
    end

    -- 第二次：标记 B，校验顺序
    if not b_time then
        if t <= a_time then
            mp.osd_message("⚠️ 终点必须在起点之后，请重新标记", 2)
            msg.warn(string.format("终点 %.2fs <= 起点 %.2fs，已重置", t, a_time))
            a_time, b_time = nil, nil
            return
        end
        b_time = t
        mp.osd_message("标记终点: " .. fmt_ms(t), 1)
        msg.info("标记终点: " .. t)
    else
        -- 第三次：清除重置
        clear_marks()
        return
    end

    local video_path = mp.get_property("path")
    if not video_path then
        mp.osd_message("导出失败：无打开的文件", 2)
        clear_marks()
        return
    end

    local dir, fname = utils.split_path(video_path)
    local base = fname:match("^(.+)%.[^%.]+$") or fname
    local stamp = fmt_ms(a_time) .. "-" .. fmt_ms(b_time)

    local danmu_files, sub_files = scan_ass_files(video_path)

    local osd_lines  = {}
    local did_any    = false

    -- 处理弹幕
    for _, df in ipairs(danmu_files) do
        -- 输出文件名：base_stamp_danmu_原始弹幕名中去掉base前缀部分.ass
        -- 简化为统一命名：如有多个弹幕文件则带序号
        local suffix = df.name:match("^.+" .. base .. "(.*)%.ass$") or ""
        if suffix == "" then suffix = "_danmu" end
        -- 确保 suffix 以 _ 开头
        if suffix:sub(1,1) ~= "_" then suffix = "_" .. suffix end
        local out_path = utils.join_path(dir, base .. "_" .. stamp .. suffix .. ".ass")
        local ok, err = cut_ass(df.path, out_path, a_time, b_time)
        if ok then
            msg.info("弹幕输出: " .. out_path)
            table.insert(osd_lines, "✅ 弹幕: " .. (df.name:match("[^\\/]+$") or df.name))
            did_any = true
        else
            msg.error("弹幕裁剪失败 [" .. df.name .. "]: " .. tostring(err))
            table.insert(osd_lines, "❌ 弹幕失败: " .. df.name)
        end
    end

    -- 处理字幕（只取优先级最高的一个，如需全部导出可改为遍历 sub_files）
    if #sub_files > 0 then
        local sf = sub_files[1]
        local out_path = utils.join_path(dir, base .. "_" .. stamp .. "_sub.ass")
        local ok, err = cut_ass(sf.path, out_path, a_time, b_time)
        if ok then
            msg.info("字幕输出: " .. out_path)
            table.insert(osd_lines, "✅ 字幕: " .. (sf.name:match("[^\\/]+$") or sf.name))
            did_any = true
        else
            msg.error("字幕裁剪失败 [" .. sf.name .. "]: " .. tostring(err))
            table.insert(osd_lines, "❌ 字幕失败: " .. sf.name)
        end
    end

    -- 合并 OSD 输出
    if did_any then
        mp.osd_message(table.concat(osd_lines, "\n"), 4)
    else
        mp.osd_message("⚠️ 未找到可裁剪的 .ass 文件", 3)
        msg.warn("没有找到弹幕或字幕文件，目录: " .. dir)
    end

    clear_marks()
end)

-- 清除标记
mp.register_script_message("cut_sub_clear", function()
    clear_marks()
end)