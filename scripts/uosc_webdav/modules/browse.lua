-- modules/browse.lua — WebDAV 目录获取与解析

local msg = require 'mp.msg'
local options = require "modules.options"
local utils = require "modules.utils"
local sort_mod = require "modules.sort"

local M = {}

local state = nil
local render_fn = nil  -- 由 main.lua 注入

function M.init(s, render_callback)
    state = s
    render_fn = render_callback
end

function M.open_webdav_url(target_url, force_refresh)
    local prev_url = state.current_loaded_url
    local prev_items = state.cached_dir_items
    local prev_delete_mode = state.is_delete_mode
    local prev_selected_files = state.selected_files
    local prev_selected_dirs = state.selected_dirs

    local function restore_prev()
        state.current_loaded_url = prev_url
        if prev_url ~= "" then
            state.last_visited_url = prev_url
        end
        state.cached_dir_items = prev_items
        state.is_delete_mode = prev_delete_mode
        state.selected_files = prev_selected_files
        state.selected_dirs = prev_selected_dirs
        state.menu_is_open = false
        render_fn()
    end

    if not force_refresh and state.dir_cache[target_url] then
        state.cached_dir_items = utils.copy_items(state.dir_cache[target_url].items)
        state.current_loaded_url = target_url
        state.last_visited_url = target_url
        state.is_delete_mode = false
        state.selected_files = {}
        state.selected_dirs = {}
        state.menu_is_open = false
        sort_mod.apply_sort()
        render_fn()
        return
    end

    mp.osd_message("⏳ 正在加载 WebDAV 目录...", 2)

    local new_items = {}

    local args = {
        "curl", "-s",
        "-w", "\n---HTTP_CODE---%{http_code}",
        "-X", "PROPFIND",
        "-u", options.opts.user .. ":" .. options.opts.pass,
        "-H", "Depth: 1",
        "--max-time", "10",
        target_url
    }

    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    })

    if res.status ~= 0 then
        local code = res.status
        local hint
        if     code ==  6 then hint = "无法解析主机名，请检查 URL 中的域名/IP"
        elseif code ==  7 then hint = "连接被拒绝，请确认服务正在运行且端口正确"
        elseif code == 28 then hint = "连接超时，请检查网络或防火墙"
        elseif code == 35 or code == 51 or code == 60 then hint = "SSL/TLS 握手失败，证书可能有问题"
        elseif code == 67 then hint = "认证失败，请检查用户名和密码"
        else hint = string.format("curl 错误码 %d", code) end

        mp.osd_message("❌ " .. hint, 5)
        msg.error("WebDAV curl error " .. code .. ": " .. (res.stderr or ""))
        restore_prev()
        return
    end

    local body, http_code_str = res.stdout:match("^(.*)\n---HTTP_CODE---(%d+)$")
    if not body then
        body = res.stdout
        http_code_str = "0"
    end
    local http_code = tonumber(http_code_str) or 0

    if     http_code == 401 then
        mp.osd_message("❌ 认证失败 (401)，请检查用户名和密码", 5)
        restore_prev()
        return
    elseif http_code == 403 then
        mp.osd_message("❌ 无访问权限 (403)", 4)
        restore_prev()
        return
    elseif http_code == 404 then
        mp.osd_message("❌ 路径不存在 (404)，请检查 WebDAV URL", 4)
        restore_prev()
        return
    elseif http_code == 405 then
        mp.osd_message("❌ 服务器不支持 PROPFIND (405)，请确认 WebDAV 服务已启用", 4)
        restore_prev()
        return
    elseif http_code >= 500 then
        mp.osd_message(string.format("❌ 服务器内部错误 (%d)", http_code), 4)
        restore_prev()
        return
    elseif http_code ~= 207 then
        mp.osd_message(string.format("❌ 意外的 HTTP 响应码 %d", http_code), 4)
        restore_prev()
        return
    end

    local current_path_decoded = utils.url_decode(target_url:match("https?://[^/]+(/.*)") or "/")
    local norm_current = current_path_decoded:gsub("/$", "")

    for block in body:gmatch("<[Dd]:[Rr]esponse>(.-)</[Dd]:[Rr]esponse>") do
        local raw_href = block:match("<[Dd]:[Hh]ref>([^<]+)</[Dd]:[Hh]ref>")
        if not raw_href then goto continue end

        local lastmod_str = block:match("<[Dd]:[Gg]etlastmodified>([^<]+)</[Dd]:[Gg]etlastmodified>") or ""
        local size_str    = block:match("<[Dd]:[Gg]etcontentlength>([^<]+)</[Dd]:[Gg]etcontentlength>") or ""

        if raw_href:match("^https?://") then
            raw_href = raw_href:match("https?://[^/]+(/.*)")
        end

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
    state.menu_is_open = false
    render_fn()
end

return M