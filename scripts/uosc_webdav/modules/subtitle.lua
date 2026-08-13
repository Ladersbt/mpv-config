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

-- ======== 字幕文件夹扫描（通过 curl PROPFIND） ========

--- 扫描单个字幕文件夹，返回其中字幕文件列表。
--- @param folder_url string 字幕文件夹的完整 WebDAV URL
--- @return table { name, play_url, file_url }[]
local function scan_sub_folder(folder_url)
    local args = {
        "curl", "-s",
        "-w", "\n---HTTP_CODE---%{http_code}",
        "-X", "PROPFIND",
        "-u", options.opts.user .. ":" .. options.opts.pass,
        "-H", "Depth: 1",
        "--max-time", "10",
        folder_url
    }

    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    })

    if res.status ~= 0 then return {} end

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

--- 在当前目录的 cached_dir_items 中查找字幕文件夹，逐个扫描并挂载。
--- @param video_name string 视频文件名（含扩展名）
function M.attach_subs_from_folders(video_name)
    local vstem = video_name:match("^(.+)%.[^%.]+$") or video_name
    if vstem == "" then return end
    local vstem_lower = vstem:lower()

    local matched_subs = {}
    local folder_scanned = false

    for _, item in ipairs(state.cached_dir_items) do
        if item.is_dir then
            -- 检查文件夹名是否在 sub_dir_names 中
            local dir_lower = item.name:lower()
            local is_sub_folder = false
            for _, dir_name in ipairs(options.sub_dir_names) do
                if dir_lower == dir_name then
                    is_sub_folder = true
                    break
                end
            end
            if not is_sub_folder then goto continue end

            -- 已找到字幕文件夹，扫描
            local subs = scan_sub_folder(item.url)
            folder_scanned = true
            if #subs == 0 then goto continue end

            -- 过滤出与视频同名的字幕文件
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
        end
        ::continue::
    end

    if #matched_subs == 0 then
        if folder_scanned then
            msg.verbose("字幕文件夹存在但未找到匹配视频的字幕文件")
        end
        return
    end

    sort_by_slang(matched_subs)
    mount_subs(matched_subs)
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
        mount_subs(sidecar)
        -- 有平级字幕时不扫描文件夹（平级优先级更高）
        return
    end

    -- 2) 平级无匹配，尝试字幕文件夹
    M.attach_subs_from_folders(vname)
end

return M