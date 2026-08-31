local mp      = require "mp"
local options = require "mp.options"

-- === 配置区域 ===
local opts = {
    -- 布局与开关
    position = "top-right",      
    enabled_by_default = true,   
    
    -- === 自动居中设置 ===
    auto_center = true,
    center_correction = 1.0,

    -- === 描边 (Outline) 全局粗细 ===
    -- 建议 1.5 到 3.0，0 为无描边
    border_size = 2.0,
    
    -- 字体设置
    font_face_num = "JetBrainsMono NF", 
    font_face_text = "", 

    -- === 第一行：当前系统时间 ===
    size_current  = 35,          
    color_current = "FFFFFF", 
    -- 【新增】独立描边颜色 (默认为黑色 000000)
    border_color_current = "000000",
    icon_current  = " ",       
    
    -- === 第二行左侧：还需时长 ===
    size_left     = 35,          
    color_left    = "EEEEEE",
    border_color_left = "000000",    
    icon_left     = "󱫟 ",       
    text_left     = "还需",      
    
    -- === 第二行右侧：预计结束时间 ===
    size_end      = 35,          
    color_end     = "DDDDDD",    
    border_color_end = "000000",
    icon_end      = " ",       
    text_end      = "预计结束",   

    -- === 第二行装饰符号 ===
    wrapper_open  = "[ ",    
    wrapper_close = " ]",    
    separator     = " - ",   

    alpha = "00",                
    time_format = "%H:%M:%S",
}
options.read_options(opts, "clock")

local clock_overlay = mp.create_osd_overlay('ass-events')
local overlay_visible = opts.enabled_by_default
local update_timer = nil
local last_ass_data = nil -- 缓存上次 data，内容未变化时跳过无意义的重绘

-- 辅助：生成 ASS 样式标签
local function style(text, font, size, color, b_color, bold)
    local s = ""
    if font and font ~= "" then s = s .. "\\fn" .. font end
    if size then s = s .. "\\fs" .. size end
    if color then s = s .. "\\1c&H" .. color .. "&" end
    if bold then s = s .. "\\b" .. bold end
    
    -- 注入描边设置
    if opts.border_size > 0 and b_color then
        s = s .. "\\bord" .. opts.border_size .. "\\3c&H" .. b_color .. "&"
    end
    
    return "{" .. s .. "}" .. text .. "{\\r}" 
end

local function format_seconds_hms(sec)
    sec = math.max(0, math.floor(sec or 0))
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s)
    else return string.format("%02d:%02d", m, s) end
end

local function get_alignment_tag(align)
    local map = {
        topright=9, topcenter=8, topleft=7,
        centerright=6, centercenter=5, centerleft=4,
        bottomright=3, bottomcenter=2, bottomleft=1
    }
    local key = tostring(align):lower():gsub("[%s%-_]", "")
    return "\\an" .. (map[key] or 9)
end

local function get_clock_content()
    local now_unix = os.time()
    
    -- === 1. 构建第一行 (传入 border_color_current) ===
    local raw_line1 = opts.icon_current .. os.date(opts.time_format)
    local ass_line1 = style(raw_line1, opts.font_face_num, opts.size_current, opts.color_current, opts.border_color_current, 1)

    -- === 2. 构建第二行 ===
    local part_left_raw = ""
    local part_left_ass = ""
    local duration = mp.get_property_number("duration")
    local pos = mp.get_property_number("time-pos")
    local speed = mp.get_property_number("speed") or 1
    
    if duration and pos and duration > pos then
        if speed <= 0 then speed = 1 end
        local rem_str = format_seconds_hms((duration - pos) / speed)
        part_left_raw = opts.icon_left .. opts.text_left .. " " .. rem_str
        -- 传入 border_color_left
        part_left_ass = style(opts.icon_left, opts.font_face_num, opts.size_left, opts.color_left, opts.border_color_left) ..
                        style(opts.text_left .. " ", opts.font_face_text, opts.size_left, opts.color_left, opts.border_color_left) ..
                        style(rem_str, opts.font_face_num, opts.size_left, opts.color_left, opts.border_color_left)
    end

    local part_end_raw = ""
    local part_end_ass = ""
    local rem = mp.get_property_native("playtime-remaining") 
    if rem and rem > 0 then
        local dt = os.date("*t", now_unix)
        dt.sec = math.floor(dt.sec + rem) -- 亚秒截断：os.time 以整数收字段
        local end_time = os.date(opts.time_format, os.time(dt))
        part_end_raw = opts.icon_end .. opts.text_end .. " " .. end_time
        -- 传入 border_color_end
        part_end_ass = style(opts.icon_end, opts.font_face_num, opts.size_end, opts.color_end, opts.border_color_end) ..
                       style(opts.text_end .. " ", opts.font_face_text, opts.size_end, opts.color_end, opts.border_color_end) ..
                       style(end_time, opts.font_face_num, opts.size_end, opts.color_end, opts.border_color_end)
    end

    local raw_line2 = ""
    local ass_line2 = ""
    
    -- 装饰符 (括号、横杠) 默认跟随 border_color_end，保持一致性
    local s_open = style(opts.wrapper_open, opts.font_face_num, opts.size_end, opts.color_end, opts.border_color_end)
    local s_close = style(opts.wrapper_close, opts.font_face_num, opts.size_end, opts.color_end, opts.border_color_end)
    local s_sep = style(opts.separator, opts.font_face_num, opts.size_end, opts.color_end, opts.border_color_end)

    if part_left_raw ~= "" and part_end_raw ~= "" then
        raw_line2 = opts.wrapper_open .. part_left_raw .. opts.separator .. part_end_raw .. opts.wrapper_close
        ass_line2 = s_open .. part_left_ass .. s_sep .. part_end_ass .. s_close
    elseif part_left_raw ~= "" then
        raw_line2 = opts.wrapper_open .. part_left_raw .. opts.wrapper_close
        ass_line2 = s_open .. part_left_ass .. s_close
    elseif part_end_raw ~= "" then
        raw_line2 = opts.wrapper_open .. part_end_raw .. opts.wrapper_close
        ass_line2 = s_open .. part_end_ass .. s_close
    end

    -- === 3. 计算居中填充 ===
    -- 填充方向由对齐锚点决定：右对齐时行尾垫可见文字被向左推；左对齐时须垫在行首；
    -- 居中对齐下两行本就同锚居中，不垫。
    if opts.auto_center and raw_line2 ~= "" then
        local len1 = string.len(raw_line1) 
        local len2 = string.len(raw_line2)
        if len2 > len1 then
            local diff = len2 - len1
            local pad_count = math.floor((diff / 2) * opts.center_correction)
            if pad_count > 0 then
                local pad = string.rep("\\h", pad_count)
                local pos_key = tostring(opts.position):lower():gsub("[%s%-_]", "")
                if pos_key:find("left") then
                    ass_line1 = pad .. ass_line1
                elseif pos_key:find("right") then
                    ass_line1 = ass_line1 .. pad
                end
            end
        end
    end

    if ass_line2 ~= "" then
        return ass_line1 .. "\\N" .. ass_line2
    else
        return ass_line1
    end
end

local function update_clock(force)
    if not overlay_visible then return end
    local align_tag = get_alignment_tag(opts.position)
    local alpha_tag = "\\alpha&H" .. opts.alpha .. "&"
    local ass_data = "{" .. align_tag .. alpha_tag .. "}" .. get_clock_content()
    -- 时钟内容粒度 1 秒，0.5s 周期下约半数 tick 内容相同：未变化时跳过重绘
    if force or ass_data ~= last_ass_data then
        clock_overlay.data = ass_data
        clock_overlay:update()
        last_ass_data = ass_data
    end
end

local function activate_timer()
    if not overlay_visible then return end
    if update_timer == nil then
        update_timer = mp.add_periodic_timer(0.5, update_clock)
    else
        update_timer:resume()
    end
end

local function deactivate_timer()
    if update_timer then
        update_timer:kill()
        update_timer = nil
    end
end

mp.register_script_message("toggle", function()
    if overlay_visible then
        deactivate_timer()
        clock_overlay:remove()
        overlay_visible = false
    else
        overlay_visible = true
        update_clock(true) -- 强制重绘：remove() 后 overlay 需 update() 才会重新上屏
        activate_timer()
    end
end)

-- 监听关键属性变化，以便在倍速、跳转、加载新文件时及时刷新显示
-- 监听播放速度变化，确保剩余时长实时更新
mp.observe_property("speed", "number", function() if overlay_visible then update_clock() end end)
-- 监听 time-pos 以便在用户 seek 时刷新（但不要频繁触发昂贵操作，这个是很轻量的 update）
-- mp.observe_property("time-pos", "number", function() if overlay_visible then update_clock() end end)
-- 监听 duration，文件切换时刷新
mp.observe_property("duration", "number", function() if overlay_visible then update_clock() end end)

if overlay_visible then
    update_clock()
    activate_timer()
end