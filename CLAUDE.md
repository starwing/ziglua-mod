# CLAUDE.md

Zig bindings for the Lua C API. Supports LuaJIT, Luau, and Lua 5.1–5.5 with compile-time version dispatch.

## Build & Test

```sh
# Default test (system Lua, lang=lua55)
zig build test --summary all

# Test with embedded Lua (auto-downloads source)
zig build test --summary all -Dembed=lua55

# Test with specific version / filter
zig build test --summary all -Dlang=lua54
zig build test --summary all -Dtest-filter="test name"

# Demo (standalone project)
cd examples/demo && zig build -Dstrip --release=fast && cd zig-out && lua test.lua
```

Shortcuts via `just`: `just t`, `just t-embed lua51`, `just t-lua55`, `just t-all`, `just demo`.

### Build Options

| Option          | Values                            | Default | Notes                              |
| --------------- | --------------------------------- | ------- | ---------------------------------- |
| `-Dlang`        | `luajit`, `luau`, `lua51`–`lua55` | `lua55` | Target Lua version                 |
| `-Dembed`       | same as `-Dlang`                  | (none)  | Download & compile Lua from source |
| `-Dshared`      | `bool`                            | `false` | Build Lua as shared library        |
| `-D32bit`       | `bool`                            | `false` | 32-bit integers (lua53/lua55 only) |
| `-Dluadef`      | flags                             | (none)  | Extra C defines for Lua compiler   |
| `-Dtest-filter` | string                            | (none)  | Filter test names                  |

## Files

| Path             | Purpose                                                                                        |
| ---------------- | ---------------------------------------------------------------------------------------------- |
| `src/lua.zig`    | All C API bindings on `*State` opaque type                                                     |
| `src/tests.zig`  | Test suite with comptime version guards                                                        |
| `build.zig`      | Build system, `Options`/`Lang` types, optional Lua embedding                                   |
| `build.zig.zon`  | Package manifest with lazy URL deps for 5 Lua versions                                         |
| `apis.txt`       | Every `LUA_`/`lua_`/`luaL_` declaration per version — **search this first for API signatures**. If missing, see [binding-guide](.claude/binding-guide.md) to generate. |
| `base_apis.txt`  | APIs identical across all versions                                                             |
| `diff_apis.txt`  | APIs that vary between versions                                                                |
| `examples/demo/` | Standalone demo: Zig → .so → loaded by Lua                                                     |
| `scripts/`       | Generate apis/base/diff files from Lua headers                                                 |

## Key Docs

- [`.claude/architecture.md`](.claude/architecture.md) — `src/lua.zig` and `build.zig` internals
- [`.claude/binding-guide.md`](.claude/binding-guide.md) — how to bind new APIs, naming, patterns, pitfalls
- [`scripts/CLAUDE.md`](scripts/CLAUDE.md) — API analysis script details
