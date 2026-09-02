-- modules/sort.lua — 排序相关功能

local options = require "modules.options"
local utils = require "modules.utils"

local M = {}

local state = nil  -- 由 main.lua 注入

function M.init(s)
    state = s
end

function M.get_sort_mode()
    return state.dir_sort[state.current_loaded_url] or options.opts.default_sort
end

function M.set_sort_mode(m)
    state.dir_sort[state.current_loaded_url] = m
end

function M.apply_sort()
    local m = M.get_sort_mode()
    table.sort(state.cached_dir_items, function(a, b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        if m == "name_desc" then
            return utils.natural_compare(b.name, a.name)
        elseif m == "time_desc" then
            local ta, tb = utils.parse_lastmod(a.lastmod, options.month_map), utils.parse_lastmod(b.lastmod, options.month_map)
            if ta ~= tb then return ta > tb end
            return utils.natural_compare(a.name, b.name)
        elseif m == "time_asc" then
            local ta, tb = utils.parse_lastmod(a.lastmod, options.month_map), utils.parse_lastmod(b.lastmod, options.month_map)
            if ta ~= tb then return ta < tb end
            return utils.natural_compare(a.name, b.name)
        elseif m == "size_desc" or m == "size_asc" then
            -- 目录恒排前（上方 is_dir 分支已处理），文件按字节比；
            -- 无 size 的条目（异常响应）按 0 参与比较，同值回退自然排序
            local sa, sb = tonumber(a.size) or 0, tonumber(b.size) or 0
            if sa ~= sb then
                if m == "size_desc" then return sa > sb else return sa < sb end
            end
            return utils.natural_compare(a.name, b.name)
        else
            return utils.natural_compare(a.name, b.name)
        end
    end)
end

return M