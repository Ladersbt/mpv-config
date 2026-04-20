-- uosc_webdav.lua
-- 主要借助claude编写，参考和修改自 https://gist.github.com/HedioKojima/fdbfdd73570650b01c809afb5ae7829b 🙏🏻

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

-- ============================================


-- slang 优先级顺序，靠前的优先 select
local slang = {"jpsc","chs","sc","zh-hans","zh-cn","jptc","cht","tc","zh-hant","zh-hk","zh-tw","chi","zho","zh"}
local function slang_priority(name)
    local lower = name:lower()
    for i, tag in ipairs(slang) do
        if lower:find(tag, 1, true) then return i end
    end
    return #slang + 1
end

local last_visited_url = opts.url
local protocol, domain = opts.url:match("^(https?://)([^/]+)")
if not protocol or not domain then
    msg.error("WebDAV URL 配置无效: " .. tostring(opts.url))
    return
end
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
local delete_job = {
    active  = false,
    total   = 0,
    done    = 0,
    success = 0,
    fail    = 0,
    queue   = nil,
}
local dir_cache  = {}           -- url -> { items }
local dir_cursor = {}           -- url -> child_url (上次进入的子目录URL)   -- [CHANGE] 从行号改为子目录URL
local dir_sort   = {}           -- url -> sort_mode (每个目录独立排序)      -- [CHANGE] 新增，替代全局sort_mode

-- ================= 排序相关 =================

-- [CHANGE] 删除全局 sort_mode，改用 dir_sort[current_loaded_url]，通过helper读写
local function get_sort_mode()
    return dir_sort[current_loaded_url] or opts.default_sort
end
local function set_sort_mode(m)
    dir_sort[current_loaded_url] = m
end

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

local function copy_items(src)
    local dst = {}
    for i, item in ipairs(src or {}) do
        dst[i] = item
    end
    return dst
end

local function apply_sort()
    local m = get_sort_mode()  -- [CHANGE] 用当前目录自己的排序
    table.sort(cached_dir_items, function(a, b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        if m == "name_desc" then
            return natural_compare(b.name, a.name)
        elseif m == "time_desc" then
            local ta, tb2 = parse_lastmod(a.lastmod), parse_lastmod(b.lastmod)
            if ta ~= tb2 then return ta > tb2 end
            return natural_compare(a.name, b.name)
        elseif m == "time_asc" then
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

-- uosc 列表分隔
local function separator_item()
    return { title = "文件列表", hint = "排序：" .. (sort_labels[get_sort_mode()] or get_sort_mode()), selectable = false, muted = false }
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
    msg.info(string.format("视频已挂载 %d 条外挂字幕", #matched))
end

-- ===== 渲染菜单 =====
local function render_menu()
    local path_part = current_loaded_url ~= "" and current_loaded_url:match("https?://[^/]+(/.*)") or nil
    local current_path_decoded = path_part and url_decode(path_part) or "/"
    
    -- 提前统计，供顶部功能区和 footnote 共用
    local sel_file_count = 0
    local sel_dir_count  = 0
    for _ in pairs(selected_files) do sel_file_count = sel_file_count + 1 end
    for _ in pairs(selected_dirs)  do sel_dir_count  = sel_dir_count  + 1 end
    local sel_count      = sel_file_count + sel_dir_count

    local video_count       = 0
    local total_selectable  = #cached_dir_items
    for _, item in ipairs(cached_dir_items) do
        if not item.is_dir and item.is_video then video_count = video_count + 1 end
    end

    local items = {}

    -- ---- 顶部功能区 ----
    if is_delete_mode then
    
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
                selectable = false
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
                    value = string.format("script-message webdav-go-back %q", parent_path .. "/"),
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
			title = "📶 切换排序",
			items = {
				{
					title  = sort_labels["time_desc"],
					hint   = get_sort_mode() == "time_desc" and "☑️" or "⬜",
					value  = "script-message webdav-set-sort time_desc",
					active = get_sort_mode() == "time_desc" and 1 or nil,
					keep_open = false,
				},
				{
					title  = sort_labels["time_asc"],
					hint   = get_sort_mode() == "time_asc" and "☑️" or "⬜",
					value  = "script-message webdav-set-sort time_asc",
					active = get_sort_mode() == "time_asc" and 1 or nil,
					keep_open = false,
				},
				{
					title  = sort_labels["name_asc"],
					hint   = get_sort_mode() == "name_asc" and "☑️" or "⬜",
					value  = "script-message webdav-set-sort name_asc",
					active = get_sort_mode() == "name_asc" and 1 or nil,
					keep_open = false,
				},
				{
					title  = sort_labels["name_desc"],
					hint   = get_sort_mode() == "name_desc" and "☑️" or "⬜",
					value  = "script-message webdav-set-sort name_desc",
					active = get_sort_mode() == "name_desc" and 1 or nil,
					keep_open = false,
				},
			},
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
                    value = string.format("script-message webdav-open %q %q %q",
                        item.url, "false", item.url),  -- [CHANGE] 第3参数改传子目录URL
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
    
    -- 空目录提示
    if #cached_dir_items == 0 then
        table.insert(items, {
            title = "📂 空目录",
            selectable = false,
            muted = true,
            value = ""
        })
    end

    -- [CHANGE] selected_index：从dir_cursor取上次进入的子目录URL，动态找它在菜单里的行号
    local selected_index = 1
    local cursor_child_url = dir_cursor[current_loaded_url]
    if cursor_child_url then
        for idx, it in ipairs(items) do
            -- 找到value里包含该子目录URL的那一行（文件夹条目）
            if it.value and it.value:find(cursor_child_url, 1, true) then
                selected_index = idx
                break
            end
        end
    end

    local menu = {
        type            = "webdav_browser",
        title           = (is_delete_mode and "【批量删除】 " or "WebDAV: ") .. current_path_decoded,
        items           = items,
        selected_index  = selected_index,  -- [CHANGE]
        search_style    = "on_demand",
        search_debounce = 300,
    }

    if is_delete_mode then
        menu.footnote = string.format("已选择 %d 个项目", sel_count)
    else
        -- [CHANGE] footnote 分类显示，0项不显示，全空则提示空目录
		local dir_count   = 0
		local other_count = 0
		for _, item in ipairs(cached_dir_items) do
			if item.is_dir then
				dir_count = dir_count + 1
			elseif not item.is_video then
				other_count = other_count + 1
			end
		end
		local parts = {}
		if dir_count   > 0 then table.insert(parts, string.format("📁 %d 个文件夹", dir_count))  end
		if video_count > 0 then table.insert(parts, string.format("🎬 %d 个视频",   video_count)) end
		if other_count > 0 then table.insert(parts, string.format("📄 %d 个其他文件",   other_count)) end
		menu.footnote = #parts > 0 and table.concat(parts, "　") or "📂 空目录"
    end
    
    -- 菜单已打开时用 update-menu 原地刷新（无闪烁），首次用 open-menu
    local menu_json = utils.format_json(menu)

    if menu_is_open then
        mp.commandv("script-message-to", "uosc", "update-menu", menu_json)
    else
        mp.commandv("script-message-to", "uosc", "open-menu", menu_json)
        menu_is_open = true
    end    
end

-- ===== 获取目录并解析 =====
local function open_webdav_url(target_url, force_refresh)
    local prev_url = current_loaded_url
    local prev_items = cached_dir_items
    local prev_delete_mode = is_delete_mode
    local prev_selected_files = selected_files
    local prev_selected_dirs = selected_dirs

    local function restore_prev()
        current_loaded_url = prev_url
        if prev_url ~= "" then
			last_visited_url = prev_url
		end
        cached_dir_items = prev_items
        is_delete_mode = prev_delete_mode
        selected_files = prev_selected_files
        selected_dirs = prev_selected_dirs
        menu_is_open = false
        render_menu()
    end

    -- 直接命中缓存
    if not force_refresh and dir_cache[target_url] then
        cached_dir_items = copy_items(dir_cache[target_url].items)
        current_loaded_url = target_url
        last_visited_url = target_url
        is_delete_mode = false
        selected_files = {}
        selected_dirs = {}
        menu_is_open = false
        apply_sort()
        render_menu()
        return
    end

    mp.osd_message("⏳ 正在加载 WebDAV 目录...", 2)

    -- 先把解析结果放到临时表里，成功后再写回全局
    local new_items = {}

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

    -- curl 自身错误
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

    -- 解析 HTTP 状态码
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

    -- 解析 PROPFIND XML
    local current_path_decoded = url_decode(target_url:match("https?://[^/]+(/.*)") or "/")
    local norm_current = current_path_decoded:gsub("/$", "")

    for block in body:gmatch("<[Dd]:[Rr]esponse>(.-)</[Dd]:[Rr]esponse>") do
        local raw_href = block:match("<[Dd]:[Hh]ref>([^<]+)</[Dd]:[Hh]ref>")
        if not raw_href then goto continue end

        local lastmod_str = block:match("<[Dd]:[Gg]etlastmodified>([^<]+)</[Dd]:[Gg]etlastmodified>") or ""
        local size_str    = block:match("<[Dd]:[Gg]etcontentlength>([^<]+)</[Dd]:[Gg]etcontentlength>") or ""

        if raw_href:match("^https?://") then
            raw_href = raw_href:match("https?://[^/]+(/.*)")
        end

        local decoded_href = url_decode(raw_href)
        local norm_decoded = decoded_href:gsub("/$", "")

        if norm_decoded ~= norm_current then
            local is_dir = raw_href:sub(-1) == "/"
            local name   = decoded_href:match("([^/]+)/?$") or decoded_href

            if is_dir then
                table.insert(new_items, {
                    is_dir  = true,
                    name    = name,
                    url     = protocol .. domain .. raw_href,
                    lastmod = lastmod_str
                })
            else
                local ext        = name:match("%.([^%.]+)$")
                local ext_lower   = ext and ext:lower()
                local is_video    = ext_lower and video_exts[ext_lower]
                local is_sub      = ext_lower and sub_exts[ext_lower]
                local icon        = is_video and "🎬" or "📄"

                table.insert(new_items, {
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

    -- 成功后一次性写回
    is_delete_mode = false
    selected_files = {}
    selected_dirs  = {}
    cached_dir_items = new_items
    current_loaded_url = target_url
    last_visited_url = target_url

    -- 缓存存“原始顺序”，别存已经排序过的结果
    dir_cache[target_url] = { items = copy_items(new_items) }
    dir_cursor[target_url] = nil
    apply_sort()
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
        menu_is_open = false  -- 退出删除模式时菜单已被关闭，强制重新 open-menu
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
local function webdav_delete_async(url, is_dir, cb)
    local args = {
        "curl", "-s", "-o", "/dev/null",
        "-w", "%{http_code}",
        "-X", "DELETE",
        "-u", opts.user .. ":" .. opts.pass,
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

-- 执行批量删除
mp.register_script_message("webdav-execute-delete", function()
    if delete_job.active then return end

    local delete_list = {}
    for _, item in ipairs(cached_dir_items) do
        if item.is_dir and selected_dirs[item.url] then
            table.insert(delete_list, { name = item.name, url = item.url, is_dir = true })
        elseif not item.is_dir and selected_files[item.file_url] then
            table.insert(delete_list, { name = item.name, url = item.file_url, is_dir = false })
        end
    end

    if #delete_list == 0 then
        mp.osd_message("⚠️ 没有选中任何项目", 2)
        return
    end

    delete_job.active  = true
    delete_job.total   = #delete_list
    delete_job.done    = 0
    delete_job.success = 0
    delete_job.fail    = 0
    delete_job.queue   = delete_list

    is_delete_mode = false
    selected_files = {}
    selected_dirs  = {}
    mp.commandv("script-message-to", "uosc", "close-menu", "webdav_browser")
    menu_is_open = false

    mp.osd_message(string.format("🗑️ 开始删除 %d 个项目...", delete_job.total), 2)

    local function delete_next()
        if not delete_job.active then return end

        local item = table.remove(delete_job.queue, 1)
        if not item then
            -- 全部完成
            local msg_str = string.format("✅ 删除完成：成功 %d，失败 %d",
                delete_job.success, delete_job.fail)
            mp.osd_message(msg_str, 4)
            msg.info(msg_str)
            delete_job.active = false
            dir_cache[current_loaded_url] = nil
            open_webdav_url(current_loaded_url, true)
            return
        end

        delete_job.done = delete_job.done + 1
        mp.osd_message(string.format("🗑️ 删除中 %d/%d：%s",
            delete_job.done, delete_job.total, item.name), 2)
        msg.info(string.format("DELETE %s: %s",
            item.is_dir and "dir" or "file", item.url))

        webdav_delete_async(item.url, item.is_dir, function(ok)
            if ok then
                delete_job.success = delete_job.success + 1
                msg.info("删除成功: " .. item.url)
            else
                delete_job.fail = delete_job.fail + 1
                msg.warn("删除失败: " .. item.url)
            end
            delete_next()
        end)
    end

    delete_next()
end)

-- 打开目录
mp.register_script_message("webdav-open", function(url, force, child_url)
    -- [CHANGE] child_url 现在是子目录的URL字符串，记录"从当前目录进入了哪个子目录"
    if child_url and child_url ~= "" and current_loaded_url ~= "" then
        dir_cursor[current_loaded_url] = child_url
    end
    -- [CHANGE] 返回根目录时清空所有光标记录
--    if url == opts.url then
--        dir_cursor = {}
--    end
    open_webdav_url(url, force == "true")
end)

mp.register_script_message("webdav-go-back", function(url)
    dir_cursor[current_loaded_url] = nil
    open_webdav_url(url, false)
end)

-- 循环切换排序
mp.register_script_message("webdav-cycle-sort", function()
    local modes = {"time_asc", "time_desc", "name_desc", "name_asc"}
    local cur = get_sort_mode()  -- [CHANGE] 读当前目录排序
    for i, m in ipairs(modes) do
        if m == cur then
            set_sort_mode(modes[(i % #modes) + 1])  -- [CHANGE] 只写当前目录
            break
        end
    end
    dir_cursor[current_loaded_url] = nil
    apply_sort()
    render_menu()
end)

mp.register_script_message("webdav-set-sort", function(mode)
    set_sort_mode(mode)
    dir_cursor[current_loaded_url] = nil
    apply_sort()
    menu_is_open = false  -- 子菜单关闭后重新 open
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
        and ("继承 WebDAV 目录排序: " .. sort_labels[get_sort_mode()]) or "名称 A→Z"  -- [CHANGE]
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
        and ("开 (继承 WebDAV 目录排序: " .. sort_labels[get_sort_mode()] .. ")") or "关 (名称 A→Z)"  -- [CHANGE]
    mp.osd_message("🎬 播放列表排序继承: " .. state, 2)
end)

mp.register_script_message("webdav-toggle-video-only", function()
    opts.video_only = not opts.video_only
    local state = opts.video_only and "开 (仅视频)" or "关 (全部文件)"
    mp.osd_message("🎬 仅播放视频: " .. state, 2)
end)

mp.register_script_message("open-webdav", function()
    open_webdav_url(last_visited_url, false)
end)

mp.register_script_message("open-webdav-root", function()
    if current_loaded_url == opts.url then
        mp.osd_message("📂 已在根目录", 1)
        return
    end
    dir_cursor = {}
    open_webdav_url(opts.url, false)
end)

-- 返回上一级，可绑定快捷键
mp.register_script_message("webdav-back", function()
    if current_loaded_url == "" or current_loaded_url == opts.url then return end
    local parent_path = current_loaded_url:match("^(.*)/[^/]+/?$")
    if parent_path then
        dir_cursor[current_loaded_url] = nil
        open_webdav_url(parent_path .. "/", false)
    end
end)
