-- modules/utils.lua — 工具函数

local M = {}

function M.url_decode(str)
    str = string.gsub(str, "+", " ")
    str = string.gsub(str, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return str
end

function M.format_size(bytes_str)
    local n = tonumber(bytes_str)
    if not n or n == 0 then return "" end
    if n >= 1073741824 then return string.format("%.1f GB", n / 1073741824)
    elseif n >= 1048576 then return string.format("%.1f MB", n / 1048576)
    elseif n >= 1024    then return string.format("%.1f KB", n / 1024)
    else return n .. " B" end
end

function M.copy_items(src)
    local dst = {}
    for i, item in ipairs(src or {}) do
        dst[i] = item
    end
    return dst
end

function M.natural_compare(a, b)
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

function M.parse_lastmod(s, month_map)
    if not s or s == "" then return 0 end
    local day, mon, year, h, m = s:match("(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):")
    if not day then return 0 end
    return (tonumber(year) or 0) * 100000000
         + (month_map[mon] or 0) * 1000000
         + tonumber(day) * 10000
         + tonumber(h) * 100
         + tonumber(m)
end

--- 将 WebDAV lastmod 格式化为简短时间显示，供 hint 使用。
--- 输入: "Thu, 15 Jun 2025 14:30:00 GMT"
--- 输出: "06-15 14:30"
function M.format_lastmod(s, month_map)
    if not s or s == "" then return "" end
    local day, mon, year, h, m = s:match("(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):")
    if not day then return "" end
    local mon_num = month_map[mon]
    if not mon_num then return "" end
    return string.format("%04d/%02d/%02d %02d:%02d", tonumber(year), mon_num, tonumber(day), tonumber(h), tonumber(m))
end

function M.slang_match(tag, name)
    if tag:find("&", 1, true) then
        for part in tag:gmatch("[^&]+") do
            if not name:find(part, 1, true) then return false end
        end
        return true
    else
        return name:find(tag, 1, true) ~= nil
    end
end

function M.slang_priority(name, slang)
    local lower = name:lower()
    for i, tag in ipairs(slang) do
        if M.slang_match(tag, lower) then return i end
    end
    return #slang + 1
end

return M