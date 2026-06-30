--[[    uosc_webdav 群组脚本
参考和修改自 https://gist.github.com/HedioKojima/fdbfdd73570650b01c809afb5ae7829b 🙏🏻 

input.conf 写法示例:
#                script-message open-webdav                                                                             #menu: 导航 > WebDAV > 打开 WebDAV 目录
Q                script-message open-webdav-root                                                                        #menu: 导航 > WebDAV > 回到 WebDAV 根目录
q                script-message webdav-back                                                                             ## 返回上一级
c                script-message webdav-cycle-sort                                                                       #menu: 导航 > WebDAV > 切换 WebDAV 目录排序
#                script-message webdav-toggle-sync-sort                                                                 #menu: 导航 > WebDAV > 开/关 继承 WebDAV 目录排序
#                script-message webdav-toggle-video-only                                                                #menu: 导航 > WebDAV > 开/关 仅播放视频

推荐写入 uosc 控件 'command:cloud:script-message open-webdav?WebDAV' 于 uosc.conf

模块结构:
  main.lua        — 入口（初始化 + 消息处理器）
  modules/
    options.lua     配置与常量
    utils.lua       工具函数
    sort.lua        排序逻辑
    subtitle.lua    字幕匹配与自动挂载
    menu.lua        uosc 菜单渲染
    browse.lua      WebDAV 目录获取与解析
    delete.lua      文件/文件夹删除
    playback.lua    播放与播放列表管理
]]

local msg = require 'mp.msg'
local options = require "modules.options"
local utils = require "modules.utils"

-- ================= 版本 =================

VERSION = "1.1.0"
mp.commandv('script-message', 'uosc_webdav-version', VERSION)

-- ================= 加载模块 =================

-- 验证配置
if not options.protocol or not options.domain then
    msg.error("WebDAV 配置无效，脚本未加载")
    return
end

-- 全局状态（各模块通过 .init() 共享同一个 state 表）
local state = {
    last_visited_url      = options.opts.url,
    current_loaded_url    = "",
    cached_dir_items      = {},
    is_delete_mode        = false,
    selected_files        = {},
    selected_dirs         = {},
    sync_playlist_sort    = false,
    file_loaded_registered = false,
    active_playlist_obs_id = nil,
    menu_is_open          = false,
    delete_job = {
        active  = false,
        total   = 0,
        done    = 0,
        success = 0,
        fail    = 0,
        queue   = nil,
    },
    dir_cache  = {},
    dir_cursor = {},
    dir_sort   = {},
}

local sort_mod = require "modules.sort"
local subtitle_mod = require "modules.subtitle"
local menu_mod = require "modules.menu"
local browse_mod = require "modules.browse"
local delete_mod = require "modules.delete"
local playback_mod = require "modules.playback"

-- 注入 state + 回调
sort_mod.init(state)
subtitle_mod.init(state)
menu_mod.init(state)
browse_mod.init(state, function() menu_mod.render_menu() end)
delete_mod.init(state, function(url, force) browse_mod.open_webdav_url(url, force) end)
playback_mod.init(state)

-- ================= 消息处理器 =================

mp.register_script_message("webdav-toggle-mode", function()
    if state.current_loaded_url == "" then
        mp.osd_message("⚠️ 请先打开 WebDAV 目录", 2)
        return
    end
    state.is_delete_mode = not state.is_delete_mode
    state.selected_files = {}
    state.selected_dirs  = {}
    if not state.is_delete_mode then
        state.menu_is_open = false
    end
    menu_mod.render_menu()
end)

mp.register_script_message("webdav-toggle-file", function(file_url)
    if state.selected_files[file_url] then state.selected_files[file_url] = nil
    else state.selected_files[file_url] = true end
    menu_mod.render_menu()
end)

mp.register_script_message("webdav-toggle-dir", function(dir_url)
    if state.selected_dirs[dir_url] then state.selected_dirs[dir_url] = nil
    else state.selected_dirs[dir_url] = true end
    menu_mod.render_menu()
end)

mp.register_script_message("webdav-select-all", function(select_all_str)
    local select_all = (select_all_str == "true")
    state.selected_files = {}
    state.selected_dirs  = {}
    if select_all then
        for _, item in ipairs(state.cached_dir_items) do
            if item.is_dir then state.selected_dirs[item.url] = true
            else state.selected_files[item.file_url] = true end
        end
    end
    menu_mod.render_menu()
end)

mp.register_script_message("webdav-execute-delete", function()
    delete_mod.execute_delete()
end)

mp.register_script_message("webdav-open", function(url, force, child_url)
    if child_url and child_url ~= "" and state.current_loaded_url ~= "" then
        state.dir_cursor[state.current_loaded_url] = child_url
    end
    browse_mod.open_webdav_url(url, force == "true")
end)

mp.register_script_message("webdav-go-back", function(url)
    state.dir_cursor[state.current_loaded_url] = nil
    browse_mod.open_webdav_url(url, false)
end)

mp.register_script_message("webdav-cycle-sort", function()
    local modes = {"time_asc", "time_desc", "name_desc", "name_asc"}
    local cur = sort_mod.get_sort_mode()
    for i, m in ipairs(modes) do
        if m == cur then
            sort_mod.set_sort_mode(modes[(i % #modes) + 1])
            break
        end
    end
    state.dir_cursor[state.current_loaded_url] = nil
    sort_mod.apply_sort()
    menu_mod.render_menu()
end)

mp.register_script_message("webdav-set-sort", function(mode)
    sort_mod.set_sort_mode(mode)
    state.dir_cursor[state.current_loaded_url] = nil
    sort_mod.apply_sort()
    state.menu_is_open = false
    menu_mod.render_menu()
end)

mp.register_script_message("webdav-play", function(play_url, is_video)
    playback_mod.play_file(play_url, is_video)
end)

mp.register_script_message("webdav-toggle-sync-sort", function()
    state.sync_playlist_sort = not state.sync_playlist_sort
    local state_str = state.sync_playlist_sort
        and ("开 (继承 WebDAV 目录排序: " .. options.sort_labels[sort_mod.get_sort_mode()] .. ")") or "关 (名称 A→Z)"
    mp.osd_message("🎬 播放列表排序继承: " .. state_str, 2)
end)

mp.register_script_message("webdav-toggle-video-only", function()
    options.opts.video_only = not options.opts.video_only
    local state_str = options.opts.video_only and "开 (仅视频)" or "关 (全部文件)"
    mp.osd_message("🎬 仅播放视频: " .. state_str, 2)
end)

mp.register_script_message("open-webdav", function()
    browse_mod.open_webdav_url(state.last_visited_url, false)
end)

mp.register_script_message("open-webdav-root", function()
    if state.current_loaded_url == options.opts.url then
        mp.osd_message("📂 已在根目录", 1)
        return
    end
    state.dir_cursor = {}
    browse_mod.open_webdav_url(options.opts.url, false)
end)

mp.register_script_message("webdav-back", function()
    if state.current_loaded_url == "" or state.current_loaded_url == options.opts.url then return end
    local parent_path = state.current_loaded_url:match("^(.*)/[^/]+/?$")
    if parent_path then
        state.dir_cursor[state.current_loaded_url] = nil
        browse_mod.open_webdav_url(parent_path .. "/", false)
    end
end)

-- ================= 脚本就绪 =================

msg.debug("uosc_webdav v" .. VERSION .. " 已加载")