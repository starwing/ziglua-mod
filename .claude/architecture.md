# Architecture

Internal design of `src/lua.zig` and `build.zig`. For usage, examples, and build commands, see the root `CLAUDE.md`.

## `src/lua.zig` — Core bindings (~2300 lines)

All Lua C API bindings in a single file.

### State type

`State` is `opaque {}` — all C API functions are `pub inline fn` methods on it. State contains ONLY functions; enums and constants go at module level.

### Comptime version dispatch

`lang` (imported from `config`) is a comptime-known enum with helpers:
- `lang.atLeast(min)` / `lang.between(min, max)` — range checks
- `lang.eql(other)` / `lang.in(.{ ... })` — equality / set membership
- `lang.num()` — returns numeric version (501 for 5.1, etc.)

Number, Integer, Unsigned types resolve at comptime based on `lang` and `is32bit`.

### `api()` function

Resolves C function pointers at compile time via `@extern`. Maps Zig method names to C API names by lowercasing and prepending `lua_` or `luaL_`.

`apiMap` (a `StaticStringMap`) is built from `State`'s declarations at compile time. For each `pub` declaration on `State`, the name is lowercased; if it matches a C function name (after stripping `lua_`/`luaL_`), it auto-maps.

### Auto-mapping priority

1. Method name lowercased matches C function → auto-maps via `api()` — no config needed
2. Signature differs but type mapping can fix it → add to `TypeMap`
3. Naming doesn't match but signature does → add to `specialApiTypes` with `@TypeOf`
4. Different param count / comptime params → add to `specialApiTypes` with `fn(...)`
5. Different versions have different signatures → use `@extern` directly

### `DeclType()`

Wraps Zig fn types into `*const fn(...) callconv(.c) ...` pointers. The last param `anytype` triggers `.varargs = true`.

### `TypeMap()`

Converts Zig types to C-compatible types: `bool => c_int`, `*DebugInfo => *DebugInfo.Raw`, etc.

### `specialApiTypes`

Override `StaticStringMap` for functions where auto-mapping fails. Lua 5.1 compat entries are grouped at the end with `++ .{ ... }`.

### `notAvail(name)`

Shorthand for `@compileError("name is not available in Lua ...")`.

## `build.zig` — Build system

### Public types

- **`Lang` enum** — `luajit`, `luau`, `lua51`–`lua55`. Has `.in()` helper.
- **`Options` struct** — `lang`, `embed`, `is32bit`, `shared`. Parsed via `Options.init(b)`. Exposes `toArgs()` for downstream consumers.

### Module setup

`lib_mod` is the `"lua"` module from `src/lua.zig`. A `config` options module is injected with the resolved options.

### System Lua (default)

`lib_mod.linkSystemLibrary("lua")` — no download, no compilation.

### Embedded Lua (`-Dembed=<lang>`)

`setupLua()` calls `b.lazyDependency()` to download the matching tarball (declared in `build.zig.zon` as lazy URL deps), then compiles all `.c` sources via `b.addLibrary()`.

`sourcesFor(lang)` returns the correct `.c` file list per version (base set ± version-specific files).

### Guards

- 32-bit: `lua51`/`lua52`/`luajit`/`luau` reject `-D32bit`; `lua54` rejects it in embedded mode.

### Test step

`setupTestStep()` creates the test binary from `src/tests.zig`, imports the `"lua"` module, wires up `test-filter`.

## `src/tests.zig` — Test suite

Uses `comptime` guards to skip tests that don't apply to the current Lua version.

## `examples/demo/` — Standalone demo project

An independent Zig project under `examples/demo/` that shows how to depend on this package:

- **`build.zig.zon`** — Declares `lua` as a `path` dependency pointing to `../..`
- **`build.zig`** — Imports `LuaOptions`, calls `b.dependency("lua", options.toArgs()).module("lua")`, builds `src/mod.zig` as a shared library with `linker_allow_shlib_undefined = true`
- **`src/mod.zig`** — 6 demo functions (`add`, `hello`, `error`, `call`, `callret1`, `getzig`) registered via `newLib`
- **`test.lua`** — Loads `mod.so` and exercises each function
