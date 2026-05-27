--[[
    功能：智能提取视频附件字体至 fonts 文件夹
    优化：支持增量提取（只提取缺失文件）、Windows 路径修正、防死锁信号
    依赖：mkvmerge, mkvextract (需加入系统环境变量)
]]

local utils = require 'mp.utils'
local msg = require 'mp.msg'

-- ==========================================
-- 1. 辅助与 OSD 显示
-- ==========================================

local is_windows = (package.config:sub(1,1) == '\\')
local overlay = mp.create_osd_overlay("ass-events")
local timer = nil


-- 路径规范化函数
local function normalize_path(path)
    if is_windows then
        return path:gsub("/", "\\")
    else
        return path
    end
end

-- 自定义 OSD 显示
local function show_osd(text, duration)
    duration = duration or 2
    -- {\an7} 左上对齐
    -- {\pos(20, 150)} 坐标：X=20, Y=150
    -- {\fs35} 字号35
    -- {\1c&H00FFFF&} 黄色文字
    local style = "{\\an7\\pos(20, 150)\\fs35\\bord2\\1c&H00FFFF&}"
    
    overlay.data = style .. text
    overlay:update()
    
    if timer then timer:kill() end
    timer = mp.add_timeout(duration, function()
        overlay.data = ""
        overlay:update()
    end)
end

-- 安全执行命令封装
local function run_process(args)
    return utils.subprocess({
        args = args,
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true
    })
end

-- 检查文件是否存在
local function file_exists(name)
    local f = io.open(name, "r")
    if f ~= nil then io.close(f) return true else return false end
end

-- ==========================================
-- 2. 核心提取逻辑
-- ==========================================

local function extract_fonts_func()
    local path = mp.get_property("path")
	-- 1. 检查是否有文件在播放
	if not path then
		show_osd("⚠️ 当前未播放任何媒体文件")
		mp.commandv("script-message", "fonts-extracted-done")
		return
	end

	-- 2. 检查是否为网络流、特殊协议或盘片（匹配 :// 或类似 bd:// 的协议）
	local is_stream = path:match("://") or mp.get_property_bool("demuxer-via-network")
	if is_stream then
		show_osd("⚠️ 正在播放流媒体或特殊协议，无法提取字体")
		mp.commandv("script-message", "fonts-extracted-done")
		return
	end

    -- 规范化输入路径
    local normalized_path = normalize_path(path)
    
    local dir, filename = utils.split_path(path)
    local fonts_dir = utils.join_path(dir, "fonts")

    msg.info("正在分析视频: " .. filename)

    -- 1. 获取附件列表
    local probe = run_process({"mkvmerge", "-i", "-F", "json", normalized_path})
    if probe.status ~= 0 then
        show_osd("❌ 失败: 请确保已安装并配置 MKVToolNix 环境变量", 4)
        mp.commandv("script-message", "fonts-extracted-done")
        return
    end

    local info = utils.parse_json(probe.stdout)
    -- 严谨检查：确保 info 存在且 attachments 是一个表
    if not info or not info.attachments or #info.attachments == 0 then
        show_osd("ℹ️ 该视频不含附件字体")
        mp.commandv("script-message", "fonts-extracted-done") -- 防止死锁
        return
    end

    -- 2. 筛选字体并构建所有可能的任务
    local all_tasks = {}
    local font_extensions = {ttf = true, otf = true, ttc = true, woff = true, woff2 = true}
    
    for _, att in ipairs(info.attachments) do
        local ext = att.file_name:match("^.+(%..+)$")
        if ext and font_extensions[ext:lower():sub(2)] then
            table.insert(all_tasks, {
                id = att.id,
                name = att.file_name,
                out = utils.join_path(fonts_dir, att.file_name)
            })
        end
    end

    if #all_tasks == 0 then
        show_osd("ℹ️ 未发现可识别的附件字体")
        mp.commandv("script-message", "fonts-extracted-done")
        return
    end

    -- 3. 过滤出真正需要提取的任务 (增量提取)
    local tasks_to_do = {}
    for _, t in ipairs(all_tasks) do
        if not file_exists(t.out) then
            table.insert(tasks_to_do, t)
        end
    end

    -- 如果所有任务对应的文件都存在
    if #tasks_to_do == 0 then
        msg.info("所有字体已存在，跳过提取")
        show_osd("✅ 字体校验完整，跳过提取", 1.5)
        mp.commandv("script-message", "fonts-extracted-done")
        return
    end

    -- 4. 创建文件夹 (统一路径处理)
    local normalized_fonts_dir = normalize_path(fonts_dir)
    if is_windows then
        run_process({"cmd", "/c", "if not exist \"" .. normalized_fonts_dir .. "\" mkdir \"" .. normalized_fonts_dir .. "\""})
    else
        run_process({"mkdir", "-p", fonts_dir})
    end

    -- 5. 执行提取 (统一路径处理)
    local extract_args = {"mkvextract", normalized_path, "attachments"}
    for _, t in ipairs(tasks_to_do) do
        local normalized_out = normalize_path(t.out)
        table.insert(extract_args, tostring(t.id) .. ":" .. normalized_out)
    end

    show_osd("⏳ 正在提取 " .. #tasks_to_do .. " 个字体...")
    
    local res = run_process(extract_args)
    
    if res.status == 0 then
        msg.info("提取成功，存放目录: " .. fonts_dir)
        show_osd("✅ 成功提取 " .. #tasks_to_do .. " 个字体", 3)
        mp.commandv("script-message", "fonts-extracted-done")
    else
        msg.error("提取出错: " .. (res.stderr or "查看日志"))
        show_osd("❌ 提取失败，请检查控制台", 3)
        mp.commandv("script-message", "fonts-extracted-done")
    end
end

-- ==========================================
-- 3. 注册接口
-- ==========================================

-- 注册脚本绑定名，用户可在 input.conf 中自定义按键
-- 示例：ctrl+f script-binding extract-fonts
mp.add_key_binding(nil, "extract-fonts", extract_fonts_func)

-- 同时注册脚本消息接口，方便其他脚本调用
-- 示例：script-message extract-fonts
mp.register_script_message("extract-fonts", extract_fonts_func)