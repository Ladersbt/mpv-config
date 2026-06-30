-- modules/delete.lua — WebDAV 文件/文件夹删除

local msg = require 'mp.msg'
local options = require "modules.options"

local M = {}

local state = nil
local refresh_fn = nil  -- 由 main.lua 注入：删除完成后刷新目录的回调

function M.init(s, refresh_callback)
    state = s
    refresh_fn = refresh_callback
end

function M.webdav_delete_async(url, is_dir, cb)
    local args = {
        "curl", "-s", "-o", "/dev/null",
        "-w", "%{http_code}",
        "-X", "DELETE",
        "-u", options.opts.user .. ":" .. options.opts.pass,
    }
    if is_dir then
        table.insert(args, "-H")
        table.insert(args, "Depth: infinity")
    end
    table.insert(args, url)

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = args
    }, function(ok, res)
        local code = tonumber((res and res.stdout or ""):match("^%s*(%d+)%s*$")) or 0
        cb(code == 200 or code == 204 or code == 207)
    end)
end

function M.execute_delete()
    if state.delete_job.active then return end

    local delete_list = {}
    for _, item in ipairs(state.cached_dir_items) do
        if item.is_dir and state.selected_dirs[item.url] then
            table.insert(delete_list, { name = item.name, url = item.url, is_dir = true })
        elseif not item.is_dir and state.selected_files[item.file_url] then
            table.insert(delete_list, { name = item.name, url = item.file_url, is_dir = false })
        end
    end

    if #delete_list == 0 then
        mp.osd_message("⚠️ 没有选中任何项目", 2)
        return
    end

    state.delete_job.active  = true
    state.delete_job.total   = #delete_list
    state.delete_job.done    = 0
    state.delete_job.success = 0
    state.delete_job.fail    = 0
    state.delete_job.queue   = delete_list

    state.is_delete_mode = false
    state.selected_files = {}
    state.selected_dirs  = {}
    mp.commandv("script-message-to", "uosc", "close-menu", "webdav_browser")
    state.menu_is_open = false

    mp.osd_message(string.format("🗑️ 开始删除 %d 个项目...", state.delete_job.total), 2)

    local function delete_next()
        if not state.delete_job.active then return end

        local item = table.remove(state.delete_job.queue, 1)
        if not item then
            local msg_str = string.format("✅ 删除完成：成功 %d，失败 %d",
                state.delete_job.success, state.delete_job.fail)
            mp.osd_message(msg_str, 4)
            msg.info(msg_str)
            state.delete_job.active = false
            state.dir_cache[state.current_loaded_url] = nil
            -- 通过注入的回调刷新目录
            refresh_fn(state.current_loaded_url, true)
            return
        end

        state.delete_job.done = state.delete_job.done + 1
        mp.osd_message(string.format("🗑️ 删除中 %d/%d：%s",
            state.delete_job.done, state.delete_job.total, item.name), 2)
        msg.info(string.format("DELETE %s: %s",
            item.is_dir and "dir" or "file", item.url))

        M.webdav_delete_async(item.url, item.is_dir, function(ok)
            if ok then
                state.delete_job.success = state.delete_job.success + 1
                msg.info("删除成功: " .. item.url)
            else
                state.delete_job.fail = state.delete_job.fail + 1
                msg.warn("删除失败: " .. item.url)
            end
            delete_next()
        end)
    end

    delete_next()
end

return M