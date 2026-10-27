-- -----------------------------------------------------------------------------
-- conf-persist.lua：菜单参数写盘公共模块
-- 把「播放时调参 → 原位写回 script-opts/<脚本名>.conf」抽成共享实现。
-- 机制要点：
--   - gsub 原位替换目标键行，其余注释与排版不动
--   - tmp+bak 两跳原子替换（Windows rename 不能覆盖已存在文件）
--   - 残局恢复：上次写盘中途崩溃留下「正式档缺失、.bak 唯一副本」时先还原
--   - 双缺拒写 / 空内容拒写：防止以空基重建、毁灭重注释配置
--   - 批量单次写：多键累积替换后一次落盘，要么全落要么全不动
-- 布尔序列化为 yes/no。任一键不在 options 表即整体拒写（调用方 bug）。
--
-- 使用方式：
--   package.path = mp.command_native({"expand-path", "~~/script-modules/?.lua;"}) .. package.path
--   local conf_persist = require 'conf-persist'
--   local writer = conf_persist.new{script_name = "xxx", options = options}
--   writer:persist_keys({"key1", "key2"})  /  writer:persist_key("key1")
--   - script_name：必填 string，日志前缀 + conf 文件名基干
--   - options：必填 table，read_options 后的 options 表引用（当前值唯一真源；
--     引用须稳定——只改键值，不得整体替换表）
--   - conf_name：可选，conf 文件名覆盖（仅文件名基干，不含路径分隔符与 ..）
-- 返回值契约：成功 true；失败一律 false + err 分类串，绝不返回 nil。
-- err 分类：invalid_keys / config_missing / bak_recovery_failed /
-- empty_content / io_error / rename_error / exception: ...
-- 边界：① 值不得含换行/CR；② 白名单键行不要写行尾注释（会被替换吞掉）。
-- -----------------------------------------------------------------------------
local mp = require("mp")
local mp_utils = require("mp.utils")
local msg = require("mp.msg")

local M = {}

-- 清理 .bak。只读属性会让 os.remove 静默失败并黏死后续 rename，故先清只读再重试
local function remove_bak(bak_path)
	if os.remove(bak_path) then return true end
	if not mp_utils.file_info(bak_path) then return true end -- 本就不存在
	os.execute('attrib -R "' .. bak_path .. '" >nul 2>&1')
	return os.remove(bak_path) and true or false
end

-- 构造写盘器实例。参数不合法直接 error()（构造期不属于持久化执行路径）
function M.new(opts)
	if type(opts) ~= "table" then
		error("conf-persist: new 参数必须是 table", 2)
	end
	if type(opts.script_name) ~= "string" then
		error("conf-persist: script_name 必须是 string", 2)
	end
	if type(opts.options) ~= "table" then
		error("conf-persist: options 必须是 table", 2)
	end
	if opts.conf_name ~= nil then
		if type(opts.conf_name) ~= "string" or opts.conf_name == "" then
			error("conf-persist: conf_name 必须是非空 string 或 nil", 2)
		end
		if opts.conf_name:find("[/\\]", 1, false) or opts.conf_name:find("..", 1, true) then
			error("conf-persist: conf_name 仅接受文件名基干，不含路径分隔符（/ \\ ..）: "
				.. tostring(opts.conf_name), 2)
		end
	end

	local script_name = opts.script_name
	local options = opts.options
	local conf_name = opts.conf_name or (script_name .. ".conf")

	-- 所有失败分支返回 false + err 分类串
	local function persist_keys_impl(keys)
		if type(keys) ~= "table" then
			msg.error(script_name .. ": persist_keys 参数无效（非表），跳过持久化")
			return false, "invalid_keys"
		end
		if #keys == 0 then return true end
		-- 先整体校验，不做半截写
		for _, key in ipairs(keys) do
			if options[key] == nil then
				msg.error(script_name .. ": 选项 " .. tostring(key) .. " 不存在，跳过持久化")
				return false, "invalid_keys"
			end
		end
		local config_path = mp.command_native({ "expand-path", "~~/script-opts/" .. conf_name })
		local bak_path = config_path .. ".bak"
		-- 双缺拒写：没有可保留注释的基础，不静默重建
		if not mp_utils.file_info(config_path) and not mp_utils.file_info(bak_path) then
			msg.error(script_name .. ": 配置文件不存在，跳过持久化 " .. tostring(config_path))
			return false, "config_missing"
		end
		-- 残局恢复失败不能放行（会以空基重建并删掉持有原文的 .bak）
		if not mp_utils.file_info(config_path) and mp_utils.file_info(bak_path) then
			if not os.rename(bak_path, config_path) then
				msg.error(script_name .. ": 检测到备份 " .. tostring(bak_path) ..
					" 但残局恢复失败（可能被占用），跳过持久化")
				return false, "bak_recovery_failed"
			end
		end
		local file = io.open(config_path, "rb")
		local content = file and file:read("*a") or ""
		if file then file:close() end
		-- 空内容拒写：io 瞬时失败或 0 字节空档，同双缺守卫拒写
		if content == "" then
			msg.error(script_name .. ": 配置文件存在但读出为空，跳过持久化 " .. tostring(config_path))
			return false, "empty_content"
		end

		for _, key in ipairs(keys) do
			local value = options[key]
			local serialized = type(value) == "boolean" and (value and "yes" or "no") or tostring(value)
			-- gsub 替换串里 % 是特殊字符，须转义
			local serialized_escaped = serialized:gsub("%%", "%%%%")
			local pattern_name = key:gsub("([^%w])", "%%%1")
			local replaced
			content, replaced = content:gsub(
				"^([ \t]*" .. pattern_name .. "[ \t]*=)[^\r\n]*",
				"%1" .. serialized_escaped,
				1
			)
			if replaced == 0 then
				content, replaced = content:gsub(
					"([\r\n][ \t]*" .. pattern_name .. "[ \t]*=)[^\r\n]*",
					"%1" .. serialized_escaped,
					1
				)
			end
			if replaced == 0 then
				-- 键不存在则追加到文件末尾
				local newline = content:find("\r\n", 1, true) and "\r\n" or "\n"
				if content ~= "" and not content:match("[\r\n]$") then content = content .. newline end
				content = content .. key .. "=" .. serialized .. newline
			end
		end

		local tmp_path = config_path .. ".tmp"
		-- write/close 都必须检查，失败即删 tmp，原配置分毫不动
		file = io.open(tmp_path, "wb")
		if not file then
			msg.error(script_name .. ": 无法持久化菜单改动，无法创建临时文件 " .. tostring(tmp_path))
			return false, "io_error"
		end
		local wrote, write_err = file:write(content)
		local closed, close_err = file:close()
		if not wrote or not closed then
			os.remove(tmp_path)
			msg.error(script_name .. ": 菜单改动写入失败 (" .. tostring(write_err or close_err) .. ")，原配置未动")
			return false, "io_error"
		end

		-- 原子替换：conf→bak，再 tmp→conf；tmp 转正失败时尽力回滚
		local has_original = mp_utils.file_info(config_path) ~= nil
		if has_original and not remove_bak(bak_path) then
			os.remove(tmp_path)
			msg.error(script_name .. ": 无法清理旧备份 " .. tostring(bak_path) ..
				"（可能被占用或权限拒绝），本次持久化已跳过，原配置未动")
			return false, "rename_error"
		end
		if has_original and not os.rename(config_path, bak_path) then
			os.remove(tmp_path)
			msg.error(script_name .. ": 无法备份原配置 " .. tostring(config_path))
			return false, "rename_error"
		end
		if os.rename(tmp_path, config_path) then
			if not remove_bak(bak_path) then
				msg.warn(script_name .. ": 备份 " .. tostring(bak_path) ..
					" 清理失败（可能被占用），将在下次写盘时重试")
			end
		else
			if has_original and not os.rename(bak_path, config_path) then
				msg.error(script_name .. ": 回滚备份 " .. tostring(bak_path) ..
					" 失败，正式档暂缺，将由下次写盘的残局恢复还原")
			end
			os.remove(tmp_path)
			msg.error(script_name .. ": 替换配置文件失败 " .. tostring(config_path))
			return false, "rename_error"
		end

		msg.info(script_name .. ": 已持久化菜单改动: " .. table.concat(keys, ", "))
		return true
	end

	local writer = {}

	-- 批量写。函数体包 pcall，Lua 异常归一为 false, "exception: ..."
	function writer:persist_keys(keys)
		local ok, res, err = pcall(persist_keys_impl, keys)
		if not ok then
			msg.error(script_name .. ": 持久化发生异常: " .. tostring(res))
			return false, "exception: " .. tostring(res)
		end
		if res == nil then
			msg.error(script_name .. ": 持久化返回了 nil（契约违反），按失败处理")
			return false, "exception: persist 返回 nil"
		end
		return res, err
	end

	-- 单键写。键名类型前置检查：persist_key(nil) 会被空表短路静默吞掉，故拦下
	function writer:persist_key(key)
		if type(key) ~= "string" then
			msg.error(script_name .. ": persist_key 键名无效（" .. tostring(key) .. "），跳过持久化")
			return false, "invalid_keys"
		end
		return self:persist_keys({ key })
	end

	return writer
end

return M
