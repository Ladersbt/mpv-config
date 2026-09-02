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
local mp_utils = require 'mp.utils'
local options = require "modules.options"
local utils = require "modules.utils"

-- ================= 版本 =================

VERSION = "2.0.0"
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
    menu_is_open          = false,
    loading               = nil,   -- 在途 PROPFIND：{ url = 目标 URL, gen = 代际, abort = 取消函数 }
    delete_job = {
        active  = false,
        total   = 0,
        done    = 0,
        success = 0,
        fail    = 0,
        queue   = nil,
        menu_dismissed = false,  -- 删除进行中用户 Esc 关闭进度菜单后置位：后续进度/结果不再强开菜单
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
-- browse 注入 UI 渲染回调表：正式列表 / spinner 占位 / 错误态三种渲染
browse_mod.init(state, {
    render         = function() menu_mod.render_menu() end,
    render_loading = function(url) menu_mod.render_loading_menu(url) end,
    render_error   = function(url, err) menu_mod.render_error_menu(url, err) end,
})
delete_mod.init(state,
    -- 删除后的目录刷新走静默模式：菜单已关不强开（数据后台更新），菜单开着原地换新列表
    function(url, force) browse_mod.open_webdav_url(url, force, true) end,
    function(done, total, name, ok, fail) menu_mod.render_delete_progress(done, total, name, ok, fail) end,
    function(ok, fail) menu_mod.render_delete_result(ok, fail) end)
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

mp.register_script_message("webdav-ask-delete", function()
    -- 两步确认第一步：删除模式的"确认删除"点击后先弹确认子菜单
    local sel_file_count, sel_dir_count = 0, 0
    for _ in pairs(state.selected_files) do sel_file_count = sel_file_count + 1 end
    for _ in pairs(state.selected_dirs)  do sel_dir_count  = sel_dir_count  + 1 end
    local count = sel_file_count + sel_dir_count
    if count == 0 then
        mp.osd_message("⚠️ 没有选中任何项目", 2)
        return
    end
    menu_mod.render_batch_delete_confirm(count)
end)

mp.register_script_message("webdav-execute-single-delete", function(url, is_dir, name)
    delete_mod.execute_single_delete(url, is_dir == "true", name or "")
end)

mp.register_script_message("webdav-cancel-delete", function()
    delete_mod.cancel_delete()
end)

mp.register_script_message("webdav-reopen", function()
    -- 确认菜单的"取消"：回到当前目录列表（确认菜单无 callback，点击后已自动关闭）
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
    local modes = {"time_asc", "time_desc", "name_desc", "name_asc", "size_desc", "size_asc"}
    local cur = sort_mod.get_sort_mode()
    for i, m in ipairs(modes) do
        if m == cur then
            sort_mod.set_sort_mode(modes[(i % #modes) + 1])
            break
        end
    end
    state.dir_cursor[state.current_loaded_url] = nil
    sort_mod.apply_sort()
    mp.osd_message("📶 排序: " .. (options.sort_labels[sort_mod.get_sort_mode()] or sort_mod.get_sort_mode()), 2)
    menu_mod.render_menu()
end)

mp.register_script_message("webdav-set-sort", function(mode)
    sort_mod.set_sort_mode(mode)
    state.dir_cursor[state.current_loaded_url] = nil
    sort_mod.apply_sort()
    state.menu_is_open = false
    menu_mod.render_menu()
end)

mp.register_script_message("webdav-play", function(play_url)
    playback_mod.play_file(play_url)
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

-- ================= uosc 菜单回调（callback 模式） =================
-- left/right 被 uosc 菜单 forced binding 拦截；设 callback 后未匹配的键以 key 事件转发到此，
-- 据此实现右键激活选中项（= enter）、左键/backspace 返回上一级。
-- 带修饰键的未匹配键（ctrl+right 等）也会被转发，需过滤以免误触发。
-- close 事件用于同步 menu_is_open：open-menu 替换旧菜单同样触发 close（uosc 无条件回调），
-- 需借 user-data/uosc/menu/type（uosc 打开时设置/关闭时清空）区分真关闭与替换。

--- 从条目主命令（value）中提取 URL，回当前目录列表按 URL 精确定位删除目标。
--- 不使用 event.index：uosc 搜索过滤后 items 被替换为过滤+重排的拷贝列表，
--- index 与全量列表错位会定位到错误条目（误删文件）；URL 是唯一键，不受过滤影响。
local function find_delete_target(v)
    if not v then return nil end
    local play_url = v:match('webdav%-play "(.-)"')
    if play_url then
        for _, item in ipairs(state.cached_dir_items) do
            if not item.is_dir and item.play_url == play_url then
                return { url = item.file_url, is_dir = false, name = item.name }
            end
        end
        return nil
    end
    local dir_url = v:match('webdav%-open "(.-)"')
    if dir_url then
        for _, item in ipairs(state.cached_dir_items) do
            if item.is_dir and item.url == dir_url then
                return { url = item.url, is_dir = true, name = item.name }
            end
        end
    end
    return nil
end

mp.register_script_message('menu-event', function(json)
    local event = mp_utils.parse_json(json)
    if not event then return end

    if event.type == 'activate' then
        -- item_actions 按钮触发：value 仍是条目主命令（播放/导航），不能执行；
        -- 必须先按 event.action 分流，否则点删除按钮会直接开始播放（F4 坑 1）
        if event.action == 'delete' then
            local target = find_delete_target(event.value)
            if target then
                menu_mod.render_single_delete_confirm(target)
            else
                mp.osd_message("⚠️ 无法定位删除目标，请刷新目录后重试", 2)
            end
            return
        elseif event.action then
            return  -- 未知 action：忽略，不执行条目主命令
        end

        local v = event.value
        if v and v ~= "" then
            mp.command(v)
            -- 仅播放文件需关菜单；目录导航/勾选等由 render_menu 的 update-menu 接管
            if v:find("webdav-play", 1, true) then
                mp.commandv("script-message-to", "uosc", "close-menu", "webdav_browser")
                state.menu_is_open = false
            end
        end
    elseif event.type == 'key' then
        if event.key == "right" and not event.modifiers and event.selected_item then
            local sel = event.selected_item
            -- 聚焦 action 按钮后按 right：只走 action 分流，一律不执行条目主命令。
            -- 注意 uosc 的 key 事件里 selected_item.action 是 action 对象 table
            -- （{name,icon,label}），不是文档所写的 name 字符串，须按类型判断
            if sel.action then
                if type(sel.action) == 'table' and sel.action.name == 'delete' then
                    local target = find_delete_target(sel.value)
                    if target then
                        menu_mod.render_single_delete_confirm(target)
                    else
                        mp.osd_message("⚠️ 无法定位删除目标，请刷新目录后重试", 2)
                    end
                end
                return
            end
            local v = sel.value
            if v and v ~= "" then
                mp.command(v)
                if v:find("webdav-play", 1, true) then
                    mp.commandv("script-message-to", "uosc", "close-menu", "webdav_browser")
                    state.menu_is_open = false
                end
            end
        elseif event.key == "left" and not event.modifiers then
            mp.commandv("script-message", "webdav-back")
        end
    elseif event.type == 'back' then
        mp.commandv("script-message", "webdav-back")
    elseif event.type == 'close' then
        -- 仅当真关闭（uosc 中已无本菜单实例）才复位并放弃在途加载；
        -- 替换场景下属性已是新菜单类型，复位会让下次 render 误走 open-menu 重开
        if mp.get_property_native('user-data/uosc/menu/type') ~= 'webdav_browser' then
            state.menu_is_open = false
            browse_mod.cancel_loading()
            -- 删除进行中用户关掉进度菜单 = 明确不想再被拉回：
            -- 置位后进度/结果菜单不再强开（终态仍有 OSD 汇报）
            if state.delete_job.active then
                state.delete_job.menu_dismissed = true
            end
        end
    end
end)

-- ================= 脚本就绪 =================

msg.debug("uosc_webdav v" .. VERSION .. " 已加载")