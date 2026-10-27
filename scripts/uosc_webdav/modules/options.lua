-- modules/options.lua — 配置与常量

local opt = require 'mp.options'

local M = {}

-- 用户配置
M.opts = {
    url = "http://192.168.1.100:8080/dav/",
    user = "admin",
    pass = "password",
    default_sort = "name_asc",
    video_only = true,
    -- 多服务器（servers.json 的读取归一化见 modules/servers.lua）：
    -- persist_changes：菜单更改是否写盘（read_options 只认 yes/no，写错静默回落默认值）。
    --   可在服务器列表菜单勾选「💾 改动持久化」切换；开关自身状态始终写盘、不受门控
    --   （main.lua webdav-toggle-persist，防门控自锁）。默认 yes。
    -- default_server：默认直入的服务器 name（留空 = 多服务器时先显示列表；单服务器恒直入）
    persist_changes = true,
    default_server = "",
}

opt.read_options(M.opts, "uosc_webdav")

-- 字幕文件夹名称（供 M.attach_subs_from_folders 识别）
M.sub_dir_names = {
    "sub", "subs", "subtitle", "subtitles",
    "字幕", "外挂字幕", "外挂",
    "sc", "tc", "jpsc", "jptc", "chs", "cht",
}

-- 扩展名常量
M.video_exts = {
    mp4 = true, mkv = true, avi = true, mov = true, wmv = true,
    flv = true, webm = true, m2ts = true, ts = true, rmvb = true,
    m4v = true, iso = true, vob = true,
}

M.audio_exts = {
    mp3 = true, flac = true, aac = true, ogg = true, opus = true,
    wav = true, m4a = true, ape = true, wma = true, alac = true,
    mka = true, dts = true, ac3 = true,
}

M.sub_exts = {
    srt = true, ass = true, ssa = true, vtt = true, txt = true,
    sup = true, sub = true, idx = true, smi = true, lrc = true,
}

-- 字幕语言优先级
M.slang = {
    "jpsc", "jptc", "chs&jap", "sc&jap", "cht&jap", "ch&jap", "tc&jap", "zh&jap",
    "中日", "简日", "繁日", "双语", "雙語",
    "chs&eng", "sc&eng", "cht&eng", "ch&eng", "tc&eng", "zh&eng",
    "中英", "中上英下", "简英", "简体&英文", "繁英", "繁体&英文", "繁體&英文",
    "特效", "chs", "sc", "zh-hans", "zh-cn", "简体中文",
    "cht", "tc", "zh-hant", "zh-hk", "zh-tw", "繁体中文", "繁體中文",
    "chi", "zho", "zh",
    "中", "简", "繁", "simplified", "traditional",
}

-- 排序标签（给用户看）
M.sort_labels = {
    name_asc  = "名称 A→Z",
    name_desc = "名称 Z→A",
    time_desc = "时间 新→旧",
    time_asc  = "时间 旧→新",
    size_desc = "大小 大→小",
    size_asc  = "大小 小→大",
}

-- 月份映射
M.month_map = {
    Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6,
    Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12
}

--- 按服务器表求派生量（协议/主机/凭据前缀）。
--- 多服务器下这些是运行时值：每次请求/删除/字幕扫描按「发起时的那台服务器」求值，
--- 不做加载期常量（旧单文件版的 auth_prefix 是加载期一次算好，切服务器后会用错凭据）。
--- 返回 nil 表示 url 非法；调用方对单次操作缓存结果，不要在热路径上重复算。
--- match_url：url 缺尾斜杠时补一个（仅供字幕反查的前缀匹配，不写回 srv），
--- 防 conf 回退条目缺斜杠时长短前缀误配。
---
--- url 内嵌 userinfo（老配置可能有，curl 能用它认证）在这里**规范化剥离**，
--- 凭据优先取 srv.user/pass，缺失时回落到 URL 里的。不剥的后果很严重：
---   · auth_prefix 拼出两份凭据 → play_url 畸形 → mpv 播放直接失败（curl bad format）
---   · domain 带凭据 → 菜单 hint 明文显示密码
---   · auth_prefix 不再是 match_url 前缀 → 字幕反查必然失败
--- @param srv {url:string, user:string, pass:string}
--- @return {protocol:string, domain:string, user:string, pass:string, auth_prefix:string, match_url:string}|nil
function M.server_ctx(srv)
    if type(srv) ~= "table" or type(srv.url) ~= "string" then return nil end
    local protocol, rest = srv.url:match("^(https?://)(.*)$")
    if not protocol or rest == "" then return nil end
    -- userinfo 只可能出现在第一个 / 之前
    local authority, path = rest:match("^([^/?#]*)(.*)$")
    local url_user, url_pass = "", ""
    local domain = authority
    local at = authority:find("@", 1, true)
    if at then
        local creds = authority:sub(1, at - 1)
        domain = authority:sub(at + 1)
        local u, p = creds:match("^([^:]*):(.*)$")
        if u then url_user, url_pass = u, p else url_user = creds end
    end
    if domain == "" then return nil end
    -- 显式配置的账号密码优先；没配时用 URL 里带的
    local user = (srv.user ~= nil and srv.user ~= "") and srv.user or url_user
    local pass = (srv.pass ~= nil and srv.pass ~= "") and srv.pass or url_pass
    local match_url = protocol .. domain .. path
    if match_url:sub(-1) ~= "/" then match_url = match_url .. "/" end
    return {
        protocol = protocol,
        domain = domain,
        user = user,
        pass = pass,
        auth_prefix = protocol .. user .. ":" .. pass .. "@" .. domain,
        match_url = match_url,
    }
end

return M