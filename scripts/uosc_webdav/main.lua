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
    browse.lua      WebDAV 目录获取与解析
    delete.lua      文件/文件夹删除
    menu.lua        uosc 菜单渲染
    options.lua     配置与常量
    playback.lua    播放与播放列表管理
    servers.lua     服务器列表管理
    sort.lua        排序逻辑
    subtitle.lua    字幕匹配与自动挂载
    utils.lua       工具函数
]]

-- 模块搜索路径：自家 modules 在前，再前置共享模块目录 script-modules（conf-persist）。
local mp = require 'mp'
local script_dir = mp.get_script_directory()
if script_dir then
    package.path = script_dir .. "/modules/?.lua;"
        .. mp.command_native({"expand-path", "~~/script-modules/?.lua;"}) .. package.path
end

local msg = require 'mp.msg'
local mp_utils = require 'mp.utils'
local options = require "modules.options"
local utils = require "modules.utils"
local servers_mod = require "modules.servers"
local conf_persist = require "conf-persist"

-- conf-persist 写盘器：persist_changes=yes 时把 default_server / video_only 等标量开关
-- 原位写回 script-opts/uosc_webdav.conf（键必须已在 options.opts 声明默认值）。
-- persist_changes 自身是菜单勾选项（webdav-toggle-persist）：它的状态切换**不受门控约束、
-- 始终写盘**（门控自身的净变化必须落盘）——否则切成 no 后想切回 yes 会被门控挡掉，
-- 永远勾不回来（门控自锁）。
local conf_writer = conf_persist.new({ script_name = "uosc_webdav", options = options.opts })

--- persist_changes 门控：yes 时把指定 conf 键写盘；失败只告警不回滚内存值
--- （内存值已是用户想要的，写盘失败是磁盘层问题，回滚会更困惑）。
local function persist_conf_keys(keys)
    if not options.opts.persist_changes then return end
    local ok, err = conf_writer:persist_keys(keys)
    if not ok then
        mp.osd_message("⚠️ 配置写盘失败（" .. tostring(err) .. "），重启后丢失", 4)
    end
end

-- ================= 版本 =================

VERSION = "3.0.0"
mp.commandv('script-message', 'uosc_webdav-version', VERSION)

-- ================= 加载模块 =================

-- 服务器列表归一化（JSON 缺失/损坏 → 回退 conf 单服务器，永远不返回 nil）。
-- 逐台预校验 url 派生量：全部非法说明配置无可救药，按原单服务器逻辑拒绝加载；
-- 部分非法则剔除并告警（坏条目不该拖死整份配置）。
local server_list = servers_mod.load(options.opts)
local valid_servers = {}
for _, srv in ipairs(server_list) do
    if options.server_ctx(srv) then
        table.insert(valid_servers, srv)
    else
        msg.error("服务器「" .. tostring(srv.name) .. "」URL 非法，已剔除：" .. tostring(srv.url))
    end
end
if #valid_servers == 0 then
    msg.error("WebDAV 配置无效（无可用服务器），脚本未加载")
    return
end

-- 全局状态（各模块通过 .init() 共享同一个 state 表）
local state = {
    servers               = valid_servers,
    -- 当前选中的服务器（服务器表引用）。nil = 尚未选择（多服务器且未配默认直入的初始态）
    current_server        = nil,
    last_visited_url      = nil,   -- 入口判定后才赋值为选中服务器的根 URL
    current_loaded_url    = "",
    cached_dir_items      = {},
    is_delete_mode        = false,
    selected_files        = {},
    selected_dirs         = {},
    sync_playlist_sort    = false,
    file_loaded_registered = false,
    -- 注意：这里**不再**有 menu_is_open。菜单是否开着一律实时读
    -- user-data/uosc/menu/type（uosc 在 Menu:init 写入、Menu:destroy 置 nil）。
    -- 脚本内缓存这个布尔副本没有必要（uosc 的 update-menu 本就只在同 type 时生效），
    -- 且在 close 回调里有竞态（uosc 先 destroy 置 nil，再异步投递 close 事件，
    -- 回调里读到的常是 nil），只会误导维护者。
    server_draft          = nil,   -- 录入草稿（menu.lua 读它显示「有未完成草稿」提示）
    pending_import        = nil,   -- 剪贴板导入待确认条目（含明文密码，生命周期见 set_pending_import）
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

--- 选中一台服务器：更新 current_server + 派生量缓存，重置浏览位置到其根目录。
--- dir_cache/dir_cursor/dir_sort 以完整 URL 为键，不同服务器天然隔离，无需清空。
--- 必须取消在途 PROPFIND：旧服务器的迟到响应会覆盖新会话状态，
--- 且后续操作会把新服务器凭据发往旧服务器主机（跨服务器凭据外泄）。
--- @param srv 服务器表（state.servers 中的引用）
local function select_server(srv)
    browse_mod.cancel_loading()
    state.current_server = srv
    state.current_loaded_url = ""
    state.cached_dir_items = {}
    state.is_delete_mode = false
    state.selected_files = {}
    state.selected_dirs = {}
    state.last_visited_url = srv.url
    -- 批量删除进行中切服务器：旧任务队列里的 URL 全属于旧服务器，
    -- 继续跑会拿新凭据删旧 URL，直接放弃剩余队列
    if state.delete_job.active then
        state.delete_job.active = false
        state.delete_job.queue = nil
        mp.osd_message("⏹️ 已切换服务器，进行中的批量删除已取消", 3)
    end
end

--- 按 name 精确匹配服务器（default_server 配置用 name 引用而非下标：
--- 下标在删除服务器后会整体移位，造成「删除 A 后默认变成 C」的静默错位）
local function find_server_by_name(name)
    for _, srv in ipairs(state.servers) do
        if srv.name == name then return srv end
    end
    return nil
end

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
    menu_mod.set_realign_next_render(true)  -- 排序切换 = 内容切换，光标回顶（列表头部是路径分隔行）
    menu_mod.render_menu()
end)

mp.register_script_message("webdav-set-sort", function(mode)
    sort_mod.set_sort_mode(mode)
    state.dir_cursor[state.current_loaded_url] = nil
    sort_mod.apply_sort()
    menu_mod.set_realign_next_render(true)  -- 排序切换 = 内容切换，光标回顶；重建吞掉排序子菜单停留（点完回根列表，预期取舍）
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
    persist_conf_keys({ "video_only" })
    local state_str = options.opts.video_only and "开 (仅视频)" or "关 (全部文件)"
    mp.osd_message("🎬 仅播放视频: " .. state_str, 2)
end)

mp.register_script_message("open-webdav", function()
    -- 入口判定：
    --   已选中过服务器（本次会话）→ 直接回 last_visited（会话内保持上下文）
    --   单服务器 → 直接进入（default_server 不干预）
    --   多服务器且 default_server 命中 → 直接进入该服务器
    --   多服务器且未命中/留空 → 显示服务器列表菜单
    if state.current_server then
        browse_mod.open_webdav_url(state.last_visited_url, false)
        return
    end
    if #state.servers == 1 then
        select_server(state.servers[1])
        browse_mod.open_webdav_url(state.current_server.url, false)
        return
    end
    local default_name = options.opts.default_server
    if default_name ~= "" then
        local srv = find_server_by_name(default_name)
        if srv then
            select_server(srv)
            browse_mod.open_webdav_url(srv.url, false)
            return
        end
        msg.warn("default_server「" .. default_name .. "」未匹配任何服务器，显示服务器列表")
    end
    menu_mod.render_servers_menu()
end)

mp.register_script_message("open-webdav-root", function()
    if not state.current_server then
        -- 未选服务器时直接引导到列表（而不是只弹一句提示让用户无处可去）。
        -- osd_message 是单槽覆盖，列表菜单的 render 不会再弹提示，所以文案
        -- 必须自带引导语义，也不能丢 ⚠️（用户是靠图标分辨严重性的）。
        mp.osd_message("⚠️ 请先选择服务器", 2)
        menu_mod.render_servers_menu()
        return
    end
    if state.current_loaded_url == state.current_server.url then
        mp.osd_message("📂 已在根目录", 1)
        return
    end
    state.dir_cursor = {}
    browse_mod.open_webdav_url(state.current_server.url, false)
end)

mp.register_script_message("webdav-back", function()
    if not state.current_server then return end
    if state.current_loaded_url == "" or state.current_loaded_url == state.current_server.url then return end
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
-- close 事件只做「真关闭」时的清理：open-menu 替换旧菜单同样会无条件触发 close，
-- 故须借 user-data/uosc/menu/type（uosc 的 Menu:init 写入、Menu:destroy 置 nil）区分。
-- 注意：菜单开闭状态**不再**在脚本里维护副本（原 menu_is_open 已移除，理由见
-- state 定义处注释），任何「菜单是否开着」的判断都实时读该属性。

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

--- action 分流（activate 与 key 两条路径共用）。
--- activate 事件的 action 是 name 字符串；key 事件的 selected_item.action 是 table。
--- 这里统一收 name 字符串 + value，返回 true 表示已消费（不再执行条目主命令）。
local function dispatch_menu_action(action_name, value)
    if action_name == 'delete' then
        -- 服务器列表菜单的删除按钮：value 是 webdav-select-server "name"
        local srv_name = value and value:match('webdav%-select%-server "(.-)"')
        if srv_name then
            menu_mod.render_server_delete_confirm(srv_name)
            return true
        end
        local target = find_delete_target(value)
        if target then
            menu_mod.render_single_delete_confirm(target)
        else
            mp.osd_message("⚠️ 无法定位删除目标，请刷新目录后重试", 2)
        end
        return true
    elseif action_name == 'edit' then
        local srv_name = value and value:match('webdav%-select%-server "(.-)"')
        if srv_name then
            mp.commandv("script-message", "webdav-server-edit", srv_name)
        end
        return true
    elseif action_name == 'test' then
        local srv_name = value and value:match('webdav%-select%-server "(.-)"')
        if srv_name then
            mp.commandv("script-message", "webdav-server-test", srv_name)
        end
        return true
    end
    return true  -- 未知 action 也返回 true（阻止执行条目主命令）；
                 -- 将来新增 action 需在此登记，漏登记的症状是「按了没反应」而非误执行
end

mp.register_script_message('menu-event', function(json)
    local event = mp_utils.parse_json(json)
    if not event then return end

    if event.type == 'activate' then
        -- item_actions 按钮触发：value 仍是条目主命令（播放/导航/选中），不能执行；
        -- 必须先按 event.action 分流，否则点删除按钮会直接开始播放
        if event.action then
            dispatch_menu_action(event.action, event.value)
            return
        end

        local v = event.value
        if v and v ~= "" then
            mp.command(v)
            -- 仅播放文件需关菜单；目录导航/勾选等由 render_menu 的 update-menu 接管
            if v:find("webdav-play", 1, true) then
                mp.commandv("script-message-to", "uosc", "close-menu", "webdav_browser")
            end
        end
    elseif event.type == 'key' then
        if event.key == "right" and not event.modifiers and event.selected_item then
            local sel = event.selected_item
            -- 聚焦 action 按钮后按 right：只走 action 分流，一律不执行条目主命令。
            if sel.action then
                -- uosc 的 key 事件里 selected_item.action 是 action 对象 table
                -- （{name,icon,label}），不是 activate 事件里的 name 字符串，须按类型取 name
                local action_name = type(sel.action) == 'table' and sel.action.name or nil
                if action_name then
                    dispatch_menu_action(action_name, sel.value)
                end
                return
            end
            local v = sel.value
            if v and v ~= "" then
                mp.command(v)
                if v:find("webdav-play", 1, true) then
                    mp.commandv("script-message-to", "uosc", "close-menu", "webdav_browser")
                end
            end
        elseif event.key == "left" and not event.modifiers then
            mp.commandv("script-message", "webdav-back")
        end
    elseif event.type == 'back' then
        mp.commandv("script-message", "webdav-back")
    elseif event.type == 'close' then
        -- 这条分支只负责「真关闭」时的清理（取消在途加载 / 抑制删除进度强开）。
        --
        -- 时序坑：uosc 替换菜单的顺序是
        --   旧菜单 destroy() 无条件把 user-data/uosc/menu/type 置 nil
        --   → 发 close 回调（script-message 异步投递到本脚本）
        --   → 新菜单 init 写入新 type
        -- 在 close 回调里立即读该属性，拿到的常是 destroy 留下的 nil；即使延后一个
        -- tick 也不可靠，所以「延迟 + 白名单」不能当作判据。
        -- 因此菜单开闭状态一律在正常渲染路径实时读属性（dispatch_menu / browse 都是
        -- 这样），这里只做尽力而为的清理。用 100ms 延迟是为了让新菜单的 type 落定，
        -- 但**本分支的正确性不依赖这个延迟**——误判的最坏后果是「该清没清」
        -- （残留一个 in-flight 加载 / 进度菜单），不会再出现「该显示却以为菜单已关」。
        mp.add_timeout(0.1, function()
            local utype = mp.get_property_native('user-data/uosc/menu/type')
            local ours = utype == 'webdav_browser' or utype == 'webdav_servers'
                or utype == 'webdav_test_result' or utype == 'webdav_import_confirm'
                or utype == 'webdav_delete_confirm'
            if ours then return end
            browse_mod.cancel_loading()
            -- 删除进行中用户关掉进度菜单 = 明确不想再被拉回：
            -- 置位后进度/结果菜单不再强开（终态仍有 OSD 汇报）
            if state.delete_job.active then
                state.delete_job.menu_dismissed = true
            end
        end)
    end
end)

-- ================= 服务器列表菜单消息 =================

mp.register_script_message("webdav-select-server", function(name)
    local srv = find_server_by_name(name)
    if not srv then
        mp.osd_message("⚠️ 服务器不存在：" .. tostring(name), 2)
        return
    end
    select_server(srv)
    browse_mod.open_webdav_url(srv.url, false)
end)

mp.register_script_message("webdav-back-to-browser", function()
    if not state.current_server then
        menu_mod.render_servers_menu()
        return
    end
    local target = state.last_visited_url or state.current_server.url
    browse_mod.open_webdav_url(target, false)
end)

mp.register_script_message("webdav-open-servers", function()
    menu_mod.render_servers_menu()
end)

-- ================= 服务器录入（mp.input 顺序问答） =================

-- uosc 菜单没有文本输入控件，多字段表单走 mp.input 顺序问答（mpv 0.41 内置 console 输入框）。
--   先 close-menu 再 input.get（两者同开会抢 forced 键位），提交后重开列表菜单。
-- draft 暂存中途已填字段：用户在第 N 步 Esc 放弃后重进，前面填的不丢。
local input_loaded, input = pcall(require, "mp.input")

-- 录入草稿：{ name=, url=, user=, pass=, edit_origin=nil|{name,url} }
-- edit_origin 非 nil 表示「编辑既有服务器」，用 name+url 做身份锚而**不是下标**：
-- 草稿会长期存活（Esc 保留、菜单顶部可见），期间用户完全可能删掉别的服务器，
-- 快照下标会错位到另一台（静默覆盖）或落进 ipairs 空洞（条目永不出现且不写盘）。
-- 挂在 state 上而不是文件局部：服务器列表菜单要读它显示「有未完成草稿」提示。
local server_draft = nil
local function set_draft(d)
    server_draft = d
    state.server_draft = d
end

-- 剪贴板导入的待确认条目（含明文密码）。唯一真源是 state.pending_import，
-- 不要再加文件局部副本——两处各读各的会漏清，密码就长驻内存了。
--
-- 清理时机：确认菜单的菜单级 on_close（见 webdav-server-import-clipboard）。
-- 不用 callback——uosc 的 open_command_menu 只有非 callback 分支才自动 menu:close()，
-- 一加 callback，本菜单的 keep_open=false 就全失效；on_close 走 Menu:close() 尾部，
-- 与 callback/keep_open 无关，Esc / 回车激活 / 被顶替三条关闭路径都会触发。
--
-- 代际编号（import_serial）是必需的：
-- uosc 顶替旧菜单时，旧菜单的 destroy 是同步的，但 on_close 经 mp.command 发
-- script-message 是**跨脚本异步投递**，投递时刻可能晚于「新一次导入」对
-- state.pending_import 的写入。没有代际判断，迟到的 on_close 就会把刚设置的新条目
-- 清成 nil（连续导入 A、B 时 B 直接丢失）。
--
-- 代际只在**新一次导入**时推进（即 entry 非 nil），清空（nil）不推进。
-- 这样「确认导入」路径清空 pending 后，稍后到达的该菜单 on_close 仍携带当前代际，
-- 会命中并再次清空 —— 幂等，无害；而被更新导入顶替过的旧菜单携带的是旧代际，必然不匹配。
local import_serial = 0
local function set_pending_import(entry)
    state.pending_import = entry
    if entry ~= nil then
        import_serial = import_serial + 1   -- 只有「新导入」才算新一代
    end
    return import_serial
end

--- 按身份锚在当前列表里定位服务器下标。
--- 先按 name+url 精确匹配（防「同名被改 URL」），再退到仅 name 匹配。
--- 返回 nil 表示原服务器已被删除或改名——调用方须明确告知用户，不得静默写错位置。
local function find_draft_target_index(origin)
    if type(origin) ~= "table" then return nil end
    for i, srv in ipairs(state.servers) do
        if srv.name == origin.name and srv.url == origin.url then return i end
    end
    -- 允许用户在别处只改了 URL 的情况：name 唯一即可定位
    for i, srv in ipairs(state.servers) do
        if srv.name == origin.name then return i end
    end
    return nil
end

--- 录入完成：校验 + 写入列表 + 按需落盘 + 重开服务器列表菜单
--- @param extra_note string|nil 调用方想附带告知用户的说明（如「已丢弃此前草稿」）。
---   必须经由这里的 note 一起 osd——mpv 的 osd_message 是单槽覆盖、不堆叠，
---   调用方自己再 osd 一条会被本函数末尾的成功提示吃掉。
local function commit_server_draft(extra_note)
    if not server_draft then return end
    local draft = server_draft
    set_draft(nil)

    local entry = {
        name = draft.name, url = draft.url,
        user = draft.user or "", pass = draft.pass or "",
    }

    -- 编辑模式下按身份锚重新定位目标；定位不到说明原服务器已消失，
    -- 此时不能拿旧下标硬写（会覆盖别台或写空洞），改为明确报错并降级成新增。
    local target_index = nil
    local origin_lost = false
    if draft.edit_origin then
        target_index = find_draft_target_index(draft.edit_origin)
        if not target_index then
            origin_lost = true
        end
    end

    local ok, err = servers_mod.validate(entry, state.servers, target_index)
    if not ok then
        mp.osd_message("❌ " .. err, 4)
        menu_mod.render_servers_menu()
        return
    end

    if target_index then
        -- 先记旧条目再覆盖——判「编辑的是不是当前服务器」用旧名/引用，
        -- 不能用新名（改名时新名 ≠ 当前名，current_server 会变幽灵指向被替换的旧表）
        local old_entry = state.servers[target_index]
        local old_name = old_entry and old_entry.name or nil
        local was_current = state.current_server ~= nil
            and (state.current_server == old_entry
                 or (old_name ~= nil and state.current_server.name == old_name))
        state.servers[target_index] = entry
        if was_current then
            select_server(entry)
        end
        -- 改名时迁移 default_server 引用（防悬空：重启后按旧名匹配不到）
        if old_name and old_name ~= entry.name and options.opts.default_server == old_name then
            options.opts.default_server = entry.name
            persist_conf_keys({ "default_server" })
        end
    else
        table.insert(state.servers, entry)
    end

    -- 结果提示：osd 单槽覆盖（见 extra_note 说明），所有分支结果合并成一条，
    -- 按优先级拼装：写盘失败 > 原服务器丢失（降级为新增）> 普通成功。
    local note
    local persist_failed_err = nil
    if options.opts.persist_changes then
        local saved, save_err = servers_mod.save(state.servers)
        if not saved then persist_failed_err = save_err end
    end

    if persist_failed_err then
        note = (target_index and "✅ 服务器已更新：" or "✅ 服务器已添加：") .. entry.name
            .. "（⚠️ 写盘失败 " .. tostring(persist_failed_err) .. "，重启后丢失）"
        -- 写盘失败与 origin_lost 可能同时发生，两者都要让用户知道
        if origin_lost then
            note = note .. "；原服务器已不存在，本次为新增"
        end
    elseif origin_lost then
        -- 原服务器在编辑期间被删除/改名：条目仍保存（用户填的内容不丢），
        -- 但必须明说它变成了新增，避免用户以为改的是原来那台。
        note = "ℹ️ 原服务器已不存在，已作为新增保存：" .. entry.name
    elseif target_index then
        note = "✅ 服务器已更新：" .. entry.name
    else
        note = "✅ 服务器已添加：" .. entry.name
    end
    if extra_note and extra_note ~= "" then
        note = note .. "；" .. extra_note
    end
    mp.osd_message(note, persist_failed_err and 5 or (origin_lost and 4 or 3))
    menu_mod.render_servers_menu()
end

--- 顺序问答：地址 → 名称 → 账号 → 密码。每步 submit 填下一字段；Esc（closed）放弃。
--- 地址优先：用户最清楚的是「要连哪个盘」，名称可默认取 host（回车即过），
--- 早期把名称放第一位会逼用户先想一个名字、再填真正重要的 URL。
--- mp.input 无密码掩码参数（密码会明文显示在 console），这是已知限制；
--- 不落屏的替代是「从剪贴板导入」（webdav-server-import-clipboard）。
local function ask_server_fields()
    if not input_loaded then
        mp.osd_message("❌ 本 mpv 版本无 mp.input 模块，无法录入", 4)
        return
    end
    -- 先关菜单再开输入框（两者同开抢 forced 键位）
    mp.commandv("script-message-to", "uosc", "close-menu")

    local step = 0

    -- 地址填完即时把名称预填成 host（用户直接回车即用默认名）
    -- 必须剥掉 userinfo —— 用户常把 http(s)://user:pass@host/path/ 整串粘进
    -- URL 步骤，若不剥，「名称」会变成含密码的串，进而进菜单 JSON / 列表 title /
    -- servers.json，违反「密码绝不进菜单 JSON」红线
    local function suggest_name_from_url(url)
        local without_scheme = url:gsub("^https?://", "")
        local without_userinfo = without_scheme:gsub("^[^@/]*@", "")
        local host = without_userinfo:match("^([^/]+)")
        return host or ""
    end

    local step_prompts = {
        { key = "url",  prompt = "WebDAV 地址（http(s)://…，以 / 结尾）:" },
        { key = "name", prompt = "服务器名称（列表显示名，留空则用地址主机名）:" },
        { key = "user", prompt = "账号（可留空）:" },
        { key = "pass", prompt = "密码（可留空，明文显示）:" },
    }

    local function ask_next()
        step = step + 1
        local s = step_prompts[step]
        if not s then
            -- 名称留空时兜底用 host（校验层要求 name 非空）
            if not server_draft.name or server_draft.name == "" then
                server_draft.name = suggest_name_from_url(server_draft.url or "")
            end
            commit_server_draft()
            return
        end
        -- 名称步骤的默认值是「地址里的 host」，回车即采用
        local default_text = server_draft[s.key] or ""
        if s.key == "name" and default_text == "" then
            default_text = suggest_name_from_url(server_draft.url or "")
        end
        -- closed 在每次 submit（内部 terminate）后也会触发，
        -- 用门闩区分「用户 Esc 放弃」和「本步已提交、正要进下一步」
        local submitted = false
        input.get({
            prompt = s.prompt,
            default_text = default_text,
            submit = function(text)
                submitted = true
                -- 录入路径劝阻 URL 内嵌凭据（校验层放行以兼容老配置）。
                -- 用户从别处复制来 http://user:pass@host/path/ 时，自动把凭据拆到
                -- 账号/密码字段并从 URL 里剥掉——避免 domain 里带凭据、auth_prefix
                -- 出现双份凭据，也避免密码随 URL 进菜单 hint / JSON 档。
                if s.key == "url" then
                    -- 拆分有副作用（写 user/pass），而下面的残余 @ 检查
                    -- 可能拒绝这次输入。必须先快照，拒绝时还原——否则脏凭据留在草稿里，
                    -- 用户重输正确地址后仍带着上次的凭据入库（比截断更隐蔽：地址对、账号错）。
                    -- 注意不能简单清空：续填草稿里可能本就有用户之前填好的合法凭据。
                    -- 维护提醒：本分支今后若新增任何写草稿的副作用，必须一并纳入这里的快照/还原。
                    local prev_user, prev_pass = server_draft.user, server_draft.pass
                    local scheme, userinfo, rest = text:match("^(https?://)([^@/]+)@(.+)$")
                    if scheme then
                        local u, p = userinfo:match("^([^:]*):?(.*)$")
                        if (not server_draft.user or server_draft.user == "") and u and u ~= "" then
                            server_draft.user = u
                        end
                        if (not server_draft.pass or server_draft.pass == "") and p and p ~= "" then
                            server_draft.pass = p
                        end
                        text = scheme .. rest
                    end
                    -- 密码里含未编码 @ 时（user:p@ss@host），上面那条模式
                    -- 只吃掉一段，剥完仍是 http://ss@host/ 这样的残余 @，会让 server_ctx
                    -- 算出带凭据的 domain、认证必失败。必须拦下让用户重输，不能静默入库
                    -- （剪贴板路径同款校验，两条路径行为必须一致）。
                    if text:match("^https?://[^/]*@") then
                        server_draft.user, server_draft.pass = prev_user, prev_pass  -- 回滚副作用
                        mp.osd_message("❌ 密码里的 @ 需要 URL 编码写成 %40，或先清除本步再分开填账号密码；请重新输入地址", 5)
                        -- 本步不接受这个值：重新问「地址」这一问（step 回退一格）。
                        -- 不要动 submitted——submit 后控制台会因 keep_open=false 自动关闭并
                        -- 触发旧输入框的 closed；保持 submitted=true 才能让那条 closed 认出
                        -- 「这是正常提交路径」而不误报「已取消」并重开菜单（否则会顶掉新输入框；
                        -- 置 false 会让 render_servers_menu 执行、菜单 forced
                        -- keybinding 抢走 Enter，新输入框直接失效）。
                        step = step - 1
                        ask_next()
                        return
                    end
                    if scheme then
                        mp.osd_message("ℹ️ 地址里的账号密码已自动拆到后续步骤", 3)
                    end
                end
                -- 名称留空（直接回车且默认值也为空）时仍走兜底
                server_draft[s.key] = text
                input.terminate()
                ask_next()
            end,
            closed = function()
                if submitted then return end  -- 本步正常提交，不是取消
                -- Esc 放弃：draft 保留（重进续填），菜单重开
                mp.osd_message("已取消录入（草稿保留，重新进入可续填）", 2)
                menu_mod.render_servers_menu()
            end,
        })
    end
    ask_next()
end

mp.register_script_message("webdav-server-new", function()
    set_pending_import(nil)   -- 开始新录入，丢弃上一次未确认的导入
    set_draft({ name = "", url = "", user = "", pass = "", edit_origin = nil })
    ask_server_fields()
end)

-- 续填未完成草稿（新增流程）
mp.register_script_message("webdav-server-new-resume", function()
    if not server_draft then
        set_draft({ name = "", url = "", user = "", pass = "", edit_origin = nil })
    end
    ask_server_fields()
end)

-- 续填未完成草稿（编辑流程，draft 里带着 edit_origin 身份锚）
mp.register_script_message("webdav-server-edit-resume", function()
    if not server_draft then
        mp.osd_message("⚠️ 没有可续填的草稿", 2)
        menu_mod.render_servers_menu()
        return
    end
    ask_server_fields()
end)

-- 丢弃草稿
mp.register_script_message("webdav-server-discard-draft", function()
    set_draft(nil)
    set_pending_import(nil)   -- 连同待导入条目一起清（明文密码不长驻）
    mp.osd_message("🗑️ 已丢弃草稿", 2)
    menu_mod.render_servers_menu()
end)

mp.register_script_message("webdav-server-edit", function(name)
    for _, srv in ipairs(state.servers) do
        if srv.name == name then
            -- 身份锚用 name+url，不用下标（草稿存活期间列表可能被删改）
            set_draft({ name = srv.name, url = srv.url, user = srv.user, pass = srv.pass,
                        edit_origin = { name = srv.name, url = srv.url } })
            ask_server_fields()
            return
        end
    end
    mp.osd_message("⚠️ 服务器不存在：" .. tostring(name), 2)
end)

--- 从剪贴板导入完整 URL（http://user:pass@host:port/path/）整串解析。
--- 密码全程不落屏（不经过 mp.input / 菜单 JSON），是密码录入的安全通道。
--- 解析完先弹确认菜单，不直接入库——粘错的 URL 不该无声进列表。
--- 确认菜单里也不回显密码，只显示 name/host/账号。
mp.register_script_message("webdav-server-import-clipboard", function()
    local clip = mp.get_property("clipboard/text")
    if not clip or clip == "" then
        mp.osd_message("⚠️ 剪贴板为空", 2)
        return
    end
    -- 容忍首尾空白（从浏览器地址栏复制常带换行）
    clip = clip:gsub("^%s+", ""):gsub("%s+$", "")
    -- 不能用单条 Lua 模式解析，`([^@/]*)@?` 会回溯——遇到无凭据 URL 时
    -- `[^@/]*` 先吞掉整段再回吐，host 被劈两半（http://192.168.1.50:5005/dav/
    -- 会被拆成 host=5 + user=192.168.1.50）。改为手工切分：先剥协议，
    -- 再只在「第一个 / 之前」找 @（userinfo 只可能出现在这个区间）。
    local protocol, rest = clip:match("^(https?://)(.*)$")
    if not protocol or rest == "" then
        mp.osd_message("❌ 剪贴板内容不是合法 URL（需要 http(s)://[user:pass@]host/path/ 形态）", 4)
        return
    end
    local authority, path = rest:match("^([^/?#]*)(.*)$")
    local user, pass = "", ""
    local hostport = authority
    local at = authority:find("@", 1, true)
    if at then
        local creds = authority:sub(1, at - 1)
        hostport = authority:sub(at + 1)
        -- 密码里可能含未编码的 @：以「第一个 : 之前」为用户名，其余整体当密码
        local u, p = creds:match("^([^:]*):(.*)$")
        if u then user, pass = u, p else user = creds end
    end
    if hostport == "" then
        mp.osd_message("❌ 剪贴板 URL 缺少主机名", 4)
        return
    end
    -- 密码里含未编码 @ 时（user:p@ss@host）拆完主机名仍残留 @，
    -- 这种 URL 会让 server_ctx 算出带凭据的 domain。宁可让用户重输也不要静默产坏条目。
    if hostport:find("@", 1, true) then
        mp.osd_message("❌ 密码里的 @ 需要按 URL 编码写成 %40，或改用「新增服务器」分开填", 5)
        return
    end
    local url = protocol .. hostport .. path
    if url:sub(-1) ~= "/" then url = url .. "/" end
    -- 名称默认取 host（剥掉端口更易读，但重名判断用完整 hostport 保证唯一）
    local host = hostport
    local name = host
    local n = 1
    while find_server_by_name(name) do
        n = n + 1
        name = host .. " (" .. n .. ")"
    end
    -- 先做一次校验，非法就当场报错（不进确认菜单）
    local entry = { name = name, url = url, user = user, pass = pass }
    local ok, err = servers_mod.validate(entry, state.servers, nil)
    if not ok then
        mp.osd_message("❌ " .. err, 4)
        return
    end
    -- 记下本次导入的代际编号：on_close 会把它带回来，过期菜单的回调据此忽略
    local my_serial = set_pending_import(entry)
    -- 确认菜单（密码不回显）
    local items = {
        { title = "名称", hint = name, selectable = false, value = "" },
        { title = "地址", hint = url, selectable = false, value = "" },
        { title = "账号", hint = user ~= "" and user or "（匿名）", selectable = false, value = "" },
        { title = "密码", hint = pass ~= "" and "••••••（已读取）" or "（未设置）", selectable = false, value = "" },
        { title = "服务器管理", selectable = false, muted = true, separator = true },
        {
            title = "✅ 确认导入",
            value = "script-message webdav-server-import-confirm",
            keep_open = false,
        },
        {
            title = "↩️ 取消",
            value = "script-message webdav-open-servers",
            keep_open = false,
        },
    }
    local menu = {
        type = "webdav_import_confirm",
        title = "从剪贴板导入服务器？",
        search_style = "disabled",
        items = items,
        -- 确认菜单一关闭就丢弃待导入条目（含明文密码），无论怎么关的。
        -- 用 uosc 的菜单级 on_close 而不是 callback：
        --   · callback 一旦设置，uosc 的 open_command_menu 就不再自动关闭菜单
        --     （lib/menus.lua 里只有非 callback 分支才 menu:close()），本菜单的
        --     keep_open=false 会全部失效，点了按钮菜单赖着不走；
        --   · on_close 走 Menu:close() 尾部（elements/Menu.lua），与 callback/keep_open
        --     完全无关，Esc / 回车激活 / 被另一个 open-menu 顶替**三种路径都会触发**。
        -- 注意值必须是命令（字符串或表），不能写 "callback"——那会去调不存在的
        -- self.callback，无 callback 的菜单会直接报错。
        -- 末尾附上本次导入的代际编号：on_close 是异步投递的，可能晚于下一次导入，
        -- handler 用它判断「这条回调属于哪个菜单」，过期的直接忽略（见 set_pending_import 注释）。
        on_close = { "script-message", "webdav-server-import-cancel", tostring(my_serial) },
    }
    mp.commandv("script-message-to", "uosc", "open-menu", mp_utils.format_json(menu))
end)

--- on_close 回调：确认菜单关闭（Esc / 顶替 / 取消）即清掉待导入条目。
--- 「确认导入」路径自己会在读取后立即清，所以这里多清一次是无害的幂等操作；
--- 真正的价值是覆盖那些脚本 otherwise 感知不到的关闭路径（Esc）。
--- @param serial string|number 该菜单创建时的代际编号；不等于当前代际说明这条
---   on_close 属于一个已被新导入顶替的旧菜单，此时**必须忽略**，否则会清掉新条目。
mp.register_script_message("webdav-server-import-cancel", function(serial)
    if tonumber(serial) ~= import_serial then return end
    set_pending_import(nil)
end)

mp.register_script_message("webdav-server-import-confirm", function()
    if not state.pending_import then
        mp.osd_message("⚠️ 没有待导入的服务器", 2)
        menu_mod.render_servers_menu()
        return
    end
    -- 既有未完成草稿会被覆盖。先明确告知，避免静默丢失用户之前填的内容
    -- （尤其是编辑流程的 edit_origin 身份锚）。
    local overwrite_note = server_draft and "已丢弃此前的未完成草稿" or nil
    -- 先取局部引用、紧接着就清 state：pending 含明文密码，读到即清，
    -- 后续构造 draft 用这份局部快照。注意**不能**指望渲染层替我们清——menu.lua
    -- 的 render_servers_menu 明确不碰 pending（理由见那里的注释），
    -- 这里不清就只剩确认菜单的 on_close 一条清理路径，而「确认」正是要立刻清的场景。
    local pending = state.pending_import
    set_pending_import(nil)
    -- 经由 commit_server_draft 的统一路径（校验/写盘/重开菜单）
    set_draft({
        name = pending.name, url = pending.url,
        user = pending.user, pass = pending.pass, edit_origin = nil,
    })
    commit_server_draft(overwrite_note)
end)

--- 删除服务器（二次确认菜单在 menu.lua 侧渲染）
mp.register_script_message("webdav-server-delete", function(name)
    for i, srv in ipairs(state.servers) do
        if srv.name == name then
            table.remove(state.servers, i)
            -- 删的是当前服务器：清空选中态（缓存以 URL 为键天然隔离，无需清）
            if state.current_server and state.current_server.name == name then
                state.current_server = nil
                state.current_loaded_url = ""
                state.cached_dir_items = {}
                state.last_visited_url = nil  -- 会话上下文字段一并清，防残留
            end
            -- default_server 指向被删服务器时同步清除（防悬空引用）
            if options.opts.default_server == name then
                options.opts.default_server = ""
                persist_conf_keys({ "default_server" })
            end
            -- 列表不允许删空（save 拒绝空列表；保留一台兜底）。
            -- 必须用 conf 回退条目，不能用 servers_mod.load() 重新读档——
            -- 磁盘 JSON 里可能还留着刚删的那台（persist=no 时删除不写盘），
            -- load() 会把它复活；persist=yes 时更糟，复活的条目会被随后的 save 写回。
            if #state.servers == 0 then
                local fallback = servers_mod.conf_fallback(options.opts)
                if fallback and fallback.url ~= "" then
                    table.insert(state.servers, fallback)
                    mp.osd_message("⚠️ 已删除最后一台，回退到 conf 单服务器配置", 3)
                else
                    mp.osd_message("⚠️ 已删除全部服务器，conf 中也没有可用配置", 3)
                end
            end
            if options.opts.persist_changes then
                local saved, save_err = servers_mod.save(state.servers)
                if not saved then
                    mp.osd_message("⚠️ 删除已生效但写盘失败（" .. tostring(save_err) .. "）", 4)
                end
            end
            mp.osd_message("🗑️ 已删除服务器：" .. name, 3)
            menu_mod.render_servers_menu()
            return
        end
    end
    mp.osd_message("⚠️ 服务器不存在：" .. tostring(name), 2)
end)

--- 测试连接。对服务器根发一次 PROPFIND Depth:0（只要 207 即视为可用），
--- 异步不阻塞；结果用独立菜单展示（不污染浏览状态，不改 current_server）。
--- 带代际守卫——连点测试或用户已离开时，旧请求的迟到结果不再抢开菜单。
local test_gen = 0
local test_handle = nil

mp.register_script_message("webdav-server-test", function(name)
    local srv = find_server_by_name(name)
    if not srv then
        mp.osd_message("⚠️ 服务器不存在：" .. tostring(name), 2)
        return
    end
    local ctx = options.server_ctx(srv)
    if not ctx then
        menu_mod.render_server_test_result(name, false, "URL 非法")
        return
    end
    -- 取消上一次仍在飞的测试（连点场景）
    if test_handle then
        local h = test_handle
        test_handle = nil
        pcall(mp.abort_async_command, h)
    end
    test_gen = test_gen + 1
    local my_gen = test_gen
    local function still_current()
        return test_gen == my_gen
    end
    mp.osd_message("🔍 正在测试「" .. name .. "」…", 2)
    local args = {
        -- 不用 -o /dev/null：mpv 调起的是 Windows 原生 curl.exe，它把 /dev/null
        -- 当普通路径去写并返回退出码 23（写 body 失败）。注意 mpv 回调的 ok 仍为 true、
        -- -w 状态码仍进 stdout，所以旧写法并不会真的判失败；但去掉更干净，
        -- 正文与状态码靠 -w 尾标记切分（与 browse.lua 的 PROPFIND 同款）
        "curl", "-s",
        "--connect-timeout", "5",
        "-w", "\n---HTTP_CODE---%{http_code}",
        "-X", "PROPFIND",
        "-u", ctx.user .. ":" .. ctx.pass,
        "-H", "Depth: 0",
        "--max-time", "10",
        srv.url,
    }
    local handle = mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(ok, res)
        -- 代际守卫：被后续测试取代（连点）或已被取消 → 丢弃结果，不再抢开菜单
        if not still_current() then return end
        test_handle = nil
        if not ok or not res then
            menu_mod.render_server_test_result(name, false, "无法启动请求")
            return
        end
        if res.status ~= 0 then
            local code = res.status
            local hint
            if     code ==  6 then hint = "无法解析主机名"
            elseif code ==  7 then hint = "连接被拒绝（服务未运行/端口错误）"
            elseif code == 28 then hint = "连接超时"
            elseif code == 35 or code == 51 or code == 60 then hint = "SSL/TLS 握手失败"
            elseif code == 67 then hint = "认证失败"
            else hint = string.format("curl 错误码 %d", code) end
            menu_mod.render_server_test_result(name, false, hint)
            return
        end
        -- 状态码在 -w 尾标记里（正文已混在 stdout，靠标记切出）
        local http_code = tonumber((res.stdout or ""):match("---HTTP_CODE---(%d+)%s*$")) or 0
        if http_code == 207 or http_code == 200 then
            menu_mod.render_server_test_result(name, true, "HTTP " .. http_code)
        elseif http_code == 401 then
            menu_mod.render_server_test_result(name, false, "认证失败 (401)，账号或密码错")
        elseif http_code == 403 then
            menu_mod.render_server_test_result(name, false, "无访问权限 (403)")
        elseif http_code == 404 then
            menu_mod.render_server_test_result(name, false, "路径不存在 (404)，检查 URL")
        elseif http_code == 405 then
            menu_mod.render_server_test_result(name, false, "服务器不支持 PROPFIND (405)")
        elseif http_code >= 500 then
            menu_mod.render_server_test_result(name, false, string.format("服务器内部错误 (%d)", http_code))
        else
            menu_mod.render_server_test_result(name, false, string.format("意外响应码 %d", http_code))
        end
    end)
    test_handle = handle
end)

mp.register_script_message("webdav-server-set-default", function(name)
    name = name or ""
    -- 空串 = 清除默认（总是先显示列表）
    if name ~= "" and not find_server_by_name(name) then
        mp.osd_message("⚠️ 服务器不存在：" .. name, 2)
        return
    end
    options.opts.default_server = name
    persist_conf_keys({ "default_server" })
    local hint = name ~= "" and ("⭐ 默认进入：" .. name) or "已清除默认进入（总是先显示列表）"
    mp.osd_message(hint, 2)
    menu_mod.render_servers_menu()
end)

--- 「💾 改动持久化」勾选切换（服务器列表菜单的唯一入口）。
--- 与 persist_conf_keys 不同，这里**不走门控**、直接写 conf：persist_changes 键的
--- 状态切换永远落盘。若也受门控约束，切成 no 后「切回 yes」的写盘会被门控挡掉，
--- 重启回到 no，用户在菜单里永远勾不回来（门控自锁，理由见文件头部
--- conf-persist 写盘器注释）。
--- 写盘失败不回滚内存值（与 persist_conf_keys 语义一致：内存值是用户想要的，
--- 写盘失败是磁盘层问题），仅 OSD 说明「重启后回到旧状态」。
mp.register_script_message("webdav-toggle-persist", function()
    options.opts.persist_changes = not options.opts.persist_changes
    local ok, err = conf_writer:persist_keys({ "persist_changes" })
    local note
    if not ok then
        note = "⚠️ 改动持久化写盘失败（" .. tostring(err) .. "），本次切换仅会话内生效，重启回到旧状态"
    elseif options.opts.persist_changes then
        note = "已开启，改动持久化保存"
    else
        note = "已关闭，改动仅本次会话"
    end
    mp.osd_message(note, 3)
    menu_mod.render_servers_menu()
end)

-- ================= 脚本就绪 =================

msg.debug("uosc_webdav v" .. VERSION .. " 已加载")