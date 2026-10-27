-- modules/delete.lua — WebDAV 文件/文件夹删除
-- 单删（item_actions 按钮 → 确认菜单 → 执行）与批量删（勾选 → 两步确认 → 进度菜单 + 可取消）。

local msg = require 'mp.msg'
local options = require "modules.options"

local M = {}

local state = nil
local refresh_fn = nil         -- 由 main.lua 注入：删除完成后刷新目录的回调
local render_progress_fn = nil -- 由 main.lua 注入：批量删除进度菜单渲染
local render_result_fn = nil   -- 由 main.lua 注入：批量删除结果菜单渲染

function M.init(s, refresh_callback, progress_callback, result_callback)
    state = s
    refresh_fn = refresh_callback
    render_progress_fn = progress_callback
    render_result_fn = result_callback
end

--- 发起 DELETE。凭据按 srv 参数显式传入（批量任务快照）或回落当前服务器。
--- 快照入 args 后飞行期间用户切服务器不影响在途请求。
--- @param srv 可选；不传则用 state.current_server（单删路径），
---        批量删除必须传 delete_job.srv（整批任务的凭据快照）
function M.webdav_delete_async(url, is_dir, cb, srv)
    srv = srv or state.current_server
    if not srv then
        cb(false)
        return
    end
    -- 凭据必须经 server_ctx 归一化，不能直接读 srv.user/srv.pass。
    -- 原因：老配置可能把凭据写在 url 里（http://user:pass@host/）
    -- 而 user/pass 字段留空。server_ctx 会把 url 的 userinfo 剥进 ctx.user/ctx.pass，
    -- 而 file_url 是用 ctx.domain（已剥净）拼的——此时若仍读 srv.user/pass 就会拿到空串，
    -- curl 收到 "-u :" 等于匿名，DELETE 直接 401（用户看到「删除失败」）。
    -- url 里残留的 userinfo 会被 curl 优先用于认证，所以这个坑此前并不显现。
    local ctx = options.server_ctx(srv)
    if not ctx then
        cb(false)
        return
    end
    local args = {
        -- 不用 -o /dev/null：mpv 调起的是 Windows 原生 curl.exe，它把 /dev/null
        -- 当普通路径去写并返回退出码 23（写 body 失败）。注意 mpv 回调的 ok 仍为 true、
        -- -w 状态码仍进 stdout，所以旧写法并不会真的判失败；
        -- 去掉只是更干净，正文与状态码靠 -w 尾标记切分（与 browse.lua 的 PROPFIND 同款）
        "curl", "-s",
        "-w", "\n---HTTP_CODE---%{http_code}",
        "-X", "DELETE",
        "-u", ctx.user .. ":" .. ctx.pass,
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
        local code = tonumber((res and res.stdout or ""):match("---HTTP_CODE---(%d+)%s*$")) or 0
        cb(ok and (code == 200 or code == 204 or code == 207))
    end)
end

--- 单文件删除（正常模式条目右侧按钮 → 确认菜单后执行）。
function M.execute_single_delete(url, is_dir, name)
    if state.delete_job.active then
        mp.osd_message("⚠️ 批量删除进行中，请稍候", 2)
        return
    end
    mp.osd_message("🗑️ 删除中：" .. name, 2)
    -- DELETE 飞行期间用户可能已导航到别处：缓存清理用发起时的目录，
    -- 刷新仅在用户仍停留在该目录时进行（否则只清缓存，不打扰当前视图）
    local dir_at_start = state.current_loaded_url
    M.webdav_delete_async(url, is_dir, function(ok)
        if ok then
            mp.osd_message("✅ 已删除：" .. name, 3)
            msg.info("删除成功: " .. url)
            state.dir_cache[dir_at_start] = nil
            if state.current_loaded_url == dir_at_start then
                refresh_fn(dir_at_start, true)
            end
        else
            mp.osd_message("❌ 删除失败：" .. name, 4)
            msg.warn("删除失败: " .. url)
        end
    end)
end

--- 取消批量删除：置 inactive，正在飞行的一个请求照常落地，剩余队列放弃。
function M.cancel_delete()
    if state.delete_job.active then
        state.delete_job.active = false
        mp.osd_message("⏹️ 正在取消删除...", 2)
    end
end

function M.execute_delete()
    -- 用户可 Esc 关闭进度菜单再发起新批量：静默吞掉会显得"确认了却没反应"
    if state.delete_job.active then
        mp.osd_message("⚠️ 批量删除进行中，请稍候", 2)
        return
    end

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
    -- 整批任务的凭据快照（不是每请求一次）——飞行期间切服务器，
    -- 队列剩余项仍用「发起时的那台」的凭据（URL 也属于那台，两者一致）。
    -- 注：select_server 现已直接取消进行中的批量删除（active=false），
    -- 这个快照是第二道防线（取消前的在途单项仍用对凭据）。
    state.delete_job.srv     = state.current_server
    state.delete_job.menu_dismissed = false  -- 新任务开始，允许进度/结果菜单重新显示

    state.is_delete_mode = false
    state.selected_files = {}
    state.selected_dirs  = {}

    -- 批量删除期间用户可能导航走：回调里的缓存清理/刷新都绑定发起时的目录
    local dir_at_start = state.current_loaded_url

    -- 进度菜单（type=webdav_browser）：确认菜单点击后已自动关闭，这里走 open 分支
    render_progress_fn(0, state.delete_job.total, "", 0, 0)

    local function delete_next()
        -- 被取消：放弃剩余队列，刷新反映已删部分
        if not state.delete_job.active then
            mp.osd_message(string.format("⏹️ 已取消删除（已完成 %d/%d）",
                state.delete_job.done, state.delete_job.total), 4)
            state.dir_cache[dir_at_start] = nil
            if state.current_loaded_url == dir_at_start then
                refresh_fn(dir_at_start, true)
            end
            return
        end

        local item = table.remove(state.delete_job.queue, 1)
        if not item then
            local msg_str = string.format("✅ 删除完成：成功 %d，失败 %d",
                state.delete_job.success, state.delete_job.fail)
            mp.osd_message(msg_str, 4)
            msg.info(msg_str)
            state.delete_job.active = false
            -- 先展示结果菜单，短暂停留后再静默刷新目录
            -- （菜单已关则不强开，数据后台更新；开着则原地换新列表）
            render_result_fn(state.delete_job.success, state.delete_job.fail)
            mp.add_timeout(1.5, function()
                state.dir_cache[dir_at_start] = nil
                if state.current_loaded_url == dir_at_start then
                    refresh_fn(dir_at_start, true)
                end
            end)
            return
        end

        state.delete_job.done = state.delete_job.done + 1
        render_progress_fn(state.delete_job.done, state.delete_job.total, item.name,
            state.delete_job.success, state.delete_job.fail)
        msg.info(string.format("DELETE %s: %s",
            item.is_dir and "dir" or "file", item.url))

        -- 凭据用任务级快照（delete_job.srv），不读实时 state.current_server
        M.webdav_delete_async(item.url, item.is_dir, function(ok)
            if ok then
                state.delete_job.success = state.delete_job.success + 1
                msg.info("删除成功: " .. item.url)
            else
                state.delete_job.fail = state.delete_job.fail + 1
                msg.warn("删除失败: " .. item.url)
            end
            delete_next()
        end, state.delete_job.srv)
    end

    delete_next()
end

return M
