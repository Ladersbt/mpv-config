-- modules/menu.lua — uosc 菜单渲染

local mp_utils = require 'mp.utils'
local options = require "modules.options"
local utils = require "modules.utils"
local sort_mod = require "modules.sort"

local M = {}

local state = nil

function M.init(s)
    state = s
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
                value = "script-message webdav-execute-delete",
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
        if state.current_loaded_url ~= options.opts.url and state.current_loaded_url ~= "" then
            local parent_path = state.current_loaded_url:match("^(.*)/[^/]+/?$")
            if parent_path then
                table.insert(items, {
                    title = "↩️ 返回上一级",
                    value = string.format("script-message webdav-go-back %q", parent_path .. "/"),
                    keep_open = false
                })
            end
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
                    keep_open = false
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
                    value = string.format("script-message webdav-play %q %q",
                        item.play_url, tostring(item.is_video or false)),
                    keep_open = false
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

    local menu = {
        type            = "webdav_browser",
        title           = (state.is_delete_mode and "【批量删除】" or "WebDAV:") .. current_path_decoded,
        items           = items,
        selected_index  = selected_index,
        search_style    = "on_demand",
        search_debounce = 300,
    }

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

    local menu_json = mp_utils.format_json(menu)

    if state.menu_is_open then
        mp.commandv("script-message-to", "uosc", "update-menu", menu_json)
    else
        mp.commandv("script-message-to", "uosc", "open-menu", menu_json)
        state.menu_is_open = true
    end
end

return M