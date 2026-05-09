const std = @import("std");
const print = std.debug.print;

pub const Lang = enum {
    luajit,
    luau,
    lua51,
    lua52,
    lua53,
    lua54,
    lua55,

    pub fn in(self: @This(), comptime values: anytype) bool {
        inline for (values) |v| {
            if (self == v) return true;
        }
        return false;
    }
};

pub const Options = struct {
    lang: Lang = .lua55,
    embed: bool = false,
    is32bit: bool = false,
    shared: bool = false,

    pub fn init(b: *std.Build) Options {
        const embed_lang = b.option(Lang, "embed", "Embedded Lua version");
        return Options{
            .embed = embed_lang != null,
            .lang = embed_lang orelse b.option(Lang, "lang", "Lua version to target") orelse .lua55,
            .is32bit = b.option(bool, "32bit", "Use 32-bit integers for Lua") orelse false,
            .shared = b.option(bool, "shared", "Build Lua as a shared library") orelse false,
        };
    }

    pub fn toArgs(self: @This()) Args {
        return .{
            .embed = if (self.embed) self.lang else null,
            .lang = self.lang,
            .@"32bit" = self.is32bit,
            .shared = self.shared,
        };
    }

    const Args = struct {
        embed: ?Lang,
        lang: ?Lang,
        @"32bit": ?bool,
        shared: ?bool,
    };
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = Options.init(b);
    if (options.is32bit) {
        if (options.lang.in(.{ .lua51, .lua52, .luajit, .luau })) {
            print("Lua 5.1, 5.2, LuaJIT and Luau do not support 32-bit integers.\n", .{});
            std.process.exit(2);
        }
        // Lua 5.4 predefined LUA_32BITS in luaconf.h, can not changed by flags
        if (options.embed and options.lang == .lua54) {
            print("Lua 5.4 does not support 32-bit integers when embedded.\n", .{});
            std.process.exit(2);
        }
    }
    const lib_mod = b.addModule("lua", .{
        .root_source_file = b.path("src/lua.zig"),
        .target = target,
        .optimize = optimize,
    });
    const config = b.addOptions();
    inline for (@typeInfo(Options).@"struct".fields) |f|
        config.addOption(f.type, f.name, @field(options, f.name));
    lib_mod.addOptions("config", config);
    if (options.embed)
        lib_mod.linkLibrary(try setupLua(b, options, target, optimize))
    else
        lib_mod.linkSystemLibrary("lua", .{});
    try setupTestStep(b, target, optimize);
}

fn setupTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
) !void {
    const tests = b.addTest(.{
        .name = "test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lua.zig", .module = b.modules.get("lua").? },
            },
        }),
        .filters = b.option(
            []const []const u8,
            "test-filter",
            "Skip tests that do not match filters",
        ) orelse &.{},
    });
    const test_step = b.step("test", "Run Lua tests");
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}

fn setupLua(
    b: *std.Build,
    options: Options,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
) !*std.Build.Step.Compile {
    const lang_name = @tagName(options.lang);
    const lua_dep = b.lazyDependency(lang_name, .{}) orelse {
        std.log.err("Lazy dependency '{s}' not available", .{lang_name});
        return error.DependencyNotAvailable;
    };
    const src_path = lua_dep.path("src");

    const mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addIncludePath(src_path);

    // Common compile flags for Lua
    var flags = try std.ArrayList([]const u8).initCapacity(b.allocator, 4);
    defer flags.deinit(b.allocator);

    for (b.option(
        []const []const u8,
        "luadef",
        "Additional defines to pass to Lua",
    ) orelse &.{}) |def| {
        try flags.append(b.allocator, def);
    }
    switch (target.result.os.tag) {
        .windows => {
            try flags.append(b.allocator, "-DLUA_USE_WINDOWS");
            if (options.shared) try flags.append(b.allocator, "-DLUA_BUILD_AS_DLL");
        },
        .linux => try flags.append(b.allocator, "-DLUA_USE_LINUX"),
        .macos => try flags.append(b.allocator, "-DLUA_USE_MACOSX"),
        else => {},
    }
    if (options.is32bit) try flags.append(b.allocator, "-DLUA_32BITS");

    for (sourcesFor(options.lang)) |src| {
        mod.addCSourceFile(.{
            .file = src_path.path(b, src),
            .flags = flags.items,
        });
    }

    return b.addLibrary(.{
        .name = "lua",
        .root_module = mod,
        .linkage = if (options.shared) .dynamic else .static,
    });
}

fn sourcesFor(lang: Lang) []const []const u8 {
    return switch (lang) {
        .lua51 => &src_51,
        .lua52 => &src_52,
        .lua53 => &src_53,
        .lua54 => &src_54,
        .lua55 => &src_55,
        else => unreachable,
    };
}

const src_base = [_][]const u8{
    "lapi.c",    "lauxlib.c", "lbaselib.c", "lcode.c",    "ldblib.c",
    "ldebug.c",  "ldo.c",     "ldump.c",    "lfunc.c",    "lgc.c",
    "linit.c",   "liolib.c",  "llex.c",     "lmathlib.c", "lmem.c",
    "loadlib.c", "lobject.c", "lopcodes.c", "loslib.c",   "lparser.c",
    "lstate.c",  "lstring.c", "lstrlib.c",  "ltable.c",   "ltablib.c",
    "ltm.c",     "lundump.c", "lvm.c",      "lzio.c",
};

const src_51 = src_base ++ .{"print.c"};
const src_52 = src_base ++ .{ "lctype.c", "lcorolib.c", "lbitlib.c" };
const src_53 = src_52 ++ .{"lutf8lib.c"};
const src_54 = src_base ++ .{ "lctype.c", "lcorolib.c", "lutf8lib.c" };
const src_55 = src_54;
