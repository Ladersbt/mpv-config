-- modules/subtitle.lua — 字幕匹配与自动挂载
-- 支持同目录平级字幕 + 子文件夹扫描（sub, subs, subtitle, subtitles, 字幕, 外挂字幕 等）

local msg = require 'mp.msg'
local options = require "modules.options"
local utils = require "modules.utils"

local M = {}

local state = nil

function M.init(s)
    state = s
end

-- ======== 平级字幕匹配（来自 cached_dir_items） ========

--- 从 state.cached_dir_items 中选出与视频同名的字幕文件。
--- 返回按 slang 优先级排序的 item 列表。
local function match_sidecar_subs(video_name)
    local vstem = video_name:match("^(.+)%.[^%.]+$") or video_name
    if vstem == "" then return {} end

    local matched = {}
    local vstem_lower = vstem:lower()
    for _, item in ipairs(state.cached_dir_items) do
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
    return matched
end

local function sort_by_slang(items)
    table.sort(items, function(a, b)
        return utils.slang_priority(a.name, options.slang) < utils.slang_priority(b.name, options.slang)
    end)
end

local function mount_subs(items)
    for i, item in ipairs(items) do
        local flag = (i == 1) and "select" or "auto"
        mp.commandv("sub-add", item.play_url, flag, item.name)
    end
    if #items > 0 then
        msg.info(string.format("视频已挂载 %d 条外挂字幕", #items))
    end
end

-- ======== 字幕文件夹扫描（通过 curl PROPFIND，异步） ========

--- 解析 PROPFIND 响应，返回字幕文件列表（同步纯解析，不发请求）。
--- @param ok boolean command_native_async 回调的 ok
--- @param res table|nil subprocess 结果
--- @param folder_url string 字幕文件夹的完整 WebDAV URL
--- @return table { name, play_url, file_url }[]
local function parse_sub_props(ok, res, folder_url)
    if not ok or not res or res.status ~= 0 then return {} end

    local body, http_code_str = res.stdout:match("^(.*)\n---HTTP_CODE---(%d+)$")
    if not body then
        body = res.stdout
        http_code_str = "0"
    end
    local http_code = tonumber(http_code_str) or 0
    if http_code ~= 207 then return {} end

    local folder_path_decoded = utils.url_decode(folder_url:match("https?://[^/]+(/.*)") or "/")
    local norm_folder = folder_path_decoded:gsub("/$", "")

    local subs = {}
    for block in body:gmatch("<[Dd]:[Rr]esponse>(.-)</[Dd]:[Rr]esponse>") do
        local raw_href = block:match("<[Dd]:[Hh]ref>([^<]+)</[Dd]:[Hh]ref>")
        if not raw_href then goto continue end

        if raw_href:match("^https?://") then
            raw_href = raw_href:match("https?://[^/]+(/.*)")
        end

        -- 解码 XML 实体（&amp; → & 等），与 browse.lua 保持一致
        raw_href = utils.xml_decode(raw_href)
        local decoded_href = utils.url_decode(raw_href)
        local norm_decoded = decoded_href:gsub("/$", "")

        -- 跳过文件夹自身
        if norm_decoded == norm_folder then goto continue end
        -- 跳过子文件夹（只取平级文件）
        if raw_href:sub(-1) == "/" then goto continue end

        local name = decoded_href:match("([^/]+)$") or ""
        local ext = name:match("%.([^%.]+)$")
        if ext and options.sub_exts[ext:lower()] then
            table.insert(subs, {
                name     = name,
                play_url = options.auth_prefix .. raw_href,
                file_url = options.protocol .. options.domain .. raw_href,
            })
        end

        ::continue::
    end

    return subs
end

--- 异步扫描单个字幕文件夹，完成后 callback(subs)。
--- 不阻塞 file-loaded：视频先播，字幕扫描结果晚到再挂载。
local function scan_sub_folder_async(folder_url, callback)
    local args = {
        "curl", "-s",
        "--connect-timeout", "5",
        "-w", "\n---HTTP_CODE---%{http_code}",
        "-X", "PROPFIND",
        "-u", options.opts.user .. ":" .. options.opts.pass,
        "-H", "Depth: 1",
        "--max-time", "10",
        folder_url
    }

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    }, function(ok, res)
        callback(parse_sub_props(ok, res, folder_url))
    end)
end

--- 挂载前确认播放的仍是发起扫描时的那个文件：
--- 异步扫描期间用户可能已切集，迟到的结果挂到新文件上会张冠李戴。
local function mount_if_still_current(video_play_url, items)
    if (mp.get_property("path") or "") ~= video_play_url then
        msg.verbose("字幕扫描回调到达时已换文件，丢弃")
        return
    end
    mount_subs(items)
end

--- 在当前目录的 cached_dir_items 中查找字幕文件夹，并行扫描，全部返回后挂载。
--- @param video_name string 视频文件名（含扩展名）
--- @param video_play_url string 发起时的视频 play_url，用于换集守卫
function M.attach_subs_from_folders(video_name, video_play_url)
    local vstem = video_name:match("^(.+)%.[^%.]+$") or video_name
    if vstem == "" then return end
    local vstem_lower = vstem:lower()

    local folders = {}
    for _, item in ipairs(state.cached_dir_items) do
        if item.is_dir then
            local dir_lower = item.name:lower()
            for _, dir_name in ipairs(options.sub_dir_names) do
                if dir_lower == dir_name then
                    table.insert(folders, item)
                    break
                end
            end
        end
    end
    if #folders == 0 then return end

    -- 并行发起所有字幕文件夹的 PROPFIND，计数器等全部返回再统一排序挂载
    local matched_subs = {}
    local pending = #folders
    local any_scanned = false

    for _, folder in ipairs(folders) do
        scan_sub_folder_async(folder.url, function(subs)
            if #subs > 0 then any_scanned = true end
            for _, sub in ipairs(subs) do
                local sstem = (sub.name:match("^(.+)%.[^%.]+$") or sub.name):lower()
                local start_pos = sstem:find(vstem_lower, 1, true)
                if start_pos then
                    local next_char = sstem:sub(start_pos + #vstem_lower, start_pos + #vstem_lower)
                    if next_char == "" or not next_char:match("%d") then
                        table.insert(matched_subs, sub)
                    end
                end
            end

            pending = pending - 1
            if pending == 0 then
                if #matched_subs == 0 then
                    if any_scanned then
                        msg.verbose("字幕文件夹存在但未找到匹配视频的字幕文件")
                    end
                    return
                end
                sort_by_slang(matched_subs)
                mount_if_still_current(video_play_url, matched_subs)
            end
        end)
    end
end

-- ======== 统一入口 ========

--- 从平级文件和字幕文件夹中自动挂载外挂字幕。
--- @param video_play_url string 视频的 play_url（含 auth_prefix）
function M.attach_subs_for(video_play_url)
    local vname = video_play_url:match("([^/?#]+)%??[^/]*$") or ""
    vname = utils.url_decode(vname)
    if vname == "" then return end

    -- 1) 平级字幕
    local sidecar = match_sidecar_subs(vname)
    if #sidecar > 0 then
        sort_by_slang(sidecar)
        mount_if_still_current(video_play_url, sidecar)
        -- 有平级字幕时不扫描文件夹（平级优先级更高）
        return
    end

    -- 2) 平级无匹配，尝试字幕文件夹
    M.attach_subs_from_folders(vname, video_play_url)
end

return M