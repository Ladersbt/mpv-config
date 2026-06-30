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

function M.play_file(play_url, is_video_str)
    if options.opts.video_only and is_video_str == "false" then
        mp.osd_message("⚠️ 此文件不是视频，无法播放", 2)
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

    if #file_items == 0 then return end

    local target_pos = 0
    for i, item in ipairs(file_items) do
        if item.play_url == play_url then target_pos = i - 1; break end
    end

    if state.active_playlist_obs_id then
        mp.unobserve_property(state.active_playlist_obs_id)
        state.active_playlist_obs_id = nil
    end

    mp.commandv("loadfile", file_items[1].play_url, "replace")
    for i = 2, #file_items do
        mp.commandv("loadfile", file_items[i].play_url, "append")
    end

    if target_pos > 0 then
        local expected = #file_items
        local obs_id
        local registered = false
        obs_id = mp.observe_property("playlist-count", "number", function(_, count)
            if not registered then return end
            if count and count >= expected then
                mp.unobserve_property(obs_id)
                state.active_playlist_obs_id = nil
                mp.commandv("playlist-play-index", target_pos)
            end
        end)
        registered = true
        state.active_playlist_obs_id = obs_id
    end

    local mode_hint = state.sync_playlist_sort
        and ("继承 WebDAV 目录排序: " .. options.sort_labels[sort_mod.get_sort_mode()]) or "名称 A→Z"
    local file_label = options.opts.video_only and "个视频" or "个文件"
    mp.osd_message("🎬 播放列表共 " .. #file_items .. " " .. file_label .. " [" .. mode_hint .. "]", 3)

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
end

return M