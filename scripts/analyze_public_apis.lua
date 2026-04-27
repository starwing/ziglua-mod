local path_sep = package.config:sub(1, 1)
local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local resolver = dofile(script_dir .. "resolver.lua")

local join_path = resolver.join_path
local read_all = resolver.read_all
local split_lines = resolver.split_lines
local trim = resolver.trim
local versions = resolver.parse_build_zon(arg[1] or ".")

local headers = {
    "luaconf.h",
    "lua.h",
    "lauxlib.h",
    "lualib.h",
}
table.sort(headers)

local function starts_with(text, prefix)
    return text:sub(1, #prefix) == prefix
end

local function normalize_source_line(line, strip_backslash)
    local text = trim(line:gsub("\t", "    "))
    if strip_backslash then
        text = trim(text:gsub("\\%s*$", ""))
    end
    return text
end

local function flatten_lines(lines, first_line, last_line, strip_backslash)
    local parts = {}
    for line_index = first_line, last_line do
        parts[#parts + 1] = normalize_source_line(lines[line_index], strip_backslash)
    end
    return table.concat(parts, " ")
end

local function is_lua_symbol(symbol)
    return starts_with(symbol, "LUA_")
end

local function is_api_symbol(symbol)
    return starts_with(symbol, "lua_") or starts_with(symbol, "luaL_")
end

local function make_entry(version_name, header_name, line_number, text)
    return {
        version = version_name,
        file = header_name,
        line = line_number,
        text = text,
    }
end

local function add_entry(bucket, symbol, entry)
    local records = bucket.entries[symbol]
    if records == nil then
        records = {}
        bucket.entries[symbol] = records
        bucket.order[#bucket.order + 1] = symbol
    end

    records[#records + 1] = entry
end

local function find_api_decl_symbol(declaration)
    local symbol = declaration:match("%((luaL_[%w_]*)%)%s*%(")
    if symbol ~= nil then
        return symbol
    end

    symbol = declaration:match("%((lua_[%w_]*)%)%s*%(")
    if symbol ~= nil then
        return symbol
    end

    local prefix = declaration:match("^(.-)%s*%(")
    if prefix == nil then
        return nil
    end

    local last_symbol = nil
    for token in prefix:gmatch("([%a_][%w_]*)") do
        if is_api_symbol(token) then
            last_symbol = token
        end
    end

    return last_symbol
end

local function parse_header(path, version_name, header_name, parsed)
    local content, err = read_all(path)
    if content == nil then
        error(("failed to read %s: %s"):format(path, err))
    end

    local lines = split_lines(content)
    local line_index = 1

    while line_index <= #lines do
        local line = lines[line_index]
        local directive, symbol = line:match("^%s*#%s*(define)%s+([%a_][%w_]*)")
        if symbol == nil then
            directive, symbol = line:match("^%s*#%s*(undef)%s+([%a_][%w_]*)")
        end

        if symbol ~= nil then
            local last_line = line_index
            if directive == "define" then
                while last_line < #lines and lines[last_line]:match("\\%s*$") do
                    last_line = last_line + 1
                end
            end

            local entry = make_entry(
                version_name,
                header_name,
                line_index,
                flatten_lines(lines, line_index, last_line, directive == "define")
            )

            if is_lua_symbol(symbol) then
                add_entry(parsed.LUA, symbol, entry)
            end
            if is_api_symbol(symbol) then
                add_entry(parsed.API, symbol, entry)
            end

            line_index = last_line + 1
        elseif line:match("^%s*[A-Z_]+_API%s") ~= nil then
            local last_line = line_index
            while last_line < #lines and not lines[last_line]:find(";", 1, true) do
                last_line = last_line + 1
            end

            local declaration = flatten_lines(lines, line_index, last_line, false)
            local api_symbol = find_api_decl_symbol(declaration)
            if api_symbol ~= nil then
                add_entry(
                    parsed.API,
                    api_symbol,
                    make_entry(version_name, header_name, line_index, declaration)
                )
            end

            line_index = last_line + 1
        else
            line_index = line_index + 1
        end
    end
end

local function index_of(list, value)
    for i = 1, #list do
        if list[i] == value then
            return i
        end
    end
    return nil
end

local function insert_at(list, index, value)
    if index == nil then
        index = #list + 1
    elseif index < 1 then
        index = 1
    end

    if index > #list + 1 then
        index = #list + 1
    end

    for i = #list, index, -1 do
        list[i + 1] = list[i]
    end
    list[index] = value
end

local function find_prev_present(order, present, pos)
    for i = pos - 1, 1, -1 do
        local symbol = order[i]
        if present[symbol] then
            return symbol
        end
    end
    return nil
end

local function find_next_present(order, present, pos)
    for i = pos + 1, #order do
        local symbol = order[i]
        if present[symbol] then
            return symbol
        end
    end
    return nil
end

local function build_master_order(all_data, bucket_name)
    local master = {}
    local present = {}

    for version_index = #versions, 1, -1 do
        local version_name = versions[version_index].name
        local order = all_data[version_name][bucket_name].order

        for pos = 1, #order do
            local symbol = order[pos]
            if not present[symbol] then
                local prev_symbol = find_prev_present(order, present, pos)
                local next_symbol = find_next_present(order, present, pos)

                local insert_index = #master + 1
                if prev_symbol ~= nil then
                    local prev_index = index_of(master, prev_symbol)
                    if prev_index ~= nil then
                        insert_index = prev_index + 1
                    end
                elseif next_symbol ~= nil then
                    local next_index = index_of(master, next_symbol)
                    if next_index ~= nil then
                        insert_index = next_index
                    end
                end

                insert_at(master, insert_index, symbol)
                present[symbol] = true
            end
        end
    end

    return master
end

local function collect_files(all_data, bucket_name, symbol)
    local seen = {}
    local files = {}

    for version_index = #versions, 1, -1 do
        local version_name = versions[version_index].name
        local entries = all_data[version_name][bucket_name].entries[symbol]
        if entries ~= nil then
            for _, entry in ipairs(entries) do
                if not seen[entry.file] then
                    seen[entry.file] = true
                    files[#files + 1] = entry.file
                end
            end
        end
    end

    table.sort(files)
    return files
end

local function render_category(lines, title, all_data, bucket_name, order)
    lines[#lines + 1] = title
    lines[#lines + 1] = ""

    for _, symbol in ipairs(order) do
        local files = collect_files(all_data, bucket_name, symbol)
        lines[#lines + 1] = ("- %s: %s"):format(symbol, table.concat(files, ", "))

        for version_index = 1, #versions do
            local version_name = versions[version_index].name
            local entries = all_data[version_name][bucket_name].entries[symbol]
            if entries ~= nil then
                for _, entry in ipairs(entries) do
                    lines[#lines + 1] = ("%s:%d:%s"):format(version_name, entry.line, entry.text)
                end
            end
        end

        lines[#lines + 1] = ""
    end
end

local function parse_all(root)
    local all_data = {}

    for _, version in ipairs(versions) do
        local parsed = {
            LUA = { order = {}, entries = {} },
            API = { order = {}, entries = {} },
        }
        all_data[version.name] = parsed

        local base = join_path(root, "zig-pkg", version.hash, "src")
        for _, header_name in ipairs(headers) do
            parse_header(join_path(base, header_name), version.name, header_name, parsed)
        end
    end

    return all_data
end

local function write_output(path, lines)
    local file, err = io.open(path, "wb")
    if file == nil then
        error(("failed to write %s: %s"):format(path, err))
    end

    file:write(table.concat(lines, "\n"))
    file:write("\n")
    file:close()
end

local function main()
    local root = arg[1] or "."
    local output_name = arg[2] or "apis.txt"

    local all_data = parse_all(root)
    local lua_order = build_master_order(all_data, "LUA")
    local api_order = build_master_order(all_data, "API")

    local lines = {}
    render_category(lines, "== LUA_ symbols ==", all_data, "LUA", lua_order)
    render_category(lines, "== lua_ / luaL_ interfaces ==", all_data, "API", api_order)

    local output_path = join_path(root, output_name)
    write_output(output_path, lines)

    io.stdout:write(
        ("wrote %s with %d LUA_ symbols and %d lua_/luaL_ interfaces\n")
        :format(output_path, #lua_order, #api_order)
    )
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write(("error: %s\n"):format(err))
    os.exit(1)
end
