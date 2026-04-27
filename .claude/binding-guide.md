# Binding Guide

How to bind Lua C API functions in `src/lua.zig`, end to end.

## Process

### 1. Find the C API signature

Search `apis.txt` across all versions:

```sh
grep -A6 "\- lua_xxx:" apis.txt
```

Each line is `<version>:<line>:<declaration>`. Pay attention to whether the signature **differs across versions** — also check `diff_apis.txt`. If the API is a **macro** (`#define`), call the underlying C function instead (e.g., `luaL_checkstring` wraps `luaL_checklstring`).

If `apis.txt` is missing or stale, first make sure the Lua source tarballs have been downloaded (the scripts read headers from `zig-pkg/{hash}/src/`):
```sh
zig build -Dembed=lua55   # downloads all 5 Lua tarballs to zig-pkg/
lua scripts/analyze_public_apis.lua      # → apis.txt
lua scripts/analyze_api_stability.lua     # → base_apis.txt, diff_apis.txt
```

### 2. Determine if new types are needed

If the API uses structs, enums, or constants not yet in `lua.zig`, check the Lua headers:

```sh
grep -r "struct lua_Debug" zig-pkg/*/src/lua.h
```

Version-specific structs (like `lua_Debug`) need comptime-gated `extern struct` definitions.

### 3. Handle compile-time configuration

If the API involves `#ifdef` / configurable constants (e.g., `LUAI_MAXSTACK`), check `zig-pkg/*/src/luaconf.h` for the default values. Add a build option to `build.zig` if the user might need to customize it.

### 4. Read the Lua documentation

```sh
ls zig-pkg/*/doc/contents.html   # find the doc path for the target version
```

If the API was removed in 5.5, use the latest version that still has it. Extract the description and note the `[-n,+n,x]` stack effect.

### 5. Implement

**Placement**: Simple types/functions before `State`. Complex structs after `State`. Within `State`, follow lua.h order: setup → stack → access → compare/arith → push → get → set → load/call → misc → debug → aux.

**Return types**:
- Lua longjmp (no error code) → suffix with `RaiseErr`, no error union
- C returns error code → Zig `Error!void` (with `Error!void => c_int` in TypeMap)
- C returns pointer that may be null → `?*T`
- String-to-enum conversion → `std.meta.stringToEnum`

**Auto-mapping priority** (try in this order):
1. Method name lowercased matches C function (after stripping `lua_`/`luaL_`) → auto-maps via `api()` — no specialApiTypes needed
2. Signature differs but type mapping can fix it → add to `TypeMap`
3. Naming doesn't match but signature does → add to `specialApiTypes` with `@TypeOf`
4. Different param count / comptime params → add to `specialApiTypes` with `fn(...)`
5. Different versions have different signatures → use `@extern` directly

### 6. Verify

```sh
zig build test --summary all -Dlang=lua55
```

Fix any compilation errors. Tests in `tests.zig` may need adaptation if the new API changes existing signatures.

## Naming

- Match C API names directly; only rename for Zig keyword conflicts or collisions
- `lua_xxx` base functions → method name `xxx` (e.g., `lua_len` → `len`)
- `luaL_xxx` aux functions → may need suffix if naming collides (e.g., `luaL_setmetatable` → `setMetatableRegistry`)
- Blind variants: `xxxBlind` (no return value; e.g., `pushSliceBlind`)
- X variants: `xxxX` (with extra parameters; e.g., `loadFileX`)

## Code Patterns

- `comptime lang.in(.{ .lua51, .luajit })` — version check for multiple targets
- Comptime struct wrappers for C callbacks (see `hookFn`)
- `fromRaw` should only read fields requested by `what` parameter
- `@intFromPtr` for pointer arithmetic on ARM64
- `std.mem.zeroes` for extern struct initialization
- Return `void` can use `return api(...)` pattern

## GC Functions

- `gcOp` defined as per-version enum (module level, near `Status`)
- Common ops (stop/restart/collect/count/countb/step) have default numbering
- 5.4-specific ops (isrunning=9, gen=10, inc=11) need explicit values
- `gcSetPause`/`gcSetStepMul` use `gcOp.setpause`/`gcOp.setstepmul`
- Lua 5.4/5.5: LUA_GCGEN/LUA_GCINC always return non-zero (previous mode)
- Lua 5.5: no longer takes parameters for gen/inc

## DebugInfo

- `DebugInfo.Raw` is an `extern struct` matching C `lua_Debug` layout per version
- All `Raw` variants must include `_ci` field (even Lua 5.1 has `_ci: c_int`)
- `getStack` zero-initializes raw, `getInfo` passes `what` to `fromRaw`
- `getLocal`/`setLocal` construct a temporary `Raw` with `_ci` from `DebugInfo`
- `CHookFn` type: `fn(*State, Event, *DebugInfo) callconv(.c) void`
- `hookFn(comptime f)` wraps user function into C-compatible `lua_Hook`

## SpecialApiTypes

Override map for functions where auto-mapping fails. Lua 5.1-specific entries are grouped separately with `++ .{ ... }`:

```zig
const specialApiTypes = std.StaticStringMap(type).initComptime(&([_]struct { []const u8, type }{
    // ... main entries ...
}) ++ .{ // Lua 5.1 compat
    .{ "luaL_loadbuffer", fn (*State, [*]const u8, usize, c_str) c_int },
    .{ "lua_tonumber", fn (*State, i32) Number },
    .{ "lua_tointeger", fn (*State, i32) Integer },
    .{ "lua_objlen", fn (*State, i32) usize },
    .{ "lua_setfenv", fn (*State, i32) c_int },
    .{ "lua_getfenv", fn (*State, i32) void },
});
```

## Common Pitfalls

- `anytype` in specialApiTypes creates varargs C function; `@as()` needed for literal args
- `[*:null]c_str` doesn't work as array element type — use `?c_str`
- Non-pointer optionals (`?f64`, `?i64`) can't be returned from inline functions on ARM64 — ensure return types are in specialApiTypes
- The `_` sentinel can only appear once in an enum (at the end)
- `lang.atLeast()` mixed with runtime `what.X` in `if` condition can't guard field access — use comptime-only guard
- NEVER use `Write` tool — only `Edit` for existing files in this project
