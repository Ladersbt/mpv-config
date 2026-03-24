local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

-- ================= 配置区域 =================
local opts = {
    url = "http://192.168.1.100:8080/dav/", -- WebDAV 根目录地址，务必以 / 结尾
    user = "admin",                         -- 用户名
    pass = "password",                      -- 密码
    default_sort = "name_asc",              -- 目录默认排序
    video_only = true,                      -- 是否仅播放视频
}

options.read_options(opts, "uosc_webdav")

local video_exts = {
    mp4 = true, mkv = true, avi = true, mov = true, wmv = true,
    flv = true, webm = true, m2ts = true, ts = true, rmvb = true,
    m4v = true, iso = true, vob = true
}

local sub_exts = {
    srt = true, ass = true, ssa = true, vtt = true,
    sup = true, sub = true, idx = true, smi = true, lrc = true
}

-- slang 优先级顺序，靠前的优先 select
local slang = {"jpsc","chs","sc","zh-hans","zh-cn","jptc","cht","tc","zh-hant","zh-hk","zh-tw","chi","zho","zh"}
local function slang_priority(name)
    local lower = name:lower()
    for i, tag in ipairs(slang) do
        if lower:find(tag, 1, true) then return i end
    end
    return #slang + 1
end
-- ============================================

local last_visited_url = opts.url
local protocol, domain = opts.url:match("^(https?://)([^/]+)")
local auth_prefix = protocol .. opts.user .. ":" .. opts.pass .. "@" .. domain

local function url_decode(str)
    str = string.gsub(str, "+", " ")
    str = string.gsub(str, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return str
end

-- 状态管理变量
local is_delete_mode = false
local selected_files = {}        -- key = file_url，value = true
local selected_dirs  = {}        -- key = dir_url，value = true
local cached_dir_items = {}
local current_loaded_url = ""
local sync_playlist_sort = false
local file_loaded_registered = false
local active_playlist_obs_id = nil
local menu_is_open = false       -- 追踪菜单是否已打开，决定用 open-menu 还是 update-menu

-- ================= 排序相关 =================
local sort_mode = opts.default_sort

local month_map = {
    Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6,
    Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12
}

local function natural_compare(a, b)
    local function split(s)
        local t = {}
        for text, num in s:lower():gmatch("(%D*)(%d*)") do
            if text ~= "" then table.insert(t, text) end
            if num  ~= "" then table.insert(t, tonumber(num)) end
        end
        return t
    end
    local ta, tb = split(a), split(b)
    for i = 1, math.max(#ta, #tb) do
        local va, vb = ta[i], tb[i]
        if va == nil then return true end
        if vb == nil then return false end
        if type(va) ~= type(vb) then return tostring(va) < tostring(vb) end
        if va ~= vb then return va < vb end
    end
    return false
end

local function parse_lastmod(s)
    if not s or s == "" then return 0 end
    local day, mon, year, h, m = s:match("(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):")
    if not day then return 0 end
    return (tonumber(year) or 0) * 100000000
         + (month_map[mon] or 0) * 1000000
         + tonumber(day) * 10000
         + tonumber(h) * 100
         + tonumber(m)
end

local function apply_sort()
    table.sort(cached_dir_items, function(a, b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        if sort_mode == "name_desc" then
            return natural_compare(b.name, a.name)
        elseif sort_mode == "time_desc" then
            local ta, tb2 = parse_lastmod(a.lastmod), parse_lastmod(b.lastmod)
            if ta ~= tb2 then return ta > tb2 end
            return natural_compare(a.name, b.name)
        elseif sort_mode == "time_asc" then
            local ta, tb2 = parse_lastmod(a.lastmod), parse_lastmod(b.lastmod)
            if ta ~= tb2 then return ta < tb2 end
            return natural_compare(a.name, b.name)
        else
            return natural_compare(a.name, b.name)
        end
    end)
end

local sort_labels = {
    name_asc  = "名称 A→Z",
    name_desc = "名称 Z→A",
    time_desc = "时间 新→旧",
    time_asc  = "时间 旧→新",
}
-- =============================================

local function format_size(bytes_str)
    local n = tonumber(bytes_str)
    if not n or n == 0 then return "" end
    if n >= 1073741824 then return string.format("%.1f GB", n / 1073741824)
    elseif n >= 1048576 then return string.format("%.1f MB", n / 1048576)
    elseif n >= 1024    then return string.format("%.1f KB", n / 1024)
    else return n .. " B" end
end

-- uosc 分隔线（不可点击的灰色细线条目）
local function separator_item()
    return { title = "─────────────────", selectable = false, muted = true, value = "" }
end

-- ===== 自动挂载字幕（模拟 sub-auto=fuzzy + slang 优先级）=====
local function attach_subs_for(video_play_url)
    local vname = video_play_url:match("([^/?#]+)%??[^/]*$") or ""
    vname = url_decode(vname)
    local vstem = vname:match("^(.+)%.[^%.]+$") or vname
    if vstem == "" then return end

    local matched = {}
    local vstem_lower = vstem:lower()
    for _, item in ipairs(cached_dir_items) do
        if item.is_sub then
            local sstem = (item.name:match("^(.+)%.[^%.]+$") or item.name):lower()
            local start_pos = sstem:find(vstem_lower, 1, true)
            if start_pos then
                local next_char = sstem:sub(start_pos + #vstem_lower, start_pos + #vstem_lower)
                if next_char == "" or not next_char:match("%d") then
                    table.insert(matched, item)
                end
            end
        end
    end

    if #matched == 0 then return end

    table.sort(matched, function(a, b)
        return slang_priority(a.name) < slang_priority(b.name)
    end)

    for i, item in ipairs(matched) do
        local flag = (i == 1) and "select" or "auto"
        mp.commandv("sub-add", item.play_url, flag, item.name)
    end
    
    msg.info(string.format("视频已挂载 %d 条外挂字幕", #matched, vstem))
end

-- ===== 渲染菜单 =====
local function render_menu()
    local path_part = current_loaded_url ~= "" and current_loaded_url:match("https?://[^/]+(/.*)") or nil
    local current_path_decoded = path_part and url_decode(path_part) or "/"

    local items = {}

    -- ---- 顶部功能区 ----
    if is_delete_mode then
        local sel_file_count = 0
        local sel_dir_count  = 0
        for _ in pairs(selected_files) do sel_file_count = sel_file_count + 1 end
        for _ in pairs(selected_dirs)  do sel_dir_count  = sel_dir_count  + 1 end
        local sel_count = sel_file_count + sel_dir_count

        local total_files = 0
        local total_dirs  = 0
        for _, item in ipairs(cached_dir_items) do
            if item.is_dir then total_dirs = total_dirs + 1
            else total_files = total_files + 1 end
        end
        local total_selectable = total_files + total_dirs

        -- 全选 / 全不选切换
        local all_selected = (sel_count == total_selectable) and total_selectable > 0
        table.insert(items, {
            title = all_selected and "☑️ 取消全选" or "⬜ 全选所有项目",
            value = all_selected and "script-message webdav-select-all false"
                                  or "script-message webdav-select-all true",
            keep_open = true
        })

        -- 确认删除
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
                value = "",
                keep_open = true
            })
        end

        -- 退出删除模式
        table.insert(items, {
            title = "❌ 退出删除模式",
            value = "script-message webdav-toggle-mode",
            keep_open = false
        })
    else
        -- 返回上一级
        if current_loaded_url ~= opts.url and current_loaded_url ~= "" then
            local parent_path = current_loaded_url:match("^(.*)/[^/]+/?$")
            if parent_path then
                table.insert(items, {
                    title = "↩️ 返回上一级",
                    value = string.format("script-message webdav-open %q", parent_path .. "/"),
                    keep_open = false
                })
            end
        end

        table.insert(items, {
            title = "🔄 刷新当前目录",
            value = string.format("script-message webdav-open %q %q", current_loaded_url, "true"),  -- [Fix] 两个参数都用 %q
            keep_open = false
        })
        table.insert(items, {
            title = "🗑️ 进入批量删除模式...",
            value = "script-message webdav-toggle-mode",
            keep_open = true
        })
        table.insert(items, {
            title = "📶 排序: " .. (sort_labels[sort_mode] or sort_mode),
            value = "script-message webdav-cycle-sort",
            keep_open = true
        })
    end

    -- ---- 分隔线（功能区 / 文件列表 之间）----
    table.insert(items, separator_item())

    -- ---- 文件 / 文件夹列表 ----
    for _, item in ipairs(cached_dir_items) do
        if item.is_dir then
            if is_delete_mode then
                local checkbox = selected_dirs[item.url] and "☑️" or "⬜"
                table.insert(items, {
                    title = checkbox .. " 📁 " .. item.name,
                    value = string.format("script-message webdav-toggle-dir %q", item.url),
                    keep_open = true
                })
            else
                table.insert(items, {
                    title = "📁 " .. item.name,
                    value = string.format("script-message webdav-open %q", item.url),
                    keep_open = false
                })
            end
        else
            if is_delete_mode then
                local checkbox = selected_files[item.file_url] and "☑️" or "⬜"
                table.insert(items, {
                    title = checkbox .. " " .. item.name,
                    value = string.format("script-message webdav-toggle-file %q", item.file_url),
                    keep_open = true
                })
            else
                local size_hint = item.size and format_size(item.size) or ""
                table.insert(items, {
                    title = item.icon .. " " .. item.name,
                    hint  = size_hint,
                    value = string.format("script-message webdav-play %q %q",
                        item.play_url, tostring(item.is_video or false)),
                    keep_open = false
                })
            end
        end
    end

    local menu = {
        type            = "webdav_browser",
        title           = (is_delete_mode and "【批量删除】 " or "WebDAV: ") .. current_path_decoded,
        items           = items,
        search_style    = "on_demand",
        search_debounce = 300,
    }

    if menu_is_open then
        mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(menu))
    else
        menu_is_open = true
        mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu))
    end
end

-- ===== 获取目录并解析 =====
local function open_webdav_url(target_url, force_refresh)
    if target_url ~= current_loaded_url or force_refresh then
        is_delete_mode = false
        selected_files = {}
        selected_dirs  = {}
        cached_dir_items = {}
        current_loaded_url = target_url
        last_visited_url = target_url

        mp.osd_message("⏳ 正在加载 WebDAV 目录...", 2)

        -- 用 -w 在 body 末尾附加 HTTP 状态码，方便解析
        local args = {
            "curl", "-s",
            "-w", "\n---HTTP_CODE---%{http_code}",
            "-X", "PROPFIND",
            "-u", opts.user .. ":" .. opts.pass,
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

        -- ---- 错误分层判断：先看 curl 自身是否出错 ----
        if res.status ~= 0 then
            local code = res.status
            local hint
            if     code ==  6 then hint = "无法解析主机名，请检查 URL 中的域名/IP"
            elseif code ==  7 then hint = "连接被拒绝，请确认服务正在运行且端口正确"
            elseif code == 28 then hint = "连接超时，请检查网络或防火墙"
            elseif code == 35 or code == 51 or code == 60
                               then hint = "SSL/TLS 握手失败，证书可能有问题"
            elseif code == 67 then hint = "认证失败，请检查用户名和密码"
            else                    hint = string.format("curl 错误码 %d", code) end
            mp.osd_message("❌ " .. hint, 5)
            msg.error("WebDAV curl error " .. code .. ": " .. (res.stderr or ""))
            return
        end

        -- ---- 解析 HTTP 状态码 ----
        local body, http_code_str = res.stdout:match("^(.*)\n---HTTP_CODE---(%d+)$")
        if not body then
            body = res.stdout
            http_code_str = "0"
        end
        local http_code = tonumber(http_code_str) or 0

        if     http_code == 401 then mp.osd_message("❌ 认证失败 (401)，请检查用户名和密码", 5); return
        elseif http_code == 403 then mp.osd_message("❌ 无访问权限 (403)", 4); return
        elseif http_code == 404 then mp.osd_message("❌ 路径不存在 (404)，请检查 WebDAV URL", 4); return
        elseif http_code == 405 then mp.osd_message("❌ 服务器不支持 PROPFIND (405)，请确认 WebDAV 服务已启用", 4); return
        elseif http_code >= 500 then mp.osd_message(string.format("❌ 服务器内部错误 (%d)", http_code), 4); return
        elseif http_code ~= 207 then mp.osd_message(string.format("❌ 意外的 HTTP 响应码 %d", http_code), 4); return
        end

        -- ---- 解析 PROPFIND XML ----
        local current_path_decoded = url_decode(target_url:match("https?://[^/]+(/.*)") or "/")
        local norm_current = current_path_decoded:gsub("/$", "")

        for block in body:gmatch("<[Dd]:[Rr]esponse>(.-)</[Dd]:[Rr]esponse>") do
            local raw_href = block:match("<[Dd]:[Hh]ref>([^<]+)</[Dd]:[Hh]ref>")
            if not raw_href then goto continue end

            local lastmod_str = block:match("<[Dd]:[Gg]etlastmodified>([^<]+)</[Dd]:[Gg]etlastmodified>") or ""
            local size_str    = block:match("<[Dd]:[Gg]etcontentlength>([^<]+)</[Dd]:[Gg]etcontentlength>") or ""

            if raw_href:match("^https?://") then raw_href = raw_href:match("https?://[^/]+(/.*)") end
            local decoded_href = url_decode(raw_href)
            local norm_decoded = decoded_href:gsub("/$", "")

            if norm_decoded ~= norm_current then
                local is_dir = raw_href:sub(-1) == "/"
                local name   = decoded_href:match("([^/]+)/?$") or decoded_href

                if is_dir then
                    table.insert(cached_dir_items, {
                        is_dir  = true,
                        name    = name,
                        url     = protocol .. domain .. raw_href,
                        lastmod = lastmod_str
                    })
                else
                    local ext       = name:match("%.([^%.]+)$")
                    local ext_lower = ext and ext:lower()
                    local is_video  = ext_lower and video_exts[ext_lower]
                    local is_sub    = ext_lower and sub_exts[ext_lower]
                    local icon      = is_video and "🎬" or "📄"
                    table.insert(cached_dir_items, {
                        is_dir   = false,
                        name     = name,
                        play_url = auth_prefix .. raw_href,
                        file_url = protocol .. domain .. raw_href,
                        lastmod  = lastmod_str,
                        size     = size_str,
                        is_video = is_video,
                        is_sub   = is_sub,
                        icon     = icon
                    })
                end
            end
            ::continue::
        end

        apply_sort()
    end

    -- 切换目录时必须重新 open-menu（新的 type/title），重置标志
    menu_is_open = false
    render_menu()
end

-- ================= 消息处理 =================

-- 开关删除模式
mp.register_script_message("webdav-toggle-mode", function()
    if current_loaded_url == "" then
        mp.osd_message("⚠️ 请先打开 WebDAV 目录", 2)
        return
    end
    is_delete_mode = not is_delete_mode
    selected_files = {}
    selected_dirs  = {}
    if not is_delete_mode then
        menu_is_open = false
    end
    render_menu()
end)

-- 切换文件选中状态
mp.register_script_message("webdav-toggle-file", function(file_url)
    if selected_files[file_url] then selected_files[file_url] = nil
    else selected_files[file_url] = true end
    render_menu()
end)

-- 切换文件夹选中状态
mp.register_script_message("webdav-toggle-dir", function(dir_url)
    if selected_dirs[dir_url] then selected_dirs[dir_url] = nil
    else selected_dirs[dir_url] = true end
    render_menu()
end)

-- 全选 / 全不选
mp.register_script_message("webdav-select-all", function(select_all_str)
    local select_all = (select_all_str == "true")
    selected_files = {}
    selected_dirs  = {}
    if select_all then
        for _, item in ipairs(cached_dir_items) do
            if item.is_dir then selected_dirs[item.url] = true
            else selected_files[item.file_url] = true end
        end
    end
    render_menu()
end)

-- WebDAV DELETE 单次请求（文件夹加 Depth: infinity）
local function webdav_delete(url, is_dir)
    local args = {
        "curl", "-s", "-o", "/dev/null",
        "-w", "%{http_code}",
        "-X", "DELETE",
        "-u", opts.user .. ":" .. opts.pass,
    }
    if is_dir then
        -- RFC 4918：删除集合（文件夹）必须带 Depth: infinity
        table.insert(args, "-H")
        table.insert(args, "Depth: infinity")
    end
    table.insert(args, url)

    local res = mp.command_native({
        name = "subprocess", playback_only = false,
        capture_stdout = true, args = args
    })
    local code = tonumber((res.stdout or ""):match("^%s*(%d+)%s*$")) or 0
    return code == 200 or code == 204 or code == 207
end

-- 执行批量删除
mp.register_script_message("webdav-execute-delete", function()
    local sel_count = 0
    for _ in pairs(selected_files) do sel_count = sel_count + 1 end
    for _ in pairs(selected_dirs)  do sel_count = sel_count + 1 end
    if sel_count == 0 then return end

    mp.osd_message(string.format("正在删除 %d 个项目...", sel_count), 3)

    local success_count = 0

    for file_url in pairs(selected_files) do
        msg.info("DELETE file: " .. file_url)
        if webdav_delete(file_url, false) then success_count = success_count + 1
        else msg.warn("删除文件失败: " .. file_url) end
    end

    for dir_url in pairs(selected_dirs) do
        msg.info("DELETE dir: " .. dir_url)
        if webdav_delete(dir_url, true) then success_count = success_count + 1
        else msg.warn("删除文件夹失败: " .. dir_url) end
    end

    mp.osd_message(string.format("删除完毕，成功 %d/%d", success_count, sel_count), 3)

    is_delete_mode = false
    selected_files = {}
    selected_dirs  = {}
    open_webdav_url(current_loaded_url, true)
end)

-- 打开目录
mp.register_script_message("webdav-open", function(url, force)
    open_webdav_url(url, force == "true")
end)

-- 循环切换排序
mp.register_script_message("webdav-cycle-sort", function()
    local modes = {"time_asc", "time_desc", "name_desc", "name_asc"}
    for i, m in ipairs(modes) do
        if m == sort_mode then
            sort_mode = modes[(i % #modes) + 1]
            break
        end
    end
    apply_sort()
    render_menu()
end)

-- 播放文件并生成全目录连播列表
mp.register_script_message("webdav-play", function(play_url, is_video)
    if opts.video_only and is_video == "false" then
        mp.osd_message("⚠️ 此文件不是视频，无法播放", 2)
        return
    end

    local file_items = {}
    for _, item in ipairs(cached_dir_items) do
        if not item.is_dir and (not opts.video_only or item.is_video) then
            table.insert(file_items, item)
        end
    end

    if not sync_playlist_sort then
        table.sort(file_items, function(a, b) return natural_compare(a.name, b.name) end)
    end

    if #file_items == 0 then return end

    local target_pos = 0
    for i, item in ipairs(file_items) do
        if item.play_url == play_url then target_pos = i - 1; break end
    end

    if active_playlist_obs_id then
        mp.unobserve_property(active_playlist_obs_id)
        active_playlist_obs_id = nil
    end

    mp.commandv("loadfile", file_items[1].play_url, "replace")
    for i = 2, #file_items do
        mp.commandv("loadfile", file_items[i].play_url, "append")
    end

    if target_pos > 0 then
        local expected = #file_items
        local obs_id
        local registered = false
        obs_id = mp.observe_property("playlist-count", "number", function(_, count)
			if not registered then return end             
			if count and count >= expected then
				mp.unobserve_property(obs_id)
				active_playlist_obs_id = nil
				mp.commandv("playlist-play-index", target_pos)
			end
		end)
		registered = true                                 
		active_playlist_obs_id = obs_id
    end

    local mode_hint = sync_playlist_sort
        and ("继承 WebDAV 目录排序: " .. sort_labels[sort_mode]) or "名称 A→Z"
    local file_label = opts.video_only and "个视频" or "个文件"
    mp.osd_message("🎬 播放列表共 " .. #file_items .. " " .. file_label .. " [" .. mode_hint .. "]", 3)

    if not file_loaded_registered then
        mp.register_event("file-loaded", function()
            local path = mp.get_property("path") or ""
            if not path:find(domain, 1, true) then return end

            attach_subs_for(path)

            mp.add_timeout(0.3, function()
                local track_count = mp.get_property_number("track-list/count") or 0
                local best_sid = nil
                local best_priority = math.huge

                for i = 0, track_count - 1 do
                    local t_type = mp.get_property(string.format("track-list/%d/type", i))
                    if t_type == "sub" then
                        local selected = mp.get_property(string.format("track-list/%d/selected", i))
                        if selected == "yes" then best_sid = nil; break end
                        local lang  = mp.get_property(string.format("track-list/%d/lang", i)) or ""
                        local title = mp.get_property(string.format("track-list/%d/title", i)) or ""
                        local candidate = (lang .. " " .. title):lower()
                        for j, tag in ipairs(slang) do
                            if candidate:find(tag, 1, true) and j < best_priority then
                                best_priority = j
                                best_sid = mp.get_property_number(string.format("track-list/%d/id", i))
                            end
                        end
                    end
                end

                if best_sid then
                    mp.set_property_number("sid", best_sid)
                    msg.info(string.format("内封字幕已选轨 sid=%d", best_sid))
                end
            end)
        end)
        file_loaded_registered = true
    end
end)

-- 切换连播列表是否继承目录排序
mp.register_script_message("webdav-toggle-sync-sort", function()
    sync_playlist_sort = not sync_playlist_sort
    local state = sync_playlist_sort
        and ("开 (继承 WebDAV 目录排序: " .. sort_labels[sort_mode] .. ")") or "关 (名称 A→Z)"
    mp.osd_message("🎬 播放列表排序继承: " .. state, 2)
end)

mp.register_script_message("open-webdav", function()
    open_webdav_url(last_visited_url, false)
end)

mp.register_script_message("webdav-toggle-video-only", function()
    opts.video_only = not opts.video_only
    local state = opts.video_only and "开 (仅视频)" or "关 (全部文件)"
    mp.osd_message("🎬 仅播放视频: " .. state, 2)
end)
