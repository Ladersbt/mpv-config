-- modules/menu.lua — uosc 菜单渲染
-- 条目图标用 emoji 前缀（用户实机确认的视觉偏好）；
-- 唯一例外是 spinner 占位条目与 item_actions 按钮：uosc 只认 Material Icons 名。

local mp_utils = require 'mp.utils'
local options = require "modules.options"
local utils = require "modules.utils"
local sort_mod = require "modules.sort"

local M = {}

local state = nil

function M.init(s)
    state = s
end

--- 统一处理 open-menu / update-menu 分发：
--- 菜单已开（menu_is_open 由 uosc close 事件同步）则原地 update，否则 open。
--- 异步加载（spinner 占位 → update 换真实内容）依赖此行为保证菜单全程不关。
local function dispatch_menu(menu)
    local menu_json = mp_utils.format_json(menu)
    if state.menu_is_open then
        mp.commandv("script-message-to", "uosc", "update-menu", menu_json)
    else
        mp.commandv("script-message-to", "uosc", "open-menu", menu_json)
        state.menu_is_open = true
    end
end

--- 计算目标 URL 的父目录 URL（无父级时返回 nil）。
local function parent_of(url)
    if url == options.opts.url then return nil end
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
    dispatch_menu(menu)
end

--- 单文件删除确认菜单（点条目右侧删除按钮后弹出）。
--- 独立 type 顶掉 webdav_browser（其 close 事件会把 menu_is_open 复位）；
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

--- 批量删除进度菜单：spinner + 实时计数 + 可取消（F-e）。
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

    dispatch_menu(menu)
end

return M
