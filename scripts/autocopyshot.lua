-- autocopyshot.lua
-- MPV 截图后自动复制到剪贴板
-- 双路线机制：路线1保存配置格式，路线2临时图片复制到剪贴板

local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

local opts = {
    -- 临时截图格式设置
    temp_format = "jpg",                    -- 临时文件格式: png, jpg, webp
    temp_png_compression = 7,               -- PNG 压缩等级 (0-9)
    temp_png_filter = 5,                    -- PNG 过滤器 (0-5)
    temp_jpg_quality = 95,                  -- JPG 质量 (0-100)
    temp_webp_quality = 95,                 -- WEBP 质量 (0-100)
    temp_webp_compression = 4,              -- WEBP 压缩等级 (0-6)
    
    -- OSD 消息设置
    osd_duration = 0.8,                     -- OSD 显示时长（秒）
    osd_message_success = "✅ 截图已保存并复制到剪贴板",
    osd_message_fail = "❌ 截图已保存但复制失败",
    osd_message_subtitles = "同源尺寸-有字幕",
    osd_message_video = "同源尺寸-无字幕",
    osd_message_window = "实际尺寸-有字幕",
    
    -- 其他设置
    window_screenshot_delay_offset = 0.03,  -- 窗口截图额外延迟（秒），在 osd_duration 基础上增加
    copy_delay = 0.3,                       -- 复制延迟（秒），确保文件写入完成
}

-- 读取配置文件
options.read_options(opts, 'autocopyshot')

-- 临时截图文件路径
local temp_file = os.getenv('TEMP') .. '\\mpv-screenshot-temp.' .. opts.temp_format

-- 设置临时截图的 mpv 选项
local function set_temp_screenshot_options()
    local backup = {}
    
    -- 备份当前设置
    backup.format = mp.get_property("screenshot-format")
    backup.png_compression = mp.get_property("screenshot-png-compression")
    backup.png_filter = mp.get_property("screenshot-png-filter")
    backup.jpeg_quality = mp.get_property("screenshot-jpeg-quality")
    backup.webp_quality = mp.get_property("screenshot-webp-quality")
    backup.webp_compression = mp.get_property("screenshot-webp-compression")
    
    -- 设置临时截图选项
    mp.set_property("screenshot-format", opts.temp_format)
    
    if opts.temp_format == "png" then
        mp.set_property("screenshot-png-compression", tostring(opts.temp_png_compression))
        mp.set_property("screenshot-png-filter", tostring(opts.temp_png_filter))
    elseif opts.temp_format == "jpg" or opts.temp_format == "jpeg" then
        mp.set_property("screenshot-jpeg-quality", tostring(opts.temp_jpg_quality))
    elseif opts.temp_format == "webp" then
        mp.set_property("screenshot-webp-quality", tostring(opts.temp_webp_quality))
        mp.set_property("screenshot-webp-compression", tostring(opts.temp_webp_compression))
    end
    
    return backup
end

-- 恢复原始截图选项
local function restore_screenshot_options(backup)
    if backup.format then
        mp.set_property("screenshot-format", backup.format)
    end
    if backup.png_compression then
        mp.set_property("screenshot-png-compression", backup.png_compression)
    end
    if backup.png_filter then
        mp.set_property("screenshot-png-filter", backup.png_filter)
    end
    if backup.jpeg_quality then
        mp.set_property("screenshot-jpeg-quality", backup.jpeg_quality)
    end
    if backup.webp_quality then
        mp.set_property("screenshot-webp-quality", backup.webp_quality)
    end
    if backup.webp_compression then
        mp.set_property("screenshot-webp-compression", backup.webp_compression)
    end
end

-- 复制图片文件到剪贴板的函数
local function copy_to_clipboard(file_path)
    if not file_path or file_path == "" then
        msg.warn("截图路径为空")
        return false
    end

    -- 转换为 Windows 路径格式
    local win_path = file_path:gsub("/", "\\")
    
    -- 使用 PowerShell 命令复制图片
    local ps_cmd = string.format(
        "Add-Type -Assembly System.Windows.Forms, System.Drawing; " ..
        "[Windows.Forms.Clipboard]::SetImage([Drawing.Image]::FromFile('%s'))",
        win_path:gsub("'", "''")
    )
    
    local cmd = {
        'powershell', '-NoProfile', '-Command', ps_cmd
    }

    -- 异步执行复制命令
    mp.command_native_async(
        {'run', unpack(cmd)},
        function(success, result, error)
            if success then
                msg.info("截图已复制到剪贴板")
                mp.osd_message(opts.osd_message_success, opts.osd_duration)
            else
                msg.error("复制到剪贴板失败: " .. (error or "未知错误"))
                mp.osd_message(opts.osd_message_fail, opts.osd_duration * 1.5)
            end
        end
    )
end

-- 截图并复制到剪贴板的核心函数
local function screenshot_and_copy(screenshot_flag, osd_type_message)
    -- 显示截图类型提示
    if osd_type_message then
        mp.osd_message(osd_type_message, opts.osd_duration)
    end
    
    -- 窗口截图需要延迟，避免 OSD 被截入
    local screenshot_delay = (screenshot_flag == "window") and 
                             (opts.osd_duration + opts.window_screenshot_delay_offset) or 0
    
    mp.add_timeout(screenshot_delay, function()
        -- 路线 1: 使用默认配置截图（保存到配置的目录）
        local result1 = mp.command_native({
            name = "screenshot",
            flags = screenshot_flag
        })
        
        if result1 and result1.filename then
            msg.info("主截图已保存: " .. result1.filename)
        else
            msg.warn("主截图保存失败")
        end
        
        -- 路线 2: 截图到临时文件（用于复制到剪贴板）
        -- 备份当前截图设置
        local backup = set_temp_screenshot_options()
        
        -- 截图到临时文件
        mp.commandv('screenshot-to-file', temp_file, screenshot_flag)
        
        -- 恢复原始截图设置
        restore_screenshot_options(backup)
        
        -- 延迟后复制到剪贴板
        mp.add_timeout(opts.copy_delay, function()
            copy_to_clipboard(temp_file)
        end)
    end)
end

-- 注册脚本消息接口（供 input.conf 调用）
-- 截图（包含字幕）
mp.register_script_message("screenshot-subtitles-copy", function()
    screenshot_and_copy("subtitles", opts.osd_message_subtitles)
end)

-- 截图（不包含字幕）
mp.register_script_message("screenshot-video-copy", function()
    screenshot_and_copy("video", opts.osd_message_video)
end)

-- 截图（窗口）
mp.register_script_message("screenshot-window-copy", function()
    screenshot_and_copy("window", opts.osd_message_window)
end)