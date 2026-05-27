-- 与此程序 'https://github.com/Eatgrapes/WinIsland' 联动以在 mpv 播放音乐时实现类似手机音乐软件的灵动岛效果

local opt = require 'mp.options'

local opts = {
    enabled = false,
    winisland_path = "WinIsland.exe",
}

opt.read_options(opts, "winisland")

local is_running = false

-- 判断是否为纯音乐
local function is_audio_only()
    local track_list = mp.get_property_native("track-list", {})
    -- 兜底：如果轨道列表为空，说明没加载媒体，不视为音乐
    if not track_list or #track_list == 0 then return false end

    local has_audio = false
    
    for _, track in ipairs(track_list) do
        if track.type == "audio" then
            has_audio = true
        elseif track.type == "video" and not track.albumart then
            -- 只要有真正的视频轨，直接判定不是纯音乐
            return false
        end
    end
    
    -- 必须满足“没有视频轨”且“至少有一条音频轨”
    return has_audio
end

-- 异步启动 WinIsland
local function start_winisland()
    if not opts.enabled or is_running then return end

    is_running = true -- 乐观锁：立刻占坑

    mp.command_native_async({
        name = "subprocess",
        args = { opts.winisland_path },
        playback_only = false,  -- 确保不受播放状态限制
        detach = true,          -- 脱离 mpv 进程树独立运行
    }, function(success, _, err)
        if success then
            mp.msg.info("WinIsland: 启动请求已成功发出")
        else
            is_running = false  -- 状态回滚
            mp.msg.error("WinIsland: 启动失败 - " .. tostring(err))
        end
    end)
end

-- 异步关闭 WinIsland
local function stop_winisland()
    if not is_running then return end

    is_running = false 

    mp.command_native_async({
        name = "subprocess",
        args = { "taskkill", "/IM", "WinIsland.exe", "/F" },
        playback_only = false,  
        capture_stdout = true,  -- 拦截标准输出，阻止其污染 mpv 控制台
        capture_stderr = true,  -- 拦截错误输出
    }, function(success, _, err)
        if success then
            mp.msg.info("WinIsland: 关闭请求已成功发出")
        else
            mp.msg.warn("WinIsland: 关闭命令返回异常: " .. tostring(err))
        end
    end)
end

-- 文件加载时判断：音乐启动，视频关闭
local function on_file_loaded()
    if not opts.enabled then return end

    if is_audio_only() then
        start_winisland()
    else
        stop_winisland()
    end
end

-- 监听空闲状态：播放列表播完或手动停止时关闭
mp.observe_property("idle-active", "bool", function(_, idle)
    if idle then
        stop_winisland()
    end
end)

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("shutdown", stop_winisland)