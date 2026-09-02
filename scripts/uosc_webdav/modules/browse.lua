-- modules/browse.lua — WebDAV 目录获取与解析（异步）
-- PROPFIND 用 mp.command_native_async 发起，等待期间菜单显示 spinner 占位条目，
-- 数据到达后 update-menu 原地替换，加载期间不再阻塞脚本线程、菜单不再闪断。

local msg = require 'mp.msg'
local options = require "modules.options"
local utils = require "modules.utils"
local sort_mod = require "modules.sort"

local M = {}

local state = nil
local ui = nil  -- 由 main.lua 注入：{ render, render_loading, render_error }

local loading_gen = 0  -- 在途请求代际：abort 后回调仍会被投递（killed），
                       -- 同 URL 快速重发时按 URL 判断新旧会失效，故用单调递增 token

function M.init(s, ui_callbacks)
    state = s
    ui = ui_callbacks
end

--- 取消在途 PROPFIND（新请求取代旧请求 / 用户关闭菜单放弃加载）。
--- 先清 state.loading 再调 abort：回调的守卫据此丢弃被取消请求的结果。
function M.cancel_loading()
    if state.loading then
        local abort = state.loading.abort
        state.loading = nil
        if abort then abort() end
    end
end

--- 异步 PROPFIND 结果处理：成功更新状态并原地刷新菜单，失败渲染错误态菜单。
local function handle_propfind_result(target_url, ok, res)
    if not ok or res.status ~= 0 then
        local code = ok and res.status or -1
        local hint
        if     code == -2 then hint = "请求已取消"
        elseif code == -1 then hint = "请求失败或被中止"
        elseif code ==  6 then hint = "无法解析主机名，请检查 URL 中的域名/IP"
        elseif code ==  7 then hint = "连接被拒绝，请确认服务正在运行且端口正确"
        elseif code == 28 then hint = "连接超时，请检查网络或防火墙"
        elseif code == 35 or code == 51 or code == 60 then hint = "SSL/TLS 握手失败，证书可能有问题"
        elseif code == 67 then hint = "认证失败，请检查用户名和密码"
        else hint = string.format("curl 错误码 %d", code) end

        msg.error("WebDAV curl error " .. tostring(code) .. ": " .. ((res and res.stderr) or ""))
        ui.render_error(target_url, hint)
        return
    end

    local body, http_code_str = res.stdout:match("^(.*)\n---HTTP_CODE---(%d+)$")
    if not body then
        body = res.stdout
        http_code_str = "0"
    end
    local http_code = tonumber(http_code_str) or 0

    if     http_code == 401 then
        ui.render_error(target_url, "认证失败 (401)，请检查用户名和密码")
        return
    elseif http_code == 403 then
        ui.render_error(target_url, "无访问权限 (403)")
        return
    elseif http_code == 404 then
        ui.render_error(target_url, "路径不存在 (404)，请检查 WebDAV URL")
        return
    elseif http_code == 405 then
        ui.render_error(target_url, "服务器不支持 PROPFIND (405)，请确认 WebDAV 服务已启用")
        return
    elseif http_code >= 500 then
        ui.render_error(target_url, string.format("服务器内部错误 (%d)", http_code))
        return
    elseif http_code ~= 207 then
        ui.render_error(target_url, string.format("意外的 HTTP 响应码 %d", http_code))
        return
    end

    local current_path_decoded = utils.url_decode(target_url:match("https?://[^/]+(/.*)") or "/")
    local norm_current = current_path_decoded:gsub("/$", "")

    local new_items = {}
    for block in body:gmatch("<[Dd]:[Rr]esponse>(.-)</[Dd]:[Rr]esponse>") do
        local raw_href = block:match("<[Dd]:[Hh]ref>([^<]+)</[Dd]:[Hh]ref>")
        if not raw_href then goto continue end

        local lastmod_str = block:match("<[Dd]:[Gg]etlastmodified>([^<]+)</[Dd]:[Gg]etlastmodified>") or ""
        local size_str    = block:match("<[Dd]:[Gg]etcontentlength>([^<]+)</[Dd]:[Gg]etcontentlength>") or ""

        if raw_href:match("^https?://") then
            raw_href = raw_href:match("https?://[^/]+(/.*)")
        end

        -- 解码 XML 实体（&amp; → & 等），修复含 & 等特殊字符的目录/文件名
        raw_href = utils.xml_decode(raw_href)
        local decoded_href = utils.url_decode(raw_href)
        local norm_decoded = decoded_href:gsub("/$", "")

        if norm_decoded ~= norm_current then
            local is_dir = raw_href:sub(-1) == "/"
            local name   = decoded_href:match("([^/]+)/?$") or decoded_href

            if is_dir then
                table.insert(new_items, {
                    is_dir  = true,
                    name    = name,
                    url     = options.protocol .. options.domain .. raw_href,
                    lastmod = lastmod_str
                })
            else
                local ext        = name:match("%.([^%.]+)$")
                local ext_lower   = ext and ext:lower()
                local is_video    = ext_lower and options.video_exts[ext_lower]
                local is_audio    = ext_lower and options.audio_exts[ext_lower]
                local is_sub      = ext_lower and options.sub_exts[ext_lower]
                local icon        = is_video and "🎬" or (is_audio and "🎵" or "📄")

                table.insert(new_items, {
                    is_dir   = false,
                    name     = name,
                    play_url = options.auth_prefix .. raw_href,
                    file_url = options.protocol .. options.domain .. raw_href,
                    lastmod  = lastmod_str,
                    size     = size_str,
                    is_video = is_video,
                    is_audio = is_audio,
                    is_sub   = is_sub,
                    icon     = icon
                })
            end
        end

        ::continue::
    end

    state.is_delete_mode = false
    state.selected_files = {}
    state.selected_dirs  = {}
    state.cached_dir_items = new_items
    state.current_loaded_url = target_url
    state.last_visited_url = target_url

    state.dir_cache[target_url] = { items = utils.copy_items(new_items) }
    state.dir_cursor[target_url] = nil
    sort_mod.apply_sort()

    -- 菜单仍开着（spinner 占位被原地替换）；若用户已 Esc 关闭则只更新数据，
    -- 不强制重开——menu_is_open 由 uosc close 事件同步，可信。
    if state.menu_is_open then
        ui.render()
    end
end

--- silent=true：不渲染 spinner 占位（供删除完成后的后台刷新使用）——
--- 菜单已关时不强开（数据到达后本就有"菜单没开就不渲染"守卫），菜单开着则原地换新列表。
function M.open_webdav_url(target_url, force_refresh, silent)
    if not force_refresh and state.dir_cache[target_url] then
        state.cached_dir_items = utils.copy_items(state.dir_cache[target_url].items)
        state.current_loaded_url = target_url
        state.last_visited_url = target_url
        state.is_delete_mode = false
        state.selected_files = {}
        state.selected_dirs = {}
        state.menu_is_open = false
        sort_mod.apply_sort()
        ui.render()
        return
    end

    -- 新请求取代在途请求（用户快速连续点击目录）
    M.cancel_loading()

    -- 立即渲染 spinner 占位菜单；若菜单已开则原地 update，全程不闪断
    if not silent then
        ui.render_loading(target_url)
    end

    local args = {
        "curl", "-s",
        "--connect-timeout", "5",
        "-w", "\n---HTTP_CODE---%{http_code}",
        "-X", "PROPFIND",
        "-u", options.opts.user .. ":" .. options.opts.pass,
        "-H", "Depth: 1",
        "--max-time", "10",
        target_url
    }

    loading_gen = loading_gen + 1
    local my_gen = loading_gen
    state.loading = { url = target_url, gen = my_gen, abort = nil }
    local handle, err = mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    }, function(ok, res)
        -- 守卫：代际不匹配（请求已被取消或被更新请求取代，含同 URL 重发）则静默丢弃
        if not state.loading or state.loading.gen ~= my_gen then return end
        state.loading = nil
        handle_propfind_result(target_url, ok, res)
    end)

    if not handle then
        -- 启动失败：fn 仍会被异步调用指示失败，但此时 loading 已清空，守卫会丢弃
        state.loading = nil
        if not silent then
            ui.render_error(target_url, "无法启动请求：" .. tostring(err))
        end
        return
    end

    -- command_native_async 返回的是句柄 table（非函数），
    -- 中止需经 mp.abort_async_command（mpv 手册 scripting.md）
    state.loading.abort = function() mp.abort_async_command(handle) end
end

return M
