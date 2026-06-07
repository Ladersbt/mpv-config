-- music-reset.lua
-- 检测到带封面的音频文件时，自动将进度重置到开头
-- 解决历史记录脚本对音乐文件恢复进度的问题

local function reset_if_albumart()
    local track_list = mp.get_property_native("track-list")
    if not track_list then return end

    for _, track in ipairs(track_list) do
        if track.type == "video" and track.albumart then
            -- 延迟执行，确保在历史记录脚本恢复进度之后生效
            mp.add_timeout(0.2, function()
                local pos = mp.get_property_number("time-pos", 0)
                if pos > 1 then
                    mp.set_property_number("time-pos", 0)
                 -- mp.osd_message("音乐文件，重置到开头", 1)
                end
            end)
            return
        end
    end
end

mp.register_event("file-loaded", reset_if_albumart)