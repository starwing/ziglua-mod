# ziglua-mod

Lua C API 的 Zig 绑定 — 用纯 Zig 编写 Lua C 模块，不依赖 libc。导入名 `lua`。

[![CI](https://github.com/starwing/ziglua-mod/actions/workflows/ci.yml/badge.svg)](https://github.com/starwing/ziglua-mod/actions/workflows/ci.yml)
[![Zig](https://img.shields.io/badge/Zig-master-orange.svg)](https://ziglang.org/)

[EN](README.md) | 中文

## 动机

**[ziglua](https://github.com/natecraddock/ziglua)** 是一个优秀的项目，但它是为在 Zig 程序中*嵌入* Lua 运行时设计的——始终需要链接一个 Lua VM。当你编写 Lua C 模块（由现有 Lua 宿主加载的 `.so`/`.dll`）时，根本不需要嵌入 VM，只需要 API 绑定。

`lua.zig` 专注于 C 模块的编写场景：

- **无 libc 依赖** — 纯 Zig 编写 C 模块。Lua C API 通过 `@extern` 声明，而非引入 C 头文件。
- **API 更贴近 C API** — 方法名直接对应 `lua_xxx`（如 `lua_geti` → `getI`）。
- **ziglua 兼容别名** — 常用函数保留了 ziglua 的命名（如 `getIndex` → `getI`），迁移无障碍。
- **跨版本兼容** — 一套 API 覆盖 Lua 5.1–5.5。版本差异在编译期处理。

## 特性

- 支持 **Lua 5.1、5.2、5.3、5.4、5.5**（以及 LuaJIT、Luau）
- **全部 5 个 Lua 版本通过 63/63 项测试**
- 编译期版本分发 — 零运行时开销
- 类型安全：枚举替代魔术数字，optional 替代空指针，`bool` 替代 `int`
- 跨版本 API 兼容层（如 `luaL_len` 在 5.1 上也可用，尽管原生不存在）
- 可选的嵌入 Lua 模式（自动下载并编译 Lua 源码）
- 必要时也可以嵌入 Lua（支持静态或动态链接）

## 快速开始

### 添加依赖

```sh
zig fetch --save git+https://github.com/starwing/ziglua-mod
```

### 示例：用 Zig 编写 Lua C 模块

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

在 `build.zig` 中构建：

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
    lib.linker_allow_shlib_undefined = true; // Lua 符号由宿主提供
}
```

完整可运行的示例见 [`examples/demo/`](examples/demo/)。

### 构建和测试

```sh
# 克隆并使用系统 Lua 测试
git clone https://github.com/starwing/ziglua-mod
cd ziglua-mod
zig build test --summary all

# 使用嵌入 Lua 测试（自动下载源码）
zig build test --summary all -Dembed=lua55

# 运行示例
cd examples/demo && zig build -Dstrip --release=fast
cd zig-out && lua test.lua
```

## API 概览

所有 Lua C API 函数都是 `*State` 上的方法：

| 分类     | 示例                                                                               |
| -------- | ---------------------------------------------------------------------------------- |
| 栈压入   | `pushInteger`、`pushNumber`、`pushString`、`pushBoolean`、`pushNil`、`pushFString` |
| 栈访问   | `toInteger`、`toNumber`、`toString`、`toBoolean`、`toPointer`                      |
| 类型检查 | `isInteger`、`isNumber`、`isString`、`isFunction`、`checkInteger`、`checkString`   |
| 表操作   | `getI`（lua_geti）、`setI`（lua_seti）、`rawGet`、`rawSet`、`getField`、`setField` |
| 函数调用 | `call`、`pcall`                                                                    |
| 模块辅助 | `newLib`、`register`、`setFuncs`                                                   |
| 状态管理 | `init`、`deinit`、`status`、`version`                                              |

**命名规则**：方法名从 C API 名称中去掉 `lua_`/`luaL_` 前缀并小写化：
- `lua_geti` → `getI`
- `luaL_len` → `len`
- `luaL_newlib` → `newLib`

**ziglua 兼容别名**：
- `getIndex` → `getI`
- `setIndex` → `setI`
- `rawGetTable` → `rawGet`
- `rawSetTable` → `rawSet`
- `rawGetIndex` → `rawGetI`
- `rawSetIndex` → `rawSetI`
- `rawGetPtr` → `rawGetP`
- `rawSetPtr` → `rawSetP`

## 构建选项

| 选项            | 值                                | 默认值  | 说明                          |
| --------------- | --------------------------------- | ------- | ----------------------------- |
| `-Dlang`        | `lua51`–`lua55`、`luajit`、`luau` | `lua55` | 目标 Lua 版本                 |
| `-Dembed`       | 同 `-Dlang`                       | （无）  | 下载并编译 Lua 源码           |
| `-Dshared`      | `bool`                            | `false` | 以动态库形式构建 Lua          |
| `-D32bit`       | `bool`                            | `false` | 使用 32 位整数（lua53/lua55） |
| `-Dtest-filter` | `string`                          | （无）  | 过滤测试名称                  |

## 与 ziglua 的比较

|             | **ziglua-mod** | **ziglua**               |
| ----------- | -------------- | ------------------------ |
| 主要用途    | Lua C 模块     | 嵌入 Lua                 |
| libc 依赖   | 不需要         | 必需（编译 Lua C 源码）  |
| API 命名    | 贴近 C API     | Zig 风格                 |
| ziglua 兼容 | 提供别名       | —                        |
| 跨版本兼容  | 编译期兼容层   | 编译期分发               |
| 嵌入 Lua    | 可选           | 主要模式                 |
| Zig 版本    | master         | master（有 0.15.2 分支） |

如果你需要在 Zig 程序中嵌入 Lua，ziglua 可能更适合。如果你在用 Zig 编写 Lua 模块，`ziglua-mod` 就是为此场景设计的。

## AI 使用说明

核心灵感来自 [Ziggit 上的讨论](https://ziggit.dev/t/question-about-declaration-level-metaprogramming-generating-aliases-from-reflected-decls/15149)，关于通过反射 declarations 在编译期生成别名。初始框架为手写，后续的 API 补全、`tests.zig` 覆盖以及多版本 Lua 适配通过 **Claude Code + DeepSeek V4 Pro** 实现，人工审核后合入。此后的重构和代码优化均为人工完成。

本项目欢迎使用 AI 工具参与贡献，但有两个原则：**每一行代码都必须经过人工审核**，复杂逻辑需要人工托底——AI 无人看管时很容易跑偏。

## 许可

MIT
