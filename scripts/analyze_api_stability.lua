local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local resolver = dofile(script_dir .. "resolver.lua")

local join_path = resolver.join_path
local read_all = resolver.read_all
local split_lines = resolver.split_lines
local trim = resolver.trim
local versions = resolver.parse_build_zon(arg[1] or ".")

local latest_version_name = versions[#versions].name

local function maybe_append_space(buffer)
    if #buffer > 0 and buffer[#buffer] ~= " " then
        buffer[#buffer + 1] = " "
    end
end

local function normalize_declaration(text)
    local buffer = {}
    local index = 1
    local in_block_comment = false
    local in_string = false
    local string_quote = nil
    local escaped = false
    local pending_space = false

    while index <= #text do
        local char = text:sub(index, index)
        local next_char = text:sub(index + 1, index + 1)

        if in_block_comment then
            if char == "*" and next_char == "/" then
                in_block_comment = false
                pending_space = true
                index = index + 2
            else
                index = index + 1
            end
        elseif in_string then
            buffer[#buffer + 1] = char
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == string_quote then
                in_string = false
                string_quote = nil
            end
            index = index + 1
        elseif char == "/" and next_char == "*" then
            in_block_comment = true
            pending_space = true
            index = index + 2
        elseif char == "/" and next_char == "/" then
            break
        elseif char == "\"" or char == "'" then
            if pending_space then
                maybe_append_space(buffer)
                pending_space = false
            end
            buffer[#buffer + 1] = char
            in_string = true
            string_quote = char
            escaped = false
            index = index + 1
        elseif char:match("%s") ~= nil then
            pending_space = true
            index = index + 1
        else
            if pending_space then
                maybe_append_space(buffer)
                pending_space = false
            end
            buffer[#buffer + 1] = char
            index = index + 1
        end
    end

    return trim(table.concat(buffer))
end

local function build_compare_declaration(text)
    local normalized = normalize_declaration(text)
    local buffer = {}
    local in_string = false
    local string_quote = nil
    local escaped = false

    for index = 1, #normalized do
        local char = normalized:sub(index, index)

        if in_string then
            buffer[#buffer + 1] = char
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == string_quote then
                in_string = false
                string_quote = nil
            end
        elseif char == '"' or char == "'" then
            buffer[#buffer + 1] = char
            in_string = true
            string_quote = char
            escaped = false
        elseif char:match("%s") ~= nil or char == "(" or char == ")" then
            -- ignore spaces and parentheses for comparison
        else
            buffer[#buffer + 1] = char
        end
    end

    return table.concat(buffer)
end

local function parse_apis(path)
    local content, err = read_all(path)
    if content == nil then
        error(("failed to read %s: %s"):format(path, err))
    end

    local order = {}
    local entries = {}
    local current_symbol = nil

    for _, line in ipairs(split_lines(content)) do
        local symbol = line:match("^%- ([^:]+):")
        if symbol ~= nil then
            current_symbol = symbol
            if entries[symbol] == nil then
                entries[symbol] = {
                    declarations = {},
                    bundles = {},
                }
                order[#order + 1] = symbol
            end
        else
            local version_name, _, declaration = line:match("^(%d+%.%d+%.%d+):(%d+):(.*)$")
            if version_name ~= nil and current_symbol ~= nil then
                local entry = entries[current_symbol]
                local declarations = entry.declarations[version_name]
                if declarations == nil then
                    declarations = {}
                    entry.declarations[version_name] = declarations
                end
                declarations[#declarations + 1] = build_compare_declaration(declaration)
            end
        end
    end

    for _, symbol in ipairs(order) do
        local entry = entries[symbol]
        for _, version in ipairs(versions) do
            local declarations = entry.declarations[version.name]
            if declarations ~= nil then
                entry.bundles[version.name] = table.concat(declarations, "\n")
            end
        end
    end

    return order, entries
end

local function collect_present_versions(entry)
    local present = {}

    for index, version in ipairs(versions) do
        local bundle = entry.bundles[version.name]
        if bundle ~= nil then
            present[#present + 1] = {
                index = index,
                name = version.name,
                short = version.short,
                bundle = bundle,
            }
        end
    end

    return present
end

local function is_base_api(entry)
    local first_bundle = entry.bundles[versions[1].name]
    if first_bundle == nil then
        return false
    end

    for i = 2, #versions do
        local bundle = entry.bundles[versions[i].name]
        if bundle == nil or bundle ~= first_bundle then
            return false
        end
    end

    return true
end

local function format_group(versions_in_group)
    if #versions_in_group == 1 then
        return versions_in_group[1].short
    end

    local first_index = versions_in_group[1].index
    local last_index = versions_in_group[#versions_in_group].index
    local is_contiguous = last_index - first_index + 1 == #versions_in_group
    local ends_at_latest = last_index == #versions

    if is_contiguous and ends_at_latest then
        return (">= %s"):format(versions_in_group[1].short)
    end

    local labels = {}
    for _, version in ipairs(versions_in_group) do
        labels[#labels + 1] = version.short
    end
    return table.concat(labels, " == ")
end

local function build_diff_summary(entry)
    local present = collect_present_versions(entry)
    if #present == 0 then
        return nil
    end

    local groups_by_bundle = {}
    local group_order = {}

    for _, version in ipairs(present) do
        local group = groups_by_bundle[version.bundle]
        if group == nil then
            group = { versions = {} }
            groups_by_bundle[version.bundle] = group
            group_order[#group_order + 1] = group
        end
        group.versions[#group.versions + 1] = version
    end

    table.sort(group_order, function(left, right)
        return left.versions[1].index < right.versions[1].index
    end)

    local labels = {}
    for _, group in ipairs(group_order) do
        labels[#labels + 1] = format_group(group.versions)
    end

    return table.concat(labels, ", ")
end

local function write_lines(path, lines)
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
    local input_name = arg[2] or "apis.txt"
    local base_output_name = arg[3] or "base_apis.txt"
    local diff_output_name = arg[4] or "diff_apis.txt"

    local input_path = join_path(root, input_name)
    local order, entries = parse_apis(input_path)

    local base_lines = {}
    local diff_lines = {}

    for _, symbol in ipairs(order) do
        local entry = entries[symbol]
        if is_base_api(entry) then
            base_lines[#base_lines + 1] = ("- %s"):format(symbol)
        else
            local summary = build_diff_summary(entry)
            if summary ~= nil then
                diff_lines[#diff_lines + 1] = ("- %s: %s"):format(symbol, summary)
            end
        end
    end

    write_lines(join_path(root, base_output_name), base_lines)
    write_lines(join_path(root, diff_output_name), diff_lines)

    io.stdout:write(
        ("wrote %s (%d entries) and %s (%d entries)\n")
        :format(base_output_name, #base_lines, diff_output_name, #diff_lines)
    )
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write(("error: %s\n"):format(err))
    os.exit(1)
end
