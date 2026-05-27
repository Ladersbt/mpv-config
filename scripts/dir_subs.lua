local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

-- ==================== 1. 配置定义 ====================
local o = {
    -- 完整保存路径 (支持 ~~/, ~/, 绝对路径)
    -- 用户可以在 script-opts/dir_subs.conf 中重写此项
    state_path = "~~/files/dir_subs.json",

    save_delay = 0.5, -- 防抖延迟（秒）
    debug = false,
}

options.read_options(o)

-- ==================== 2. 路径处理 ====================

local state_path_abs = mp.command_native({ "expand-path", o.state_path })

-- 确保父目录存在（仅在初始化阶段调用，shutdown 时不调用）
local function ensure_parent_dir_exists()
    local dir, _ = utils.split_path(state_path_abs)

    if not dir or dir == "." or dir == "" then return true end

    -- 去除末尾斜杠以确保 file_info 正常工作
    dir = dir:gsub("[\\/]$", "")

    local info = utils.file_info(dir)
    if not info then
        if o.debug then msg.info("父目录不存在，尝试创建: " .. dir) end

        local is_windows = package.config:sub(1, 1) == "\\"
        local args

        if is_windows then
            -- 修复：-Command 后必须是完整的一个命令字符串，不能拆开传参
            args = { 'powershell', '-NoProfile', '-Command', string.format('New-Item -ItemType Directory -Force -Path "%s"', dir) }
        else
            args = { 'mkdir', '-p', dir }
        end

        local res = mp.command_native({
            name = "subprocess",
            capture_stdout = true,
            playback_only = false,
            args = args
        })

        if res.status ~= 0 then
            msg.error("创建目录失败: " .. dir .. " | 错误: " .. (res.stderr or res.error or "unknown"))
            return false
        end
    elseif not info.is_dir then
        msg.error("路径冲突: " .. dir .. " 已存在但不是目录！")
        return false
    end
    return true
end

-- ==================== 3. 状态管理 ====================

local dir_state = {}
local save_timer = nil

-- 路径规范化（用于作为 Key 存入 JSON）
local function normalize_path(path)
    if not path then return nil end
    path = path:gsub("\\", "/")
    path = path:gsub("/$", "")
    return path
end

-- 计算表长度（用于 debug 日志）
local function table_length(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- 加载状态
local function load_state()
    local ok, err = pcall(function()
        local file = io.open(state_path_abs, "r")
        if not file then
            if o.debug then msg.info("未找到状态文件，将在首次保存时创建") end
            return
        end

        local content = file:read("*a")
        file:close()

        if not content or content == "" then return end

        local data, parse_err = utils.parse_json(content)
        if not data then
            msg.warn("JSON 解析失败，将重置状态: " .. tostring(parse_err))
        else
            dir_state = data
         -- if o.debug then msg.info("已加载 " .. table_length(dir_state) .. " 条记录") end
        end
    end)

    if not ok then
        msg.error("加载状态文件时发生异常: " .. tostring(err))
        dir_state = {}
    end
end

-- 轻量级目录存在性检查（不启动子进程，仅用 file_info 确认）
-- 应对目录在运行期间被外部意外删除的极端情况
local function check_parent_dir()
    local dir, _ = utils.split_path(state_path_abs)
    if not dir or dir == "." or dir == "" then return true end
    dir = dir:gsub("[\\/]$", "")
    local info = utils.file_info(dir)
    return info and info.is_dir
end

-- 保存状态（实际写入）——套 pcall 保护，shutdown 阶段也安全
local function save_state_now()
    local ok, err = pcall(function()
        
        if not check_parent_dir() then
            error("父目录不存在或已被删除: " .. state_path_abs)
        end
        
        local file = io.open(state_path_abs, "w")
        if not file then
            error("无法写入文件: " .. state_path_abs)
        end

        local json_str, format_err = utils.format_json(dir_state)
        if not json_str then
            file:close()
            error("JSON 格式化失败: " .. tostring(format_err))
        end

        file:write(json_str)
        file:close()
        if o.debug then msg.info("字幕状态已保存至: " .. state_path_abs) end
    end)

    if not ok then
        msg.error("保存字幕状态时发生异常: " .. tostring(err))
    end
end

-- 防抖保存
local function save_state()
    if save_timer then save_timer:kill() end
    save_timer = mp.add_timeout(o.save_delay, save_state_now)
end

-- ==================== 4. 业务逻辑 ====================

local function get_video_dir()
    local path = mp.get_property_native("path")
    -- 跳过网络流媒体
    if not path or path:match("^https?://") or path:match("^ytdl://") or path:match("^rtmp://") then
        return nil
    end
    path = path:gsub("^file://", "")
    local dir, _ = utils.split_path(path)
    return normalize_path(dir)
end

local function apply_state()
    local dir = get_video_dir()
    if not dir or not dir_state[dir] then return end

    local entry = dir_state[dir]
    if entry.sub_scale then
        mp.set_property_number("sub-scale", entry.sub_scale)
        if o.debug then msg.info("应用 sub-scale: " .. entry.sub_scale) end
    end
    if entry.sub_pos then
        mp.set_property_number("sub-pos", entry.sub_pos)
        if o.debug then msg.info("应用 sub-pos: " .. entry.sub_pos) end
    end
end

local function on_prop_change(name, value)
    if not value then return end

    local dir = get_video_dir()
    if not dir then return end

    dir_state[dir] = dir_state[dir] or {}

    -- 只有数值真正改变时才触发保存
    if dir_state[dir][name] ~= value then
        dir_state[dir][name] = value
        if o.debug then msg.info("记录变更 " .. name .. " -> " .. tostring(value)) end
        save_state()
    end
end

-- ==================== 5. 初始化 ====================

if ensure_parent_dir_exists() then
    load_state()

    mp.register_event("file-loaded", apply_state)

    mp.observe_property("sub-scale", "native", function(_, v) on_prop_change("sub_scale", v) end)
    mp.observe_property("sub-pos",   "native", function(_, v) on_prop_change("sub_pos",   v) end)

    mp.register_event("shutdown", function()
        -- 先取消还未触发的防抖 timer，再立即写入，确保退出前数据不丢失
        if save_timer then save_timer:kill() end
        save_state_now()
        if o.debug then msg.info("退出前已保存字幕状态") end
    end)

 -- if o.debug then msg.info("脚本初始化完成，存储位置: " .. state_path_abs) end
else
    msg.error("初始化失败：无法访问或创建存储目录")
end