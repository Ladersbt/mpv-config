-- SOURCE: https://github.com/kelciour/mpv-scripts/blob/master/sub-export.lua
-- COMMIT: 29 Aug 2018 5039d8b
-- MODIFIED: 添加了 SRT 转 ASS 功能，支持自定义样式
--
-- Usage:
-- add bindings to input.conf:
-- key   script-message-to sub_export export-selected-subtitles
--
--  Note:
--     Requires FFmpeg in PATH environment variable or edit ffmpeg_path in the script options,
--     for example, by replacing "ffmpeg" with "C:\Programs\ffmpeg\bin\ffmpeg.exe"
--  Note:
--     The script support subtitles in srt, ass, and sup formats.
--  Note:
--     A small circle at the top-right corner is a sign that export is happenning now.
--  Note:
--     The exported subtitles will be automatically selected with visibility set to true.
--  Note:
--     It could take ~1-5 minutes to export subtitles.

local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require "mp.options"

---- Script Options ----
local o = {
    ffmpeg_path = "ffmpeg",
    -- eng=English, chs=Chinese
    language = "chs",

    -- SRT 转 ASS 选项
    convert_srt_to_ass = true,  -- 是否自动将 SRT 转换为 ASS

    -- ASS 样式配置
    ass_fontname = "Arial",
    ass_fontsize = 52,
    ass_primary_colour = "&H00FFFFFF",     -- 白色（&HAABBGGRR 格式）
    ass_secondary_colour = "&H000000FF",   -- 红色
    ass_outline_colour = "&H00000000",     -- 黑色边框
    ass_back_colour = "&H80000000",        -- 半透明黑色阴影
    ass_bold = 0,                          -- 0=否, -1=是
    ass_italic = 0,
    ass_underline = 0,
    ass_strikeout = 0,
    ass_scale_x = 100,
    ass_scale_y = 100,
    ass_spacing = 0,
    ass_angle = 0,
    ass_border_style = 1,                  -- 1=边框+阴影, 3=不透明框
    ass_outline = 2.5,                     -- 边框宽度
    ass_shadow = 1.5,                      -- 阴影距离
    ass_alignment = 2,                     -- 2=底部居中
    ass_margin_l = 20,
    ass_margin_r = 20,
    ass_margin_v = 20,
    ass_encoding = 1,
}

options.read_options(o)
------------------------

local is_windows = package.config:sub(1, 1) == "\\" -- detect path separator, windows uses backslashes

local TEMP_DIR = os.getenv("TEMP") or "/tmp"

local function is_writable(path)
    local file = io.open(path, "w")
    if file then
        file:close()
        os.remove(path)
        return true
    end
    return false
end

-- 生成 ASS 样式字符串
local function generate_ass_style()
    return string.format(
        "Style: Default,%s,%d,%s,%s,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%.1f,%.1f,%d,%d,%d,%d,%d",
        o.ass_fontname,
        o.ass_fontsize,
        o.ass_primary_colour,
        o.ass_secondary_colour,
        o.ass_outline_colour,
        o.ass_back_colour,
        o.ass_bold,
        o.ass_italic,
        o.ass_underline,
        o.ass_strikeout,
        o.ass_scale_x,
        o.ass_scale_y,
        o.ass_spacing,
        o.ass_angle,
        o.ass_border_style,
        o.ass_outline,
        o.ass_shadow,
        o.ass_alignment,
        o.ass_margin_l,
        o.ass_margin_r,
        o.ass_margin_v,
        o.ass_encoding
    )
end

-- 修改 ASS 文件样式
local function modify_ass_style(ass_file_path)
    local file = io.open(ass_file_path, "r")
    if not file then
        msg.error("无法打开 ASS 文件: " .. ass_file_path)
        return false
    end

    local content = file:read("*all")
    file:close()

    -- 替换默认样式
    local custom_style = generate_ass_style()
    content = content:gsub("Style: Default,[^\n]+", custom_style)

    -- 写回文件
    file = io.open(ass_file_path, "w")
    if not file then
        msg.error("无法写入 ASS 文件: " .. ass_file_path)
        return false
    end

    file:write(content)
    file:close()

    return true
end

-- 构造 FFmpeg 参数数组（直接传参，避免 shell 引号和路径空格问题）
-- 原版用字符串拼 shell 命令再丢给 powershell/bash，路径含空格或特殊字符时会出错。
--       改为直接向 subprocess 传参数数组，ffmpeg 直接收到路径，不经过任何 shell 解析。
local function make_ffmpeg_args(...)
    local t = { o.ffmpeg_path, "-y", "-hide_banner", "-loglevel", "error" }
    for _, v in ipairs({...}) do
        t[#t + 1] = v
    end
    return t
end

-- 转换 SRT 到 ASS
local function convert_srt_to_ass(srt_path)
    local ass_path = srt_path:gsub("%.srt$", ".ass")

    if o.language == 'chs' then
        msg.info("正在转换 SRT 为 ASS 格式...")
        mp.osd_message("正在转换 SRT 为 ASS 格式...")
    else
        msg.info("Converting SRT to ASS format...")
        mp.osd_message("Converting SRT to ASS format...")
    end

    local args = make_ffmpeg_args("-i", srt_path, ass_path)
    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = args
    })

    if res.status ~= 0 then
        msg.error("SRT 转 ASS 失败")
        return nil
    end

    -- 修改 ASS 样式
    if modify_ass_style(ass_path) then
        if o.language == 'chs' then
            msg.info("已转换为 ASS 格式")
            mp.osd_message("已转换为 ASS 格式")
        else
            msg.info("Converted to ASS format")
            mp.osd_message("Converted to ASS format")
        end
        return ass_path
    end

    return nil
end

-- 补上 local，process 原先是隐式全局函数
-- 将 subtitles_file / args 改为参数传入，消除隐式全局变量
local function process(is_srt, subtitles_file, args)
    local screenx, screeny, aspect = mp.get_osd_size()

    mp.set_osd_ass(screenx, screeny, "{\\an9}● ")
    local res = mp.command_native({ name = "subprocess", capture_stdout = true, playback_only = false, args = args })
    mp.set_osd_ass(screenx, screeny, "")

    if res.status == 0 then
        if o.language == 'chs' then
            msg.info("当前字幕已导出")
            mp.osd_message("当前字幕已导出")
        else
            msg.info("Finished exporting subtitles")
            mp.osd_message("Finished exporting subtitles")
        end

        -- 如果是 SRT 且启用了转换，则转换为 ASS
        local final_subtitles_file = subtitles_file
        if is_srt and o.convert_srt_to_ass then
            local ass_file = convert_srt_to_ass(subtitles_file)
            if ass_file then
                final_subtitles_file = ass_file
            end
        end

        mp.commandv("sub-add", final_subtitles_file)
        mp.set_property("sub-visibility", "yes")
        
        mp.commandv("script-message", "sub-export-done", "success", final_subtitles_file)

    else
        if o.language == 'chs' then
            msg.info("当前字幕导出失败")
            mp.osd_message("当前字幕导出失败, 查看控制台获取更多信息.")
        else
            msg.info("Failed to export subtitles")
            mp.osd_message("Failed to export subtitles, check console for more info.")
        end

        mp.commandv("script-message", "sub-export-done", "fail")

    end
end

local function export_selected_subtitles()
    local i = 0
    local tracks_count = mp.get_property_number("track-list/count")
    while i < tracks_count do
        local track_type = mp.get_property(string.format("track-list/%d/type", i))
        local track_index = mp.get_property_number(string.format("track-list/%d/ff-index", i))
        local track_selected = mp.get_property(string.format("track-list/%d/selected", i))
        local track_title = mp.get_property(string.format("track-list/%d/title", i))
        local track_lang = mp.get_property(string.format("track-list/%d/lang", i))
        local track_external = mp.get_property(string.format("track-list/%d/external", i))
        local track_codec = mp.get_property(string.format("track-list/%d/codec", i))
        local path = mp.get_property('path')
        local dir, filename = utils.split_path(path)
        local fname = mp.get_property("filename/no-ext")
        local index = string.format("0:%d", track_index)

        if track_type == "sub" and track_selected == "yes" then
            if track_external == "yes" then
                if o.language == 'chs' then
                    msg.info("错误:已选择外部字幕")
                    mp.osd_message("错误:已选择外部字幕", 2)
                else
                    msg.info("Error: external subtitles have been selected")
                    mp.osd_message("Error: external subtitles have been selected", 2)
                end
                return
            end

            local video_file = utils.join_path(dir, filename)

            local subtitles_ext = ".srt"
            local is_srt = true
            if string.find(track_codec, "ass") ~= nil then
                subtitles_ext = ".ass"
                is_srt = false
            elseif string.find(track_codec, "pgs") ~= nil then
                subtitles_ext = ".sup"
                is_srt = false
            end

            if track_lang ~= nil then
                if track_title ~= nil then
                    subtitles_ext = "." .. track_title .. "." .. track_lang .. subtitles_ext
                else
                    subtitles_ext = "." .. track_lang .. subtitles_ext
                end
            end

            local subtitles_file = utils.join_path(dir, fname .. subtitles_ext)

            if not is_writable(subtitles_file) then
                subtitles_file = utils.join_path(TEMP_DIR, fname .. subtitles_ext)
            end

            if o.language == 'chs' then
                msg.info("正在导出当前字幕")
                mp.osd_message("正在导出当前字幕")
            else
                msg.info("Exporting selected subtitles")
                mp.osd_message("Exporting selected subtitles")
            end

            local args = make_ffmpeg_args(
                "-i", video_file,
                "-map", index,
                "-vn", "-an",
                "-c:s", "copy",
                subtitles_file
            )

            mp.add_timeout(mp.get_property_number("osd-duration") * 0.001, function()
                process(is_srt, subtitles_file, args)
            end)

            break
        end

        i = i + 1
    end
end

mp.register_script_message("export-selected-subtitles", export_selected_subtitles)
