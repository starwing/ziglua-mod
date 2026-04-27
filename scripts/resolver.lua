-- resolver.lua — shared utilities for Lua API analysis scripts.
-- Parses build.zig.zon to discover Lua versions and their package hashes,
-- so scripts read headers from zig-pkg/{hash}/ instead of archives/.

local path_sep = package.config:sub(1, 1)

local function join_path(...)
    local parts = { ... }
    local path = parts[1]

    for i = 2, #parts do
        local part = parts[i]
        if path:sub(-1) ~= path_sep then
            path = path .. path_sep
        end
        path = path .. part
    end

    return path
end

local function read_all(path)
    local file, err = io.open(path, "rb")
    if file == nil then
        return nil, err
    end

    local content = file:read("a")
    file:close()
    return content
end

local function split_lines(content)
    local normalized = content:gsub("\r\n", "\n")
    if normalized:sub(-1) ~= "\n" then
        normalized = normalized .. "\n"
    end

    local lines = {}
    for line in normalized:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Parse build.zig.zon and return a sorted list of Lua version descriptors.
-- Each entry: { name = "5.1.5", short = "5.1", hash = "N-V-__8..." }
-- @param root  project root directory (defaults to ".")
-- @return table
local function parse_build_zon(root)
    root = root or "."
    local zon_path = join_path(root, "build.zig.zon")
    local content, err = read_all(zon_path)
    if content == nil then
        error(("failed to read %s: %s"):format(zon_path, err))
    end

    local versions = {}

    -- Each dependency block looks like:
    --   .lua51 = .{ .url = "...lua-5.1.5.tar.gz", .hash = "HASH", .lazy = true },
    for key, url, hash in content:gmatch(
        '%.(lua5%d)%s*=%s*%.%s*{[^}]*%.url%s*=%s*"([^"]*)"[^}]*%.hash%s*=%s*"([^"]*)"'
    ) do
        local full_ver = url:match("lua%-(%d+%.%d+%.%d+)%.tar%.gz")
        if full_ver == nil then
            full_ver = url:match("lua%-(%d+%.%d+%.%d+)")
        end
        if full_ver then
            local short_ver = full_ver:match("^(%d+%.%d+)")
            versions[#versions + 1] = {
                name = full_ver,
                short = short_ver or full_ver,
                hash = hash,
            }
        end
    end

    if #versions == 0 then
        error("no Lua dependency entries found in " .. zon_path)
    end

    table.sort(versions, function(a, b) return a.name < b.name end)
    return versions
end

return {
    join_path = join_path,
    read_all = read_all,
    split_lines = split_lines,
    trim = trim,
    parse_build_zon = parse_build_zon,
}
