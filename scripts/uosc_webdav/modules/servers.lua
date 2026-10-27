-- modules/servers.lua — 多服务器列表的读取归一化、校验与原子写盘
--
-- 存储位置：~~/script-opts/uosc_webdav_servers.json（纯数据文件，字段含义写在本仓库 conf 注释里，
-- 因为 JSON 本身没有注释能力；与 script-opts/danmaku_blacklist.json 的既有惯例一致）。
--
-- 职责划分：
--   列表（结构体数组，增删服务器 = 动态项）→ 本模块写独立 JSON；
--   标量开关（persist_changes / default_server / video_only）→ 仍走 conf + conf-persist。
-- 本模块只管存储层：不碰菜单渲染、不维护 current_server 这类会话状态。

local mp = require 'mp'
local mp_utils = require 'mp.utils'
local msg = require 'mp.msg'

local M = {}

-- JSON 档缺失/损坏时回退出来的那台服务器的固定名称
M.FALLBACK_NAME = "默认"

local EXPAND_PATH = "~~/script-opts/uosc_webdav_servers.json"
local path_cache

--- JSON 档的绝对路径。~~ 在进程生命周期内不变，故只 expand 一次。
--- 注意：`--no-config` 会让 mpv 认为 config 目录不存在，此时 expand-path 只返回相对路径
--- "script-opts/…"（mpv 0.41 行为），后续 io 会相对进程 cwd 落盘；conf-persist 同样如此，
--- 属调用环境问题不是本模块要修的，故沿用同一行为、不在这里改写路径。
function M.path()
    if not path_cache then
        path_cache = mp.command_native({ "expand-path", EXPAND_PATH })
    end
    return path_cache
end

-- ============ 读取归一化 ============

-- 同一原因只提示一次：load 只在启动时调一次（增删改走内存 list + save），
-- 但保留去重以防未来调用面扩大后刷屏
local warned = {}
local function warn_once(key, text)
    if warned[key] then return end
    warned[key] = true
    msg.warn(text)
end

local function file_exists(path)
    return mp_utils.file_info(path) ~= nil
end

--- 用 conf 的 url/user/pass 合成单台服务器（不写盘）。
--- 这是老配置的零迁移路径：升级后没有 JSON 的用户行为不变。
--- 与 conf_fallback 对称：同样过 validate（不含重名检查），url 非法/缺尾斜杠时
--- 返回空列表（调用方 main.lua 会在 valid_servers 为空时拒绝加载，行为与原单服务器版一致）。
local function fallback_from_opts(opts)
    local entry = {
        name = M.FALLBACK_NAME,
        url = opts.url or "",
        user = opts.user or "",
        pass = opts.pass or "",
    }
    local ok = M.validate(entry, {})
    if not ok then return {} end
    return { entry }
end

--- 导出 conf 回退条目（单台，非列表包装）。
--- 供「删除最后一台服务器」等场景使用——不能用 M.load() 重新读档：
--- JSON 里可能还留着刚删的那台（persist_changes=no 时删除不写盘），
--- load() 会把它复活。
--- 回退条目同样过 validate（不含重名检查）：conf 里缺尾斜杠的 url 会被拒，
--- 调用方据此决定提示文案（非法条目不该静默进列表）。
function M.conf_fallback(opts)
    local entry = fallback_from_opts(opts)[1]
    local ok, _ = M.validate(entry, {})
    if not ok then return nil end
    return entry
end

--- 逐条字段清洗：坏条目丢弃并告警，user/pass 缺失或类型不对按空串处理（匿名）。
--- 返回清洗后的新数组（不复用原表，调用方可以放心往 state 里存）。
local function sanitize(raw)
    local out = {}
    for i, entry in ipairs(raw) do
        if type(entry) ~= "table" then
            warn_once("drop:" .. i, "服务器配置第 " .. i .. " 项不是对象，已忽略")
        else
            local name, url = entry.name, entry.url
            if type(name) ~= "string" or name == "" then
                warn_once("drop:" .. i, "服务器配置第 " .. i .. " 项缺少有效 name，已忽略")
            elseif type(url) ~= "string" or url == "" then
                warn_once("drop:" .. i, "服务器配置第 " .. i .. " 项（" .. name .. "）缺少有效 url，已忽略")
            else
                out[#out + 1] = {
                    name = name,
                    url = url,
                    -- user/pass 允许为空（匿名访问），故只做类型归一、不判空
                    user = type(entry.user) == "string" and entry.user or "",
                    pass = type(entry.pass) == "string" and entry.pass or "",
                }
            end
        end
    end
    return out
end

--- 读取服务器列表（归一化，永远不返回 nil）。
--- 返回数组：{ { name=…, url=…, user=…, pass=… }, … }
--- 归一化规则：
---   1. JSON 存在且 parse 成功且 .servers 为非空数组 → 用它（逐条字段清洗）
---   2. 文件缺失 → conf 的 url/user/pass 合成单台「默认」（不写盘、不告警：合法初始态）
---   3. parse 失败 / servers 为空或非数组 / 清洗后全被丢弃 → 同 2 回退，并一次性 warn
--- 参数 opts：modules/options.lua 的 M.opts 表（conf 读出的原始值）
function M.load(opts)
    opts = opts or {}
    local path = M.path()
    local file = path and io.open(path, "rb")
    if not file then
        -- 文件缺失：老用户首次升级的常态，不是错误
        return fallback_from_opts(opts)
    end

    local content = file:read("*a")
    file:close()

    -- 空文件（被清空 / 写到一半掉电）等同于「没有服务器」，不能当成有效配置
    if not content or content == "" then
        warn_once("empty", "服务器配置为空文件，已回退到 conf 单服务器：" .. tostring(path))
        return fallback_from_opts(opts)
    end

    -- parse_json 失败返回 nil, err（不抛错），故用 if not parsed 判失败
    local parsed = mp_utils.parse_json(content)
    if type(parsed) ~= "table" then
        warn_once("parse", "服务器配置解析失败，已回退到 conf 单服务器：" .. tostring(path))
        return fallback_from_opts(opts)
    end

    -- 版本位只用于诊断，不做硬性拒绝：未来加字段时老脚本仍应能读出现有字段
    if parsed.version ~= 1 then
        msg.verbose("服务器配置版本为 " .. tostring(parsed.version) .. "（当前认识 1），按 1 解析")
    end

    local raw = parsed.servers
    if type(raw) ~= "table" or #raw == 0 then
        -- 对象/字符串等非数组形态同样落到这里（#raw 为 0）
        warn_once("no_servers", "服务器配置里没有有效的 servers 数组，已回退到 conf 单服务器")
        return fallback_from_opts(opts)
    end

    local list = sanitize(raw)
    if #list == 0 then
        warn_once("all_invalid", "服务器配置里所有条目都无效，已回退到 conf 单服务器")
        return fallback_from_opts(opts)
    end
    return list
end

-- ============ 校验 ============

--- 校验单个服务器条目。
--- 返回 true | false, 错误描述（描述直接可给 OSD / 菜单提示）
--- 参数：
---   entry         待校验条目
---   list          现有列表，用于重名检查（可传 nil / 空表）
---   exclude_index 编辑场景：校验「列表中第 exclude_index 项正在被改成 entry」，重名检查跳过它自己
function M.validate(entry, list, exclude_index)
    if type(entry) ~= "table" then
        return false, "服务器条目无效（不是表）"
    end

    local name = entry.name
    if type(name) ~= "string" then
        return false, "服务器名称必须是字符串"
    end
    -- 首尾空白/控制字符清洗：菜单显示与 default_server conf 往返都要求名称干净
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name ~= entry.name then entry.name = name end
    if name == "" then
        return false, "服务器名称不能为空"
    end
    if name:find("%c") then
        return false, "服务器名称不能包含控制字符"
    end
    -- 换行会破坏菜单单行显示，也说明值来自粘贴时没清洗
    if name:find("[\r\n]") then
        return false, "服务器名称不能包含换行"
    end
    -- 双引号会破坏菜单条目命令的 %q 参数往返。
    -- 服务器行的 value 是 `script-message webdav-select-server "<name>"`，
    -- 名称里带 " 时 mpv 命令解析会截断（`my "quoted" name` 会变成 `my `），
    -- 导致点测试/编辑/删除无反应。直接禁掉比做多层转义可靠。
    if name:find('"', 1, true) then
        return false, "服务器名称不能包含双引号"
    end
    for i, srv in ipairs(list or {}) do
        if i ~= exclude_index and type(srv) == "table" and srv.name == name then
            return false, "服务器名称重复：" .. name
        end
    end

    local url = entry.url
    if type(url) ~= "string" then
        return false, "服务器地址必须是字符串"
    end
    if url == "" then
        return false, "服务器地址不能为空"
    end
    if url:find("[\r\n]") then
        return false, "服务器地址不能包含换行"
    end
    -- 协议 + 非空主机：^https?:// 单独用会放过 "http://"（无主机）
    if not url:match("^https?://[^/]+") then
        return false, "服务器地址必须以 http:// 或 https:// 开头并带主机名"
    end
    -- 注意：URL 内嵌 userinfo（http://user:pass@host/）**不在这里拒绝**。
    -- 这里是加载期/写盘期的共同关口，而老配置里完全可能有这种 URL 且 curl 能用它认证
    -- （URL 自带凭据），拒绝会让「能用的旧配置」直接判死。
    -- 内嵌凭据只在「菜单录入路径」劝阻，见 main.lua 的 ask_server_fields。
    -- 尾斜杠是硬要求：URL 拼接（根目录/子目录/播放 URL）和 dir_cache 的键都依赖它。
    -- 这里刻意不做「自动补 /」的容错——静默改写 URL 会让缓存键与实际请求路径错位，
    -- 症状是「切过的目录显示成旧内容」这类极难定位的问题，不如让用户显式改对。
    if url:sub(-1) ~= "/" then
        return false, "服务器地址必须以 / 结尾"
    end

    -- user/pass 允许为空（匿名 WebDAV），但类型必须是字符串，否则序列化/curl 会出错
    if entry.user ~= nil and type(entry.user) ~= "string" then
        return false, "用户名必须是字符串"
    end
    if entry.pass ~= nil and type(entry.pass) ~= "string" then
        return false, "密码必须是字符串"
    end

    return true
end

-- ============ 原子写盘 ============

local function remove_file(path)
    if not file_exists(path) then return true end
    return os.remove(path) and true or false
end

--- 原子写盘：{ version = 1, servers = list } → JSON 档。
--- 返回 true | false, err（err ∈ invalid_entry / format_error / io_error / rename_error，
--- 分类风格对齐 script-modules/conf-persist.lua，调用方据此决定提示文案）。
---
--- 与 conf-persist 的语义差异（勿照抄那边的守卫）：
---   1. 目标文件不存在 = 合法初始态，允许创建 —— JSON 无注释可保，没有「缩水成单键文件」的风险；
---      conf-persist 的 config_missing 拒写在这里是错的。
---   2. 「读到损坏 JSON → 空列表写回去」是禁止路径：save 的调用方必须传完整列表，
---      空列表 / 非法条目一律在碰磁盘前拒绝（下面第一条守卫）。正是这条避免了
---      「一次 parse 失败把用户手改坏但可修复的档覆盖成空档」。
---   3. 文件内容损坏由 load 负责降级，不由 save 负责判断（save 拿不到「旧档是否可修」的信息）。
function M.save(list)
    -- 守卫 1：空列表拒写（见上方语义差异第 2 条）
    if type(list) ~= "table" or #list == 0 then
        msg.error("服务器列表为空，拒绝写盘（禁止用空列表覆盖现有配置）")
        return false, "invalid_entry"
    end
    -- 守卫 2：整表校验，任一失败都不碰磁盘（不做半截写）
    for i, entry in ipairs(list) do
        local ok, err = M.validate(entry, list, i)
        if not ok then
            msg.error("服务器列表第 " .. i .. " 项校验失败，已拒绝写盘：" .. tostring(err))
            return false, "invalid_entry"
        end
    end

    -- 守卫 3：先序列化拿到字符串，再开文件。顺序反了会先截断旧档。
    -- 本版本 format_json 失败是抛 Lua error 而不是返回 nil，必须 pcall 兜住。
    local ok, json_str = pcall(mp_utils.format_json, { version = 1, servers = list })
    if not ok then
        msg.error("服务器列表序列化失败（含不可序列化的值）：" .. tostring(json_str))
        return false, "format_error"
    end
    if type(json_str) ~= "string" or json_str == "" then
        msg.error("服务器列表序列化结果为空，已拒绝写盘")
        return false, "format_error"
    end

    local conf_path = M.path()
    if not conf_path or conf_path == "" then
        msg.error("无法解析服务器配置路径，跳过写盘")
        return false, "io_error"
    end
    local tmp_path = conf_path .. ".tmp"
    local bak_path = conf_path .. ".bak"

    -- format_json 输出无缩进单行，文件末尾补 \n（避免 POSIX 工具把末行当成不完整行）
    local file, open_err = io.open(tmp_path, "wb")
    if not file then
        msg.error("无法创建临时文件 " .. tmp_path .. "（" .. tostring(open_err) .. "）")
        return false, "io_error"
    end
    local wrote, write_err = file:write(json_str .. "\n")
    local closed, close_err = file:close()
    if not wrote or not closed then
        os.remove(tmp_path)
        msg.error("写入临时文件失败（" .. tostring(write_err or close_err) .. "），原配置未动")
        return false, "io_error"
    end
    -- 说明：Lua 无 fsync 接口，本流程防的是崩溃/杀软占用导致的半写，
    -- 不防系统级掉电（rename 后内容可能还在缓存里）。正式档损坏时 load 会回退 conf。

    -- 两跳替换：Windows 的 os.rename 不能覆盖已存在文件，必须 conf→bak、tmp→conf
    local has_original = file_exists(conf_path)
    if has_original then
        -- 旧 .bak 可能还留着（上次清理失败），先删掉才能让 conf→bak 成功
        if not remove_file(bak_path) then
            os.remove(tmp_path)
            msg.error("无法清理旧备份 " .. bak_path .. "（可能被占用），本次写盘已跳过，原配置未动")
            return false, "rename_error"
        end
        if not os.rename(conf_path, bak_path) then
            os.remove(tmp_path)
            msg.error("无法备份原配置 " .. conf_path .. "，本次写盘已跳过，原配置未动")
            return false, "rename_error"
        end
    end

    if os.rename(tmp_path, conf_path) then
        -- 成功。备份删不掉只告警：正式档已就位，下次写盘会先清理
        if not remove_file(bak_path) then
            msg.warn("服务器配置备份 " .. bak_path .. " 清理失败（可能被占用），下次写盘将重试")
        end
        msg.info("服务器配置已写入：" .. conf_path .. "（" .. #list .. " 台）")
        return true
    end

    -- tmp 转正失败：尽力回滚（正式档暂缺时用 bak 还原）
    if has_original and not os.rename(bak_path, conf_path) then
        msg.error("回滚备份 " .. bak_path .. " 失败，正式档暂缺，请手工把 .bak 改名回 .json")
    end
    os.remove(tmp_path)
    msg.error("替换服务器配置失败：" .. conf_path)
    return false, "rename_error"
end

return M
