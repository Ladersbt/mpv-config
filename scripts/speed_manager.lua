local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require 'mp.options'

-- ==================== 脚本配置 ====================
local o = {
    save_path = "~~/files/speed_data.json",
    osd_duration = 2,
    save_on_change = false,
    save_delay = 0.5  -- 防抖延迟（秒），防止频繁写入
}
-- 对应配置名为 speed_manager.conf
options.read_options(o, "speed_manager")

-- ==================== 路径解析 ====================
local function resolve_path()
    local full_path = mp.command_native({"expand-path", o.save_path})
    local dir, _ = utils.split_path(full_path)
    return full_path, dir
end

local json_path, files_dir = resolve_path()

-- ==================== 核心状态 ====================
local state = {
    speed = 1.0,
    memory = nil
}
local initialized = false 
local save_timer = nil  -- 防抖计时器

-- ==================== 工具函数 ====================
local function ensure_dir_exists(dir_path)
    if not dir_path then return end
    local info = utils.file_info(dir_path)
    if info and info.is_dir then return true end
    
    local cmd = mp.get_property_native("platform") == "windows" 
        and string.format('mkdir "%s" 2>nul', dir_path)
        or string.format('mkdir -p "%s" 2>/dev/null', dir_path)
    os.execute(cmd)
end

-- 立即执行保存的内部函数
local function save_data_immediate()
    ensure_dir_exists(files_dir)
    local file = io.open(json_path, "w")
    if not file then 
        msg.error("无法写入文件: " .. json_path)
        return 
    end
    local content, err = utils.format_json(state)
    if content then file:write(content) end
    file:close()
end

-- 带防抖逻辑的保存函数
local function save_data()
    if save_timer then save_timer:kill() end
    save_timer = mp.add_timeout(o.save_delay, function()
        save_data_immediate()
        save_timer = nil
    end)
end

local function load_data()
    local file = io.open(json_path, "r")
    if not file then return end
    local content = file:read("*a")
    file:close()
    if not content or content == "" then return end
    local data = utils.parse_json(content)
    if not data then return end
    if type(data.speed) == "number" then state.speed = data.speed end
    if type(data.memory) == "number" then state.memory = data.memory end
end

-- ==================== 功能逻辑 ====================

-- 1. 启动初始化
load_data()

-- 2. 文件加载时应用速度
mp.register_event("file-loaded", function()
    if not initialized then
        if math.abs(state.speed - 1.0) > 0.001 then
            mp.set_property_number("speed", state.speed)
        end
        initialized = true
    end
end)

-- 3. 监听速度变化
mp.observe_property("speed", "number", function(_, current_speed)
    if not current_speed or not initialized then return end
    
    state.speed = current_speed
    if o.save_on_change then
        save_data() -- 使用防抖保存
    end
end)

-- 4. 退出时立即保存
mp.register_event("shutdown", function()
    if save_timer then save_timer:kill() end
    save_data_immediate()
end)

-- 5. 切换速度功能
mp.register_script_message('toggle_speed', function()
    local current = mp.get_property_number("speed")
    initialized = true 

    if math.abs(current - 1.0) > 0.001 then
        state.memory = current
        mp.set_property_number("speed", 1.0)
        mp.osd_message(string.format("速度重置\n已记录上次速度: %.1fx", current), o.osd_duration)
    else
        if state.memory and math.abs(state.memory - 1.0) > 0.001 then
            mp.set_property_number("speed", state.memory)
            mp.osd_message(string.format("速度: %.1fx", state.memory), o.osd_duration)
        else
            mp.osd_message("没有可恢复的速度记录", 1)
        end
    end
    save_data()
end)