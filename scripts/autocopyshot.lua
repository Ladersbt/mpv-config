--[[ autocopyshot.lua
MPV 截图后自动复制到剪贴板
双路线机制：路线1保存配置格式，路线2临时图片复制到剪贴板
]]

local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

-- ==========================================
-- 非 Windows 环境保护
-- ==========================================
local ffi_ok, ffi = pcall(require, 'ffi')
if not ffi_ok then
    msg.error("autocopyshot: 无法加载 ffi 模块，脚本退出")
    return
end

local function safe_load(lib)
    local ok, result = pcall(ffi.load, lib)
    if not ok then
        msg.error("autocopyshot: 无法加载 " .. lib .. "，脚本退出（仅支持 Windows）")
        return nil
    end
    return result
end

-- ==========================================
-- Win32 API 与 GDI+ 声明
-- ==========================================
ffi.cdef[[
    // 编码转换（kernel32）
    int MultiByteToWideChar(unsigned int CodePage, unsigned int dwFlags,
        const char *lpMultiByteStr, int cbMultiByte,
        wchar_t *lpWideCharStr, int cchWideChar);

    // 堆内存（kernel32）
    void *GlobalAlloc(unsigned int uFlags, size_t dwBytes);
    void *GlobalLock(void *hMem);
    int   GlobalUnlock(void *hMem);
    void *GlobalFree(void *hMem);

    // 剪贴板操作（user32）
    int    OpenClipboard(void *hWndNewOwner);
    int    EmptyClipboard(void);
    void  *SetClipboardData(unsigned int uFormat, void *hMem);
    int    CloseClipboard(void);

    // DC（user32）
    void  *GetDC(void *hWnd);
    int    ReleaseDC(void *hWnd, void *hDC);

    // GDI 对象与像素读取（gdi32）
    int    DeleteObject(void *hObject);

    typedef struct {
        int  biSize;
        int  biWidth;
        int  biHeight;
        short biPlanes;
        short biBitCount;
        unsigned int biCompression;
        unsigned int biSizeImage;
        int  biXPelsPerMeter;
        int  biYPelsPerMeter;
        unsigned int biClrUsed;
        unsigned int biClrImportant;
    } BITMAPINFOHEADER;

    typedef struct {
        BITMAPINFOHEADER bmiHeader;
        unsigned int     bmiColors[1];
    } BITMAPINFO;

    int GetDIBits(void *hdc, void *hbm, unsigned int start, unsigned int lines,
                  void *lpvBits, BITMAPINFO *lpbmi, unsigned int usage);

    // GDI+ 初始化结构与函数
    typedef struct {
        uint32_t GdiplusVersion;
        void    *DebugEventCallback;
        int      SuppressBackgroundThread;
        int      SuppressExternalCodecs;
    } GdiplusStartupInput;

    int  GdiplusStartup(uintptr_t *token, const GdiplusStartupInput *input, void *output);
    void GdiplusShutdown(uintptr_t token);
    int  GdipCreateBitmapFromFile(const wchar_t *filename, void **bitmap);
    int  GdipCreateHBITMAPFromBitmap(void *bitmap, void **hbmReturn, uint32_t background);
    int  GdipDisposeImage(void *image);
    int  GdipGetImageWidth(void *image, unsigned int *width);
    int  GdipGetImageHeight(void *image, unsigned int *height);
]]

local kernel32 = safe_load("kernel32")
local user32   = safe_load("user32")
local gdi32    = safe_load("gdi32")
local gdiplus  = safe_load("gdiplus")

if not (kernel32 and user32 and gdi32 and gdiplus) then return end

-- ==========================================
-- GDI+ 模块级单例初始化
-- ==========================================
local gdip_token = ffi.new("uintptr_t[1]")
local gdip_input = ffi.new("GdiplusStartupInput")
gdip_input.GdiplusVersion = 1
gdip_input.SuppressBackgroundThread = 0
gdip_input.SuppressExternalCodecs   = 0

local gdip_init_ok = (gdiplus.GdiplusStartup(gdip_token, gdip_input, nil) == 0)
if not gdip_init_ok then
    msg.error("autocopyshot: GDI+ 初始化失败，脚本退出")
    return
end

-- 脚本卸载时关闭 GDI+
mp.register_event("shutdown", function()
    gdiplus.GdiplusShutdown(gdip_token[0])
end)

-- ==========================================
-- 配置项
-- ==========================================
local opts = {
    -- 临时截图格式（GDI+ 仅支持 png / jpg / jpeg，不支持 webp）
    temp_format           = "jpg",
    temp_png_compression  = 7,
    temp_png_filter       = 5,
    temp_jpg_quality      = 95,
    temp_webp_quality     = 95,   -- 仅在回退时保留，实际不生效
    temp_webp_compression = 4,

    -- OSD 设置
    osd_duration           = 0.8,
    osd_message_success    = "✅ 截图已保存并复制到剪贴板",
    osd_message_fail       = "❌ 截图已保存但复制失败",
    osd_message_subtitles  = "同源尺寸-有字幕",
    osd_message_video      = "同源尺寸-无字幕",
    osd_message_window     = "实际尺寸-有字幕",

    -- 其他设置
    window_screenshot_delay_offset = 0.03,
}

options.read_options(opts, 'autocopyshot')

-- WEBP 格式检测与回退（GDI+ 原生不支持 WEBP）
if opts.temp_format == "webp" then
    msg.warn("autocopyshot: GDI+ 不支持 WEBP 格式，temp_format 已自动回退为 jpg")
    opts.temp_format = "jpg"
end

-- 临时截图文件路径：加入 PID 防止多实例冲突
local pid       = mp.get_property("pid") or "0"
local temp_dir  = os.getenv('TEMP') or os.getenv('TMP') or "C:\\Temp"
local temp_file = temp_dir .. "\\mpv-screenshot-" .. pid .. "-temp." .. opts.temp_format

-- ==========================================
-- 辅助：UTF-8 转 UTF-16
-- ==========================================
local MAX_WCHAR = 32767

local function utf8_to_wide(str)
    if not str or str == "" then return nil end
    local len = kernel32.MultiByteToWideChar(65001, 0, str, -1, nil, 0)
    if len <= 0 or len > MAX_WCHAR then
        msg.error("autocopyshot: 路径编码转换失败或路径过长（len=" .. tostring(len) .. "）")
        return nil
    end
    local buf = ffi.new("wchar_t[?]", len)
    kernel32.MultiByteToWideChar(65001, 0, str, -1, buf, len)
    return buf
end

-- ==========================================
-- 临时截图选项管理（封装为 with 风格，确保 restore 必然执行）
-- ==========================================
local function with_temp_options(callback)
    -- 备份当前设置
    local backup = {
        format           = mp.get_property("screenshot-format"),
        png_compression  = mp.get_property("screenshot-png-compression"),
        png_filter       = mp.get_property("screenshot-png-filter"),
        jpeg_quality     = mp.get_property("screenshot-jpeg-quality"),
        webp_quality     = mp.get_property("screenshot-webp-quality"),
        webp_compression = mp.get_property("screenshot-webp-compression"),
    }

    -- 设置临时截图选项
    mp.set_property("screenshot-format", opts.temp_format)
    if opts.temp_format == "png" then
        mp.set_property("screenshot-png-compression", tostring(opts.temp_png_compression))
        mp.set_property("screenshot-png-filter",      tostring(opts.temp_png_filter))
    elseif opts.temp_format == "jpg" or opts.temp_format == "jpeg" then
        mp.set_property("screenshot-jpeg-quality", tostring(opts.temp_jpg_quality))
    end

    -- 执行回调，无论成功与否都恢复
    local ok, err = pcall(callback)

    -- 恢复原始设置
    if backup.format           then mp.set_property("screenshot-format",           backup.format)           end
    if backup.png_compression  then mp.set_property("screenshot-png-compression",  backup.png_compression)  end
    if backup.png_filter       then mp.set_property("screenshot-png-filter",       backup.png_filter)       end
    if backup.jpeg_quality     then mp.set_property("screenshot-jpeg-quality",     backup.jpeg_quality)     end
    if backup.webp_quality     then mp.set_property("screenshot-webp-quality",     backup.webp_quality)     end
    if backup.webp_compression then mp.set_property("screenshot-webp-compression", backup.webp_compression) end

    if not ok then
        msg.error("autocopyshot: with_temp_options 回调异常：" .. tostring(err))
    end
end

-- ==========================================
-- 核心复制函数（原生 Win32 FFI，使用 CF_DIB 格式）
-- ==========================================
--
-- 为什么用 CF_DIB 而不是 CF_BITMAP：
--   CF_BITMAP 是设备相关位图（DDB），现代应用（浏览器、微信、QQ、Discord 等）
--   只读取 CF_DIB（设备无关位图）或 CF_DIBV5，SetClipboardData(CF_BITMAP) 虽然
--   返回成功，但粘贴时目标应用找不到它能识别的格式，表现为粘贴无效。
--
-- CF_DIB 写入步骤：
--   GDI+ 读取图片 → 转 HBITMAP → GetDIBits 读出原始像素 →
--   GlobalAlloc 分配 BITMAPINFOHEADER+像素数据的连续内存块 → SetClipboardData(CF_DIB)

local CF_DIB    = 8   -- 设备无关位图，现代应用通用格式
local GMEM_MOVEABLE = 0x0002

local function copy_to_clipboard(file_path)
    if not file_path or file_path == "" then
        msg.warn("autocopyshot: 截图路径为空")
        return false
    end

    local win_path = file_path:gsub("/", "\\")
    local w_path   = utf8_to_wide(win_path)
    if not w_path then return false end

    local success = false
    local bitmap  = ffi.new("void*[1]")
    local hbitmap = ffi.new("void*[1]")

    -- 1. GDI+ 从文件读取位图
    if gdiplus.GdipCreateBitmapFromFile(w_path, bitmap) ~= 0 then
        msg.error("autocopyshot: GdipCreateBitmapFromFile 失败：" .. win_path)
        return false
    end

    -- 2. 获取图像尺寸（用于计算像素缓冲区大小）
    local w_out = ffi.new("unsigned int[1]")
    local h_out = ffi.new("unsigned int[1]")
    gdiplus.GdipGetImageWidth(bitmap[0], w_out)
    gdiplus.GdipGetImageHeight(bitmap[0], h_out)
    local img_w = tonumber(w_out[0])
    local img_h = tonumber(h_out[0])

    -- 3. GDI+ 位图 → HBITMAP（白色背景合成，0x00FFFFFF = ARGB 不透明白色）
    --    注意：GdipCreateHBITMAPFromBitmap 的背景色是 ARGB 格式，
    --    0x00FFFFFF 表示 alpha=0（完全不透明）、RGB=白色，这是正确的白底参数
    if gdiplus.GdipCreateHBITMAPFromBitmap(bitmap[0], hbitmap, 0x00FFFFFF) ~= 0 then
        msg.error("autocopyshot: GdipCreateHBITMAPFromBitmap 失败")
        gdiplus.GdipDisposeImage(bitmap[0])
        return false
    end

    -- 4. 用 GetDIBits 从 HBITMAP 中提取原始像素数据（24-bit BGR，行对齐到 4 字节）
    local hdc = user32.GetDC(nil)

    local bmi = ffi.new("BITMAPINFO")
    bmi.bmiHeader.biSize        = ffi.sizeof("BITMAPINFOHEADER")
    bmi.bmiHeader.biWidth       = img_w
    bmi.bmiHeader.biHeight      = img_h   -- 正值 = 自下而上（标准 DIB 方向）
    bmi.bmiHeader.biPlanes      = 1
    bmi.bmiHeader.biBitCount    = 24      -- 24-bit RGB，无 alpha，兼容性最好
    bmi.bmiHeader.biCompression = 0       -- BI_RGB，无压缩

    -- 每行字节数须对齐到 4 字节边界
    local row_stride  = math.floor((img_w * 3 + 3) / 4) * 4
    local pixel_bytes = row_stride * img_h

    local pixel_buf = ffi.new("uint8_t[?]", pixel_bytes)
    local scan_lines = gdi32.GetDIBits(hdc, hbitmap[0], 0, img_h, pixel_buf, bmi, 0)
    user32.ReleaseDC(nil, hdc)

    -- HBITMAP 此后不再需要，无论后续是否成功都立即释放
    gdi32.DeleteObject(hbitmap[0])

    if scan_lines == 0 then
        msg.error("autocopyshot: GetDIBits 失败（返回 0 扫描线）")
        gdiplus.GdipDisposeImage(bitmap[0])
        return false
    end

    -- 5. 构造 CF_DIB 数据块：BITMAPINFOHEADER 紧跟像素数据，放入全局堆
    local header_size = ffi.sizeof("BITMAPINFOHEADER")
    local total_size  = header_size + pixel_bytes

    local hmem = kernel32.GlobalAlloc(GMEM_MOVEABLE, total_size)
    if hmem == nil then
        msg.error("autocopyshot: GlobalAlloc 失败")
        gdiplus.GdipDisposeImage(bitmap[0])
        return false
    end

    local ptr = kernel32.GlobalLock(hmem)
    if ptr ~= nil then
        -- 写入头部
        ffi.copy(ptr, bmi.bmiHeader, header_size)
        -- 写入像素数据（紧跟头部之后）
        ffi.copy(ffi.cast("uint8_t*", ptr) + header_size, pixel_buf, pixel_bytes)
        kernel32.GlobalUnlock(hmem)

        -- 6. 写入剪贴板
        if user32.OpenClipboard(nil) ~= 0 then
            user32.EmptyClipboard()
            if user32.SetClipboardData(CF_DIB, hmem) ~= nil then
                -- 成功：系统接管 hmem 所有权，禁止再调用 GlobalFree
                success = true
            else
                msg.error("autocopyshot: SetClipboardData(CF_DIB) 失败，释放内存")
                kernel32.GlobalFree(hmem)
            end
            user32.CloseClipboard()
        else
            msg.error("autocopyshot: OpenClipboard 失败，剪贴板可能被其他进程占用")
            kernel32.GlobalFree(hmem)
        end
    else
        msg.error("autocopyshot: GlobalLock 失败")
        kernel32.GlobalFree(hmem)
    end

    -- 7. 释放 GDI+ 位图对象
    gdiplus.GdipDisposeImage(bitmap[0])

    -- 8. OSD 反馈
    if success then
        msg.info("autocopyshot: 截图已通过 FFI（CF_DIB）复制到剪贴板")
        mp.osd_message(opts.osd_message_success, opts.osd_duration)
    else
        mp.osd_message(opts.osd_message_fail, opts.osd_duration * 1.5)
    end

    return success
end

-- ==========================================
-- 截图并复制的核心流程
-- ==========================================
local function screenshot_and_copy(screenshot_flag, osd_type_message)
    -- 显示截图类型提示（窗口截图需要等 OSD 消失）
    if osd_type_message then
        mp.osd_message(osd_type_message, opts.osd_duration)
    end

    local delay = (screenshot_flag == "window")
        and (opts.osd_duration + opts.window_screenshot_delay_offset)
        or 0

    mp.add_timeout(delay, function()
        -- 路线1：使用用户配置格式保存截图到截图目录
        local ok1, err1 = pcall(mp.command_native, {
            name  = "screenshot",
            flags = screenshot_flag,
        })
        if not ok1 then
            msg.warn("autocopyshot: 路线1（保存截图）失败：" .. tostring(err1))
        end

        -- 路线2：截图到临时文件，然后复制到剪贴板
        -- screenshot-to-file 是同步命令，完成即代表文件已写入，无需额外延迟
        with_temp_options(function()
            mp.commandv('screenshot-to-file', temp_file, screenshot_flag)
        end)

        copy_to_clipboard(temp_file)
    end)
end

-- ==========================================
-- 注册脚本消息接口
-- ==========================================
mp.register_script_message("screenshot-subtitles-copy", function()
    screenshot_and_copy("subtitles", opts.osd_message_subtitles)
end)

mp.register_script_message("screenshot-video-copy", function()
    screenshot_and_copy("video", opts.osd_message_video)
end)

mp.register_script_message("screenshot-window-copy", function()
    screenshot_and_copy("window", opts.osd_message_window)
end)
