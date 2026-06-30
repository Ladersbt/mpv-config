-- modules/options.lua — 配置与常量

local opt = require 'mp.options'
local msg = require 'mp.msg'

local M = {}

-- 用户配置
M.opts = {
    url = "http://192.168.1.100:8080/dav/",
    user = "admin",
    pass = "password",
    default_sort = "name_asc",
    video_only = true,
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
}

-- 月份映射
M.month_map = {
    Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6,
    Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12
}

-- 派生的 URL 片段
M.protocol, M.domain = M.opts.url:match("^(https?://)([^/]+)")
if not M.protocol or not M.domain then
    msg.error("WebDAV URL 配置无效: " .. tostring(M.opts.url))
end
M.auth_prefix = M.protocol .. M.opts.user .. ":" .. M.opts.pass .. "@" .. M.domain

return M