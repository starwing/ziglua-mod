# ziglua-mod

Zig bindings for the Lua C API — write Lua C modules in pure Zig, without libc. Import as `lua`.

[![CI](https://github.com/starwing/ziglua-mod/actions/workflows/ci.yml/badge.svg)](https://github.com/starwing/ziglua-mod/actions/workflows/ci.yml)
[![Zig](https://img.shields.io/badge/Zig-master-orange.svg)](https://ziglang.org/)

EN | [中文](README.zh.md)

## Why?

**[ziglua](https://github.com/natecraddock/ziglua)** is a great project, but it's designed for *embedding* Lua into Zig programs — it always links a Lua runtime. When you're writing a Lua C module (a `.so`/`.dll` loaded by an existing Lua host), you don't need to embed a VM. You just need the API bindings.

`lua.zig` focuses on the C module use case:

- **No libc dependency** — pure Zig C modules. The Lua C API is declared via `@extern`, not C headers.
- **API closer to the C API** — method names match `lua_xxx` directly (e.g., `lua_geti` → `getI`).
- **ziglua-compatible aliases** — common functions keep their ziglua names (e.g., `getIndex` → `getI`), so migrating is smooth.
- **Cross-version compatibility** — one API across Lua 5.1–5.5. Version differences are handled at compile time.

## Features

- Supports **Lua 5.1, 5.2, 5.3, 5.4, 5.5** (plus LuaJIT, Luau)
- **All 63 tests pass on all 5 Lua versions**
- Comptime version dispatch — no runtime overhead
- Type-safe: enums instead of magic integers, optionals instead of null pointers, `bool` instead of `int`
- Cross-version API shims (e.g., `luaL_len` works on 5.1 even though it doesn't exist there)
- Optional embedded Lua mode (downloads & compiles Lua from source)
- Can also embed Lua if needed (static or shared linking)

## Getting Started

### Add as a dependency

```sh
zig fetch --save git+https://github.com/starwing/ziglua-mod
```

### Example: Lua C module in Zig

```zig
const lua = @import("lua");

export fn luaopen_mod(lua: *lua.State) callconv(.c) c_int {
    lua.newLib(&[_]lua.Reg{
        .{ .name = "add", .func = lAdd },
        .{ .name = "hello", .func = lHello },
    });
    return 1;
}

fn lAdd(L: *lua.State) callconv(.c) c_int {
    const a = L.checkInteger(1);
    const b = L.checkInteger(2);
    L.pushInteger(a + b);
    return 1;
}

fn lHello(L: *lua.State) callconv(.c) c_int {
    _ = L.pushString("Hello from Zig!");
    return 1;
}
```

Build with `build.zig`:

```zig
const LuaOptions = @import("lua").Options;

pub fn build(b: *std.Build) !void {
    const options = LuaOptions.init(b);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("lua", b.dependency("lua", options.toArgs()).module("lua"));

    const lib = b.addLibrary(.{
        .name = "mod",
        .root_module = mod,
        .linkage = .dynamic,
    });
    lib.linker_allow_shlib_undefined = true; // Lua symbols from the host
}
```

See [`examples/demo/`](examples/demo/) for a complete, buildable example.

### Build & Test

```sh
# Clone and test with system Lua
git clone https://github.com/starwing/ziglua-mod
cd ziglua-mod
zig build test --summary all

# Test with embedded Lua (auto-downloads source)
zig build test --summary all -Dembed=lua55

# Run the demo
cd examples/demo && zig build -Dstrip --release=fast
cd zig-out && lua test.lua
```

## API Overview

All Lua C API functions are methods on `*State`:

| Category         | Examples                                                                           |
| ---------------- | ---------------------------------------------------------------------------------- |
| Stack push       | `pushInteger`, `pushNumber`, `pushString`, `pushBoolean`, `pushNil`, `pushFString` |
| Stack access     | `toInteger`, `toNumber`, `toString`, `toBoolean`, `toPointer`                      |
| Type checks      | `isInteger`, `isNumber`, `isString`, `isFunction`, `checkInteger`, `checkString`   |
| Table access     | `getI` (lua_geti), `setI` (lua_seti), `rawGet`, `rawSet`, `getField`, `setField`   |
| Function calls   | `call`, `pcall`                                                                    |
| Module helpers   | `newLib`, `register`, `setFuncs`                                                   |
| State management | `init`, `deinit`, `status`, `version`                                              |

**Naming convention**: method names are derived from C API names by dropping the `lua_`/`luaL_` prefix and lowercasing:
- `lua_geti` → `getI`
- `luaL_len` → `len`
- `luaL_newlib` → `newLib`

**ziglua compatibility aliases**:
- `getIndex` → `getI`
- `setIndex` → `setI`
- `rawGetTable` → `rawGet`
- `rawSetTable` → `rawSet`
- `rawGetIndex` → `rawGetI`
- `rawSetIndex` → `rawSetI`
- `rawGetPtr` → `rawGetP`
- `rawSetPtr` → `rawSetP`

## Build Options

| Option          | Values                            | Default | Description                        |
| --------------- | --------------------------------- | ------- | ---------------------------------- |
| `-Dlang`        | `lua51`–`lua55`, `luajit`, `luau` | `lua55` | Target Lua version                 |
| `-Dembed`       | same as `-Dlang`                  | (none)  | Download & compile Lua from source |
| `-Dshared`      | `bool`                            | `false` | Build Lua as shared library        |
| `-D32bit`       | `bool`                            | `false` | Use 32-bit integers (lua53/lua55)  |
| `-Dtest-filter` | `string`                          | (none)  | Filter test names                  |

## Compared to ziglua

|                      | **ziglua-mod**     | **ziglua**                        |
| -------------------- | ------------------ | --------------------------------- |
| Primary use case     | Lua C modules      | Embedding Lua                     |
| libc dependency      | Not required       | Required (compiles Lua C sources) |
| API naming           | Close to C API     | Zig-idiomatic                     |
| ziglua compat        | Aliases provided   | —                                 |
| Cross-version compat | Compile-time shims | Compile-time dispatch             |
| Embedded Lua         | Optional           | Primary mode                      |
| Zig version          | master             | master (0.15.2 branch available)  |

If you're embedding Lua into a Zig program, ziglua may be a better fit. If you're writing Lua modules in Zig, `ziglua-mod` is purpose-built for that.

## AI Usage

The core idea was sparked by a [Ziggit discussion](https://ziggit.dev/t/question-about-declaration-level-metaprogramming-generating-aliases-from-reflected-decls/15149) on compile-time alias generation from reflected declarations. The initial framework was written by hand, then the remaining API surface — filling in `tests.zig` coverage and multi-version Lua support — was implemented with **Claude Code + DeepSeek V4 Pro**, under manual review. Subsequent refactoring and optimization were done manually.

AI tools are welcome when contributing to this project, but two rules apply: **every line must be human-reviewed**, and complex logic should be grounded by a person — AI drifts fast when left alone.

## License

MIT
