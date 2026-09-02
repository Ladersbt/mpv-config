-- modules/playback.lua — 播放与播放列表管理

local msg = require 'mp.msg'
local options = require "modules.options"
local utils = require "modules.utils"
local sort_mod = require "modules.sort"
local subtitle_mod = require "modules.subtitle"

local M = {}

local state = nil

function M.init(s)
    state = s
end

function M.play_file(play_url)
    -- 注册 file-loaded 字幕挂载（幂等；放入口统一处理，播放路径分支不再重复）
    if not state.file_loaded_registered then
        mp.register_event("file-loaded", function()
            local path = mp.get_property("path") or ""
            if not path:find(options.domain, 1, true) then return end

            subtitle_mod.attach_subs_for(path)

            mp.add_timeout(0.3, function()
                local track_count = mp.get_property_number("track-list/count") or 0
                local best_sid = nil
                local best_priority = math.huge

                for i = 0, track_count - 1 do
                    local t_type = mp.get_property(string.format("track-list/%d/type", i))
                    if t_type == "sub" then
                        local selected = mp.get_property(string.format("track-list/%d/selected", i))
                        if selected == "yes" then best_sid = nil; break end
                        local lang  = mp.get_property(string.format("track-list/%d/lang", i)) or ""
                        local title = mp.get_property(string.format("track-list/%d/title", i)) or ""
                        local candidate = (lang .. " " .. title):lower()
                        for j, tag in ipairs(options.slang) do
                            if utils.slang_match(tag, candidate) and j < best_priority then
                                best_priority = j
                                best_sid = mp.get_property_number(string.format("track-list/%d/id", i))
                            end
                        end
                    end
                end

                if best_sid then
                    mp.set_property_number("sid", best_sid)
                    msg.info(string.format("内封字幕已选轨 sid=%d", best_sid))
                end
            end)
        end)
        state.file_loaded_registered = true
    end

    -- 在当前目录定位目标条目：单文件点击是显式意图，非视频文件也放行
    -- （video_only 只约束下方播放列表的构建范围，不拦单击）
    local target_item = nil
    for _, item in ipairs(state.cached_dir_items) do
        if not item.is_dir and item.play_url == play_url then
            target_item = item
            break
        end
    end
    if not target_item then
        mp.osd_message("⚠️ 目标文件不在当前目录", 2)
        return
    end

    local file_items = {}
    for _, item in ipairs(state.cached_dir_items) do
        if not item.is_dir and (not options.opts.video_only or item.is_video) then
            table.insert(file_items, item)
        end
    end

    if not state.sync_playlist_sort then
        table.sort(file_items, function(a, b) return utils.natural_compare(a.name, b.name) end)
    end

    -- 先把每个条目的显示名写入标题映射表（key 与播放列表中的 play_url 完全一致）：
    -- uosc 播放列表菜单读取该表直接显示文件名，而不是带凭据的完整链接。
    -- 先读回现有表再合并，避免清掉其他来源已写入的条目；即使未安装
    -- playlist_title_resolver.lua，该表依然会被 uosc 的 serializer 读取。
    local title_map = mp.get_property_native('user-data/playlist_title_resolver/titles') or {}
    for _, item in ipairs(file_items) do
        title_map[item.play_url] = item.name
    end
    title_map[play_url] = target_item.name
    mp.set_property_native('user-data/playlist_title_resolver/titles', title_map)

    -- 目标被 video_only 过滤出播放列表（如网盘改后缀的 zip/pdf 视频）：
    -- 单独播放，不建播放列表——否则下方 target_pos 匹配失败会错播排序第一的文件
    local target_in_list = false
    for _, item in ipairs(file_items) do
        if item.play_url == play_url then target_in_list = true; break end
    end
    if not target_in_list then
        mp.commandv("loadfile", play_url, "replace")
        mp.osd_message("🎬 播放：" .. target_item.name, 2)
        return
    end

    if #file_items == 0 then return end

    local target_pos = 0
    for i, item in ipairs(file_items) do
        if item.play_url == play_url then target_pos = i - 1; break end
    end

    -- 先加载目标文件（立即播放正确文件，无闪烁），再追加其余文件，最后用 playlist-move 修正位置
    local target_idx = target_pos + 1
    mp.commandv("loadfile", file_items[target_idx].play_url, "replace")
    for i = 1, #file_items do
        if i ~= target_idx then
            mp.commandv("loadfile", file_items[i].play_url, "append")
        end
    end
    if target_pos > 0 then
        -- 传 target_pos+1：playlist-move 的 index2 指向"目标条目"而非移动后下标，
        -- 当 index1(0) < index2 时移动后实际停在 index2-1（mpv 手册明确此 paradox）
        mp.commandv("playlist-move", 0, target_pos + 1)
    end

    local mode_hint = state.sync_playlist_sort
        and ("继承 WebDAV 目录排序: " .. options.sort_labels[sort_mod.get_sort_mode()]) or "名称 A→Z"
    local file_label = options.opts.video_only and "个视频" or "个文件"
    mp.osd_message("🎬 播放列表共 " .. #file_items .. " " .. file_label .. " [" .. mode_hint .. "]", 3)
end

return M