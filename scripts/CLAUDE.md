# Scripts — API Analysis Tools

These Lua scripts parse Lua C headers across all supported versions to build reference files for the binding process. They use `scripts/resolver.lua` to discover versions and their content hashes from `build.zig.zon`, then read headers from `zig-pkg/{hash}/src/`.

## `resolver.lua` — Shared module

Parses `build.zig.zon` and returns version metadata. No external dependencies.

**Exports:**
- `join_path(...)` — cross-platform path joining
- `read_all(path)` — read entire file as string
- `split_lines(content)` — split text into lines (normalizes `\r\n`)
- `trim(text)` — trim leading/trailing whitespace
- `parse_build_zon(root)` — parse `build.zig.zon` and return a sorted table of:
  ```lua
  { name = "5.1.5", short = "5.1", hash = "N-V-__8..." }
  ```

**How it parses `build.zig.zon`:**
Scans for `.lua5X = .{ ... }` dependency blocks, extracts `.url` (to derive the version from the tarball filename) and `.hash` (to locate the unpacked sources under `zig-pkg/`). The zon format is simple enough that Lua patterns suffice — we match `%.(lua5%d)%s*=%s*%.%s*{[^}]*%.url%s*=%s*"([^"]*)"[^}]*%.hash%s*=%s*"([^"]*)"`.

## `analyze_public_apis.lua` → `apis.txt`

Parses four C headers from every Lua version and extracts every public symbol.

**Input:** `luaconf.h`, `lua.h`, `lauxlib.h`, `lualib.h` from `zig-pkg/{hash}/src/`

**Output:** `apis.txt` — each symbol listed with its full declaration text in every version where it appears:
```
- lua_absindex: lua.h
5.1.5:123:#define lua_absindex(L, i) ...
5.2.4:89:LUA_API int lua_absindex(lua_State *L, int idx);
```

**Key internal functions:**
- `parse_header(path, version, header, parsed)` — reads a header line by line, identifies `#define`/`#undef` directives and `*_API` function declarations
- `find_api_decl_symbol(declaration)` — extracts the API symbol name from a function declaration by finding the `lua_`/`luaL_` token before `(`
- `flatten_lines(lines, first, last, strip_backslash)` — joins multi-line `#define` continuations into a single string
- `build_master_order(all_data, bucket)` — builds a stable, cross-version ordering by inserting each symbol near its neighbors from the newest version
- `render_category(lines, title, all_data, bucket, order)` — formats the final output

## `analyze_api_stability.lua` → `base_apis.txt` + `diff_apis.txt`

Reads `apis.txt` and classifies each API by stability across versions.

**Output:**
- `base_apis.txt` — APIs where the *normalized declaration* is identical in every version. These are safe to bind without version guards.
- `diff_apis.txt` — APIs that differ between versions. Uses compact range notation:
  ```
  - lua_callk: 5.1, 5.2, >= 5.3
  ```

**Key internal functions:**
- `normalize_declaration(text)` — strips comments and normalizes whitespace so declarations can be compared
- `build_compare_declaration(text)` — further normalizes (removes parens, spaces) for exact comparison
- `is_base_api(entry)` — returns true if all 5 versions share the same normalized declaration
- `build_diff_summary(entry)` — groups versions by identical declaration, producing human-readable ranges like `5.1 == 5.2, >= 5.3`
- `format_group(versions)` — formats a single equivalence group (e.g., `>= 5.3` for contiguous-to-latest, or `5.1 == 5.2` for non-contiguous)

## Generated Files Format

### `apis.txt`
```
== LUA_ symbols ==
- LUA_MULTRET: luaconf.h, lua.h
5.1.5:42:#define LUA_MULTRET (-1)
...

== lua_ / luaL_ interfaces ==
- lua_absindex: lua.h
5.1.5:123:#define lua_absindex(L,i) ...
5.2.4:89:LUA_API int lua_absindex (lua_State *L, int idx);
```

### `base_apis.txt`
```
- lua_absindex
- lua_atpanic
- lua_call
```

### `diff_apis.txt`
```
- lua_callk: >= 5.2
- lua_dump: 5.1 == 5.2 == 5.3, >= 5.4
- lua_getiuservalue: >= 5.4
```
