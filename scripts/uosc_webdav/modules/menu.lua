-- modules/menu.lua — uosc 菜单渲染
-- 条目图标用 emoji 前缀（视觉偏好）；
-- 唯一例外是 spinner 占位条目与 item_actions 按钮：uosc 只认 Material Icons 名。

local mp_utils = require 'mp.utils'
local options = require "modules.options"
local utils = require "modules.utils"
local sort_mod = require "modules.sort"

local M = {}

local state = nil

function M.init(s)
    state = s
    -- 上一次正式列表菜单渲染的目标 URL（menu 模块内私有，不进 state 表：
    -- 只服务「内容是否切换了」的光标 realign 判定）。
    -- 只在 render_menu 成功分发正式列表时更新；loading/error 占位不更新，
    -- 否则 spinner→内容、服务器菜单→缓存根目录这类转换会丢导航信号。
    -- 排序切换走显式 realign 信号（set_realign_next_render），不经此判定。
    M._last_rendered_url = nil
    M._realign_latch = false
end

--- 外部显式请求下一次 render_menu 强制走 open-menu 重建（光标归位，目前仅排序切换用）。
--- 闩锁语义：置位后由下一次 render_menu 消费并自动清零；连置多次也只生效一次。
--- 不做成 render_menu 的参数是因为调用方（main.lua 的排序处理器）与渲染
--- 中间隔着 sort_mod.apply_sort 等步骤，闩锁比传参耦合更小。
function M.set_realign_next_render(v)
    M._realign_latch = v and true or false
end

--- 统一处理 open-menu / update-menu 分发。
---
--- 判定条件就是「同 type 已开」——实时读 user-data/uosc/menu/type，
--- 因为 uosc 的 update-menu 本身只认同 type 的已开菜单，跨 type 静默 no-op。
--- 这里读属性是安全的：本函数在正常渲染路径调用，不在 close 回调时机内，
--- 而 close 回调里读才有竞态（uosc 先 destroy 置 nil 再建新菜单，异步投递导致读早）。
--- 好处：菜单被用户 Esc 关掉后无需任何状态同步，下次渲染自然会看到 type=nil 走 open。
---
--- update-menu 的光标坑：uosc 的 Menu:update 会把脚本传入的 selected_index
--- 先写入、随即被旧菜单状态覆盖回去（menu_state_props 含 selected_index/
--- scroll_y/search），「菜单已开」的目录切换光标因此不跟手。所以内容切换
--- 不用 update 补救，直接走 open-menu 全新实例：selected_index 与滚动定位
--- 在 Menu:init 里无条件生效，不依赖 mouse_nav。
--- 高亮归宿：脚本 open-menu 永不带 mouse_nav 选项（uosc 只透传
--- opts.mouse_nav，open-menu 处理器不传），新实例 mouse_nav 初始 falsy，
--- 重建瞬间短暂带高亮；鼠标一动 on_global_mouse_move 置 true，下一次渲染
--- 期 blur 清掉未悬停条目的 selected_index——最终观感：鼠标流滚动恢复、
--- 高亮短暂存在后消失；键盘流高亮+滚动全恢复。uosc 原生的 select-menu-item
--- 不能用来补光标：它在 uosc 侧被 mouse_nav 守卫拦截，鼠标一动就不执行。
--- 代价：菜单重建（旧菜单立即关闭、新菜单 fade-in）与搜索态丢弃——内容
--- 切换场景两者本就该重置；排序切换还会吞掉「切换排序」子菜单停留（点完
--- 排序项回根列表，预期取舍——键盘热键流无子菜单上下文，不受影响）。
--- @param realign boolean|nil 内容切换（换目录/换排序/错误态）时传 true →
---   强制走 open-menu 重建；同内容重渲染（勾选、删除模式进出、删除进度
---   推进）不传 → 走 update-menu 原地更新，保持用户已移到的光标位置。
---   注意「刷新当前目录」虽同 URL，但 loading 占位介入 + browse.lua 清
---   dir_cursor，最终光标落回顶部区（与 HEAD 行为一致，非保持）。
local function dispatch_menu(menu, realign)
    local menu_json = mp_utils.format_json(menu)
    local utype = mp.get_property_native("user-data/uosc/menu/type")
    if utype == menu.type and not realign then
        mp.commandv("script-message-to", "uosc", "update-menu", menu_json)
    else
        mp.commandv("script-message-to", "uosc", "open-menu", menu_json)
    end
end

--- 计算目标 URL 的父目录 URL（无父级/已到当前服务器根时返回 nil）。
local function parent_of(url)
    local root = state.current_server and state.current_server.url or nil
    if not root or url == root then return nil end
    local parent_path = url:match("^(.*)/[^/]+/?$")
    if not parent_path then return nil end
    return parent_path .. "/"
end

--- 公共菜单骨架（type/title/callback 与占位、错误、正式菜单保持一致，
--- 保证 update-menu 切换时菜单实例不重建）。
local function base_menu(target_url, items)
    local path_part = target_url ~= "" and target_url:match("https?://[^/]+(/.*)") or nil
    local current_path_decoded = path_part and utils.url_decode(path_part) or "/"
    return {
        type          = "webdav_browser",
        title         = "WebDAV:" .. current_path_decoded,
        items         = items,
        search_style  = "disabled",  -- 占位/错误态无可搜索内容
        callback      = {mp.get_script_name(), 'menu-event'},
    }
end

--- 正常模式条目右侧的单删动作按钮（uosc item_actions）。
--- outside：优先放菜单外侧，避免盖住条目的大小/时间 hint。
--- filter_hidden：搜索过滤后隐藏按钮——过滤后 items 被 uosc 重排，
--- 视觉位置与全量列表错位，隐藏按钮可避免误点（定位兜底见 main.lua find_delete_target）。
local delete_action = {
    { name = "delete", icon = "delete", label = "删除", filter_hidden = true },
}

--- 加载中占位菜单：spinner 条目 + 可选的返回上一级。
--- 配合 browse.lua 的异步 PROPFIND：点击目录后立即渲染，数据到达后 update-menu 原地替换。
function M.render_loading_menu(target_url)
    local items = {}
    local parent_url = parent_of(target_url)
    if parent_url then
        table.insert(items, {
            title = "↩️ 返回上一级",
            value = string.format("script-message webdav-go-back %q", parent_url),
            keep_open = false
        })
    end
    table.insert(items, {
        icon = "spinner",       -- uosc 特殊图标名，渲染为旋转动画（emoji 无法替代）
        title = "正在加载目录...",
        selectable = false,
        value = ""
    })

    local menu = base_menu(target_url, items)
    menu.footnote = "正在获取目录内容"
    dispatch_menu(menu)
end

--- 加载失败菜单：错误说明 + 重试 + 返回上一级。
--- 取代旧的"OSD 报错 5 秒 + 静默回旧目录"，错误原因在菜单内留痕。
function M.render_error_menu(target_url, error_msg)
    local items = {
        {
            title = "❌ 加载失败",
            hint = error_msg,
            selectable = false,
            muted = true,
            value = ""
        },
        {
            title = "🔄 重试",
            value = string.format("script-message webdav-open %q %q", target_url, "true"),
            keep_open = false
        },
    }
    local parent_url = parent_of(target_url)
    if parent_url then
        table.insert(items, {
            title = "↩️ 返回上一级",
            value = string.format("script-message webdav-go-back %q", parent_url),
            keep_open = false
        })
    end

    local menu = base_menu(target_url, items)
    menu.selected_index = 2  -- 默认选中"重试"（第 1 条为不可选的错误说明）
    menu.footnote = error_msg
    dispatch_menu(menu, true)  -- 内容切换（正常列表→错误态），open-menu 重建、光标落"重试"
end

--- 单文件删除确认菜单（点条目右侧删除按钮后弹出）。
--- 独立 type 顶掉 webdav_browser（uosc 会先关掉旧菜单再开新的，不依赖任何脚本状态）；
--- 无 callback：uosc 直接执行条目 value 并自动关闭。
function M.render_single_delete_confirm(target)
    local menu = {
        type         = "webdav_delete_confirm",
        title        = "删除「" .. target.name .. "」？",
        search_style = "disabled",
        items = {
            {
                title = "✅ 确认删除（不可恢复）",
                value = string.format("script-message webdav-execute-single-delete %q %s %q",
                    target.url, tostring(target.is_dir), target.name),
                keep_open = false
            },
            {
                title = "↩️ 取消",
                value = "script-message webdav-reopen",
                keep_open = false
            },
        },
    }
    mp.commandv("script-message-to", "uosc", "open-menu", mp_utils.format_json(menu))
end

--- 批量删除确认菜单（第二梯队确认：删除模式的"确认删除"点击后先到这里）。
function M.render_batch_delete_confirm(count)
    local menu = {
        type         = "webdav_delete_confirm",
        title        = string.format("确认删除 %d 个项目？", count),
        search_style = "disabled",
        items = {
            {
                title = "✅ 确认删除（不可恢复）",
                value = "script-message webdav-execute-delete",
                keep_open = false
            },
            {
                title = "↩️ 取消",
                value = "script-message webdav-reopen",
                keep_open = false
            },
        },
    }
    mp.commandv("script-message-to", "uosc", "open-menu", mp_utils.format_json(menu))
end

--- 服务器删除确认菜单（服务器列表行的删除按钮 → 这里二次确认）。
--- 与文件删除确认同 type（webdav_delete_confirm）：独占替换，互不嵌套。
function M.render_server_delete_confirm(name)
    local menu = {
        type         = "webdav_delete_confirm",
        title        = "删除服务器「" .. name .. "」？",
        search_style = "disabled",
        items = {
            {
                title = "✅ 确认删除（列表中移除并写盘）",
                value = string.format("script-message webdav-server-delete %q", name),
                keep_open = false
            },
            {
                title = "↩️ 取消",
                value = "script-message webdav-open-servers",
                keep_open = false
            },
        },
    }
    mp.commandv("script-message-to", "uosc", "open-menu", mp_utils.format_json(menu))
end

--- 批量删除进度菜单：spinner + 实时计数 + 可取消。
--- 用户删除进行中 Esc 关闭菜单后（menu_dismissed）不再强开；
--- 进度过程仅靠日志跟踪，终态（完成/取消/失败）仍有 OSD 汇报。
function M.render_delete_progress(done, total, name, ok_count, fail_count)
    if state.delete_job.menu_dismissed then return end
    local items = {
        {
            icon = "spinner",
            title = string.format("删除中 %d/%d", done, total),
            hint = name,
            selectable = false,
            value = ""
        },
        {
            title = "⏹️ 取消剩余删除",
            value = "script-message webdav-cancel-delete",
            keep_open = true
        },
    }
    local menu = base_menu(state.current_loaded_url, items)
    menu.footnote = string.format("成功 %d · 失败 %d", ok_count, fail_count)
    dispatch_menu(menu)
end

--- 批量删除结果菜单：短暂展示后由 delete.lua 延迟刷新目录。
--- 与进度菜单同理：用户已手动关闭则不重开（终态 OSD 由 delete.lua 负责）。
function M.render_delete_result(ok_count, fail_count)
    if state.delete_job.menu_dismissed then return end
    local items = {
        {
            title = string.format("✅ 删除完成：成功 %d，失败 %d", ok_count, fail_count),
            selectable = false,
            value = ""
        },
    }
    local menu = base_menu(state.current_loaded_url, items)
    menu.footnote = "正在刷新目录…"
    dispatch_menu(menu)
end

function M.separator_item()
    return {
        title = "文件列表",
        hint = "排序：" .. (options.sort_labels[sort_mod.get_sort_mode()] or sort_mod.get_sort_mode()),
        selectable = false,
        muted = false
    }
end

function M.render_menu()
    local path_part = state.current_loaded_url ~= "" and state.current_loaded_url:match("https?://[^/]+(/.*)") or nil
    local current_path_decoded = path_part and utils.url_decode(path_part) or "/"

    local sel_file_count = 0
    local sel_dir_count  = 0
    for _ in pairs(state.selected_files) do sel_file_count = sel_file_count + 1 end
    for _ in pairs(state.selected_dirs)  do sel_dir_count  = sel_dir_count  + 1 end
    local sel_count = sel_file_count + sel_dir_count

    local video_count = 0
    local total_selectable = #state.cached_dir_items
    for _, item in ipairs(state.cached_dir_items) do
        if not item.is_dir and item.is_video then video_count = video_count + 1 end
    end

    local items = {}

    if state.is_delete_mode then
        local all_selected = (sel_count == total_selectable) and total_selectable > 0
        table.insert(items, {
            title = all_selected and "☑️ 取消全选" or "⬜ 全选所有项目",
            value = all_selected and "script-message webdav-select-all false"
                                  or "script-message webdav-select-all true",
            keep_open = true
        })

        if sel_count > 0 then
            local label = ""
            if sel_file_count > 0 and sel_dir_count > 0 then
                label = string.format("✅ 确认删除 %d 个文件 + %d 个文件夹 (不可恢复)", sel_file_count, sel_dir_count)
            elseif sel_dir_count > 0 then
                label = string.format("✅ 确认删除 %d 个文件夹 (不可恢复)", sel_dir_count)
            else
                label = string.format("✅ 确认删除 %d 个文件 (不可恢复)", sel_file_count)
            end
            table.insert(items, {
                title = label,
                -- 两步确认：先弹 webdav_delete_confirm 子菜单，不再一步开删
                value = "script-message webdav-ask-delete",
                keep_open = false
            })
        else
            table.insert(items, {
                title = "⚠️ 请在下方勾选要删除的项目",
                selectable = false
            })
        end

        table.insert(items, {
            title = "↩️ 退出删除模式",
            value = "script-message webdav-toggle-mode",
            keep_open = false
        })
    else
        local parent_url = parent_of(state.current_loaded_url)
        if parent_url then
            table.insert(items, {
                title = "↩️ 返回上一级",
                value = string.format("script-message webdav-go-back %q", parent_url),
                keep_open = false
            })
        end

        -- 服务器管理入口：仅在服务器根目录显示（切服务器是「主页」操作，
        -- 不该出现在每个子目录菜单里）。子目录里想切服务器：按 Q 回根目录，或走
        -- 右键菜单「导航 > WebDAV > 管理 WebDAV 服务器」（input.conf webdav-open-servers）。
        -- 单服务器时这是加第二台的唯一 UI 入口，根目录仍显示（条件若写成
        -- #state.servers > 1 会让单服务器用户彻底进不去管理菜单，死路）。
        -- 根判定可靠性：根目录加载的 URL 就是 current_server.url 同一字符串
        -- （browse.lua 原样透传，不重新拼接），且 servers.validate 强制 url 以 / 结尾，
        -- 不存在 /dav 与 /dav/ 判不等的错位。
        if state.current_server and state.current_loaded_url == state.current_server.url then
            table.insert(items, {
                title = #state.servers > 1 and "⇄ 切换服务器" or "☁️ 管理服务器",
                hint = state.current_server.name,
                value = "script-message webdav-open-servers",
                keep_open = false
            })
        end

        table.insert(items, {
            title = "🔄 刷新当前目录",
            value = string.format("script-message webdav-open %q %q", state.current_loaded_url, "true"),
            keep_open = false
        })
        table.insert(items, {
            title = "🗑️ 进入删除模式",
            value = "script-message webdav-toggle-mode",
            keep_open = true
        })
        table.insert(items, {
            title = "📶 切换排序",
            items = {
                {
                    title  = options.sort_labels["name_asc"],
                    hint   = sort_mod.get_sort_mode() == "name_asc" and "☑️" or "⬜",
                    value  = "script-message webdav-set-sort name_asc",
                    active = sort_mod.get_sort_mode() == "name_asc" and 1 or nil,
                    keep_open = false,
                },
                {
                    title  = options.sort_labels["name_desc"],
                    hint   = sort_mod.get_sort_mode() == "name_desc" and "☑️" or "⬜",
                    value  = "script-message webdav-set-sort name_desc",
                    active = sort_mod.get_sort_mode() == "name_desc" and 1 or nil,
                    keep_open = false,
                },
                {
                    title  = options.sort_labels["time_desc"],
                    hint   = sort_mod.get_sort_mode() == "time_desc" and "☑️" or "⬜",
                    value  = "script-message webdav-set-sort time_desc",
                    active = sort_mod.get_sort_mode() == "time_desc" and 1 or nil,
                    keep_open = false,
                },
                {
                    title  = options.sort_labels["time_asc"],
                    hint   = sort_mod.get_sort_mode() == "time_asc" and "☑️" or "⬜",
                    value  = "script-message webdav-set-sort time_asc",
                    active = sort_mod.get_sort_mode() == "time_asc" and 1 or nil,
                    keep_open = false,
                },
                {
                    title  = options.sort_labels["size_desc"],
                    hint   = sort_mod.get_sort_mode() == "size_desc" and "☑️" or "⬜",
                    value  = "script-message webdav-set-sort size_desc",
                    active = sort_mod.get_sort_mode() == "size_desc" and 1 or nil,
                    keep_open = false,
                },
                {
                    title  = options.sort_labels["size_asc"],
                    hint   = sort_mod.get_sort_mode() == "size_asc" and "☑️" or "⬜",
                    value  = "script-message webdav-set-sort size_asc",
                    active = sort_mod.get_sort_mode() == "size_asc" and 1 or nil,
                    keep_open = false,
                },
            },
        })
    end

    table.insert(items, M.separator_item())

    for _, item in ipairs(state.cached_dir_items) do
        if item.is_dir then
            if state.is_delete_mode then
                local checkbox = state.selected_dirs[item.url] and "☑️" or "⬜"
                table.insert(items, {
                    title = checkbox .. " 📁 " .. item.name,
                    value = string.format("script-message webdav-toggle-dir %q", item.url),
                    keep_open = true
                })
            else
                local time_hint = item.lastmod and utils.format_lastmod(item.lastmod, options.month_map) or ""
                table.insert(items, {
                    title = "📁 " .. item.name,
                    hint  = time_hint,
                    value = string.format("script-message webdav-open %q %q %q",
                        item.url, "false", item.url),
                    keep_open = false,
                    actions = delete_action,
                    actions_place = "outside",
                })
            end
        else
            if state.is_delete_mode then
                local checkbox = state.selected_files[item.file_url] and "☑️" or "⬜"
                table.insert(items, {
                    title = checkbox .. " " .. item.name,
                    value = string.format("script-message webdav-toggle-file %q", item.file_url),
                    keep_open = true
                })
            else
                local size_hint = item.size and utils.format_size(item.size) or ""
                local time_hint = item.lastmod and utils.format_lastmod(item.lastmod, options.month_map) or ""
                local hint_parts = {}
                if size_hint ~= "" then table.insert(hint_parts, size_hint) end
                if time_hint ~= "" then table.insert(hint_parts, time_hint) end
                local combined_hint = #hint_parts > 0 and table.concat(hint_parts, " | ") or ""
                table.insert(items, {
                    title = item.icon .. " " .. item.name,
                    hint  = combined_hint,
                    value = string.format("script-message webdav-play %q", item.play_url),
                    keep_open = false,
                    actions = delete_action,
                    actions_place = "outside",
                })
            end
        end
    end

    if #state.cached_dir_items == 0 then
        table.insert(items, {
            title = "📂 空目录",
            selectable = false,
            muted = true,
            value = ""
        })
    end

    local selected_index = 1
    local cursor_child_url = state.dir_cursor[state.current_loaded_url]
    if cursor_child_url then
        for idx, it in ipairs(items) do
            if it.value and it.value:find(cursor_child_url, 1, true) then
                selected_index = idx
                break
            end
        end
    end

    local menu = base_menu(state.current_loaded_url, items)
    menu.selected_index  = selected_index
    menu.search_style    = "on_demand"
    menu.search_debounce = 300

    -- 内容切换判定：URL 变了（进入子目录 / 返回上级 / 回根）才让 dispatch_menu
    -- 走 open-menu 重建（selected_index 无条件生效，光标归位）；同 URL 重渲染
    -- （勾选、删除模式进出）走 update-menu 原地更新，保持用户用方向键移到的
    -- 位置。「刷新当前目录」虽同 URL，但 loading 占位介入 + dir_cursor 被清，
    -- 最终光标落回顶部区（与 HEAD 一致，非保持）。
    -- _last_rendered_url 只在正式列表渲染时更新（见 init 注释），loading/error
    -- 占位不碰它，所以 spinner→正式列表、错误→重试成功这类转换仍算「切换」。
    local is_new_content = (M._last_rendered_url ~= state.current_loaded_url) or M._realign_latch
    M._realign_latch = false
    M._last_rendered_url = state.current_loaded_url

    if state.is_delete_mode then
        menu.footnote = string.format("已选择 %d 个项目", sel_count)
    else
        local dir_count   = 0
        local audio_count = 0
        local other_count = 0
        for _, item in ipairs(state.cached_dir_items) do
            if item.is_dir then
                dir_count = dir_count + 1
            elseif item.is_audio then
                audio_count = audio_count + 1
            elseif not item.is_video then
                other_count = other_count + 1
            end
        end
        local parts = {}
        if dir_count   > 0 then table.insert(parts, string.format("📁 %d 个文件夹", dir_count))  end
        if video_count > 0 then table.insert(parts, string.format("🎬 %d 个视频",   video_count)) end
        if audio_count > 0 then table.insert(parts, string.format("🎵 %d 个音频",    audio_count)) end
        if other_count > 0 then table.insert(parts, string.format("📄 %d 个其他文件",   other_count)) end
        menu.footnote = #parts > 0 and table.concat(parts, "　") or "📂 空目录"
    end

    dispatch_menu(menu, is_new_content)
end

-- ================= 服务器列表菜单（多服务器入口） =================

--- 服务器列表菜单（type=webdav_servers）。
--- 结构：服务器行（叶子项，激活=选中直入；hint=host；当前项打标记）
---   + 新增 / 剪贴板导入 / 默认服务器管理 / 返回浏览。
--- 密码绝不进菜单 JSON（mpv 的 verbose 日志会把菜单树全量落盘）——hint 只显示「已设置/未设置」。
function M.render_servers_menu()
    local items = {}
    local default_name = options.opts.default_server

    -- 注：pending_import 的清理**不在**这里做。渲染层不该改「剪贴板待导入」这种业务状态，
    -- 且这里只在渲染时触发、覆盖不到「按 Esc 关掉确认菜单后不再回列表」的路径。
    -- 正确清理点在确认菜单自己的 on_close（见 main.lua 的 webdav-server-import-clipboard），
    -- 它覆盖 Esc / 确认 / 取消 / 被顶替全部关闭路径。

    -- 有未完成草稿时置顶提示（用户 Esc 中断录入后 draft 会保留，续填机制需要可见）
    local draft = state.server_draft
    if draft then
        local filled = {}
        if draft.url and draft.url ~= "" then table.insert(filled, "地址") end
        if draft.name and draft.name ~= "" then table.insert(filled, "名称") end
        if draft.user and draft.user ~= "" then table.insert(filled, "账号") end
        if draft.pass and draft.pass ~= "" then table.insert(filled, "密码") end
        table.insert(items, {
            title = "📝 有未完成的录入草稿",
            hint = #filled > 0 and (table.concat(filled, "/") .. " 已填") or "尚未填写",
            muted = true,
            selectable = false,
            value = "",
        })
        table.insert(items, {
            title = "▶️ 继续上次录入",
            value = draft.edit_origin and "script-message webdav-server-edit-resume"
                                       or "script-message webdav-server-new-resume",
            keep_open = false,
        })
        table.insert(items, {
            title = "🗑️ 丢弃草稿",
            value = "script-message webdav-server-discard-draft",
            keep_open = true,
        })
        table.insert(items, {
            title = "服务器列表",
            selectable = false,
            muted = true,
            separator = true,
        })
    end

    for _, srv in ipairs(state.servers) do
        -- host 取自 server_ctx 的 domain（已剥离 userinfo），
        -- 不能直接从 srv.url 截取——老配置的 url 可能内嵌 user:pass@，
        -- 那样 hint 会把密码明文显示在服务器列表行上
        local ctx = options.server_ctx(srv)
        local host = (ctx and ctx.domain) or srv.url:match("^https?://([^/]+)") or srv.url
        local marks = {}
        if state.current_server and srv.name == state.current_server.name then
            table.insert(marks, "▶ 当前")
        end
        if default_name ~= "" and srv.name == default_name then
            table.insert(marks, "⭐ 默认")
        end
        -- 认证标记同样必须看归一化后的 ctx.user：老配置的凭据可能只在 url 里，
        -- 此时 srv.user 是空串但 server_ctx 已把它剥进 ctx.user，实际是需要认证的。
        -- 读 srv.user 会让这类服务器显示成「无需密码」，点进去才发现要凭据。
        if ctx and ctx.user ~= "" then
            table.insert(marks, "🔑")
        end
        table.insert(items, {
            title = "☁️ " .. srv.name,
            hint  = (#marks > 0 and (table.concat(marks, " ") .. "  ") or "") .. host,
            -- value 为主命令（选中直入）；actions 按钮在 callback 里按 event.action 分流，
            -- 分流前绝不能执行 value（点删除按钮会执行主命令）
            value = string.format("script-message webdav-select-server %q", srv.name),
            keep_open = false,
            actions = {
                { name = "test", icon = "network_check", label = "测试", filter_hidden = true },
                { name = "edit", icon = "edit", label = "编辑", filter_hidden = true },
                { name = "delete", icon = "delete", label = "删除", filter_hidden = true },
            },
            actions_place = "outside",
        })
    end

    table.insert(items, {
        title = "服务器管理",
        selectable = false,
        muted = true,
        separator = true,
    })
    -- 写盘状态做成可勾选开关。右侧 ☑️/⬜ 呈现状态
    -- （与排序子菜单的 hint 惯例一致），点击翻转。开关自身状态**始终写盘**、不受门控
    -- 约束（webdav-toggle-persist 旁路，理由见 main.lua 注释），不存在「关掉后勾不回来」
    -- 的自锁。keep_open=true + render_servers_menu 原地 update：点完勾选框即时翻转、菜单不关。
    table.insert(items, {
        title = "💾 改动持久化",
        hint = options.opts.persist_changes and "☑️" or "⬜",
        value = "script-message webdav-toggle-persist",
        keep_open = true,
    })
    table.insert(items, {
        title = "➕ 新增服务器",
        value = "script-message webdav-server-new",
        keep_open = false,
    })
    table.insert(items, {
        title = "📋 从剪贴板导入",
        hint = "粘贴含账号密码的完整 URL，整串导入",
        value = "script-message webdav-server-import-clipboard",
        keep_open = false,
    })
    -- 单服务器时「默认进入」无意义（恒直入，default_server 不参与判定），不显示
    if #state.servers > 1 then
        local default_items = {
            {
                title = "总是先显示列表",
                hint = default_name == "" and "☑️" or "⬜",
                value = "script-message webdav-server-set-default ",
                active = default_name == "" and 1 or nil,
                keep_open = false,
            },
        }
        for _, srv in ipairs(state.servers) do
            table.insert(default_items, {
                title = srv.name,
                hint = srv.name == default_name and "☑️" or "⬜",
                value = string.format("script-message webdav-server-set-default %q", srv.name),
                active = srv.name == default_name and 1 or nil,
                keep_open = false,
            })
        end
        table.insert(items, {
            title = "⭐ 默认进入",
            hint = default_name ~= "" and default_name or "（列表）",
            items = default_items,
        })
    end

    -- 已选中过服务器时才提供「返回浏览」
    if state.current_server then
        table.insert(items, {
            title = "↩️ 返回文件浏览",
            value = "script-message webdav-back-to-browser",
            keep_open = false,
        })
    end

    local menu = {
        type = "webdav_servers",
        title = string.format("WebDAV 服务器（%d 台）", #state.servers),
        items = items,
        -- 服务器通常就几台，搜索纯属干扰；且搜索激活后 actions 按钮被 filter_hidden 隐藏，
        -- 会让「编辑/删除」按钮莫名消失，故禁用搜索
        search_style = "disabled",
        callback = { mp.get_script_name(), "menu-event" },
        footnote = options.opts.persist_changes and "选中即进入 · 改动会保存"
                   or "选中即进入 · 改动仅本次会话",
    }
    dispatch_menu(menu)
end

--- 连接测试结果菜单。
--- 独立 type：测试是从服务器列表触发的异步操作，用一个临时菜单承载结果，
--- 关闭即回列表（「返回」项直接回 webdav_servers）。
--- @param name   服务器名
--- @param ok     boolean 是否连通
--- @param detail 说明串（成功=HTTP 状态，失败=错误原因）
function M.render_server_test_result(name, ok, detail)
    local items = {
        {
            title = ok and "✅ 连接成功" or "❌ 连接失败",
            hint = detail or "",
            selectable = false,
            value = "",
        },
        { title = "服务器管理", selectable = false, muted = true, separator = true },
        {
            title = "↩️ 返回服务器列表",
            value = "script-message webdav-open-servers",
            keep_open = false,
        },
    }
    local menu = {
        type = "webdav_test_result",
        title = "测试连接：" .. name,
        search_style = "disabled",
        items = items,
        footnote = ok and "地址与凭据均可用" or "检查地址、账号密码与网络",
    }
    mp.commandv("script-message-to", "uosc", "open-menu", mp_utils.format_json(menu))
end

return M
