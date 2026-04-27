const std = @import("std");

const LuaOptions = @import("lua").Options;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = LuaOptions.init(b);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
        .strip = b.option(
            bool,
            "strip",
            "Strip symbols from the library",
        ) orelse false,
    });
    mod.addImport("lua", b.dependency("lua", options.toArgs()).module("lua"));

    const lib = b.addLibrary(.{
        .name = "mod",
        .root_module = mod,
        .linkage = .dynamic,
    });
    lib.out_filename = if (target.result.os.tag == .windows) "mod.dll" else "mod.so";
    lib.linker_allow_shlib_undefined = true;

    const step = b.getInstallStep();
    step.dependOn(&b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .prefix },
    }).step);
    step.dependOn(&b.addInstallFile(b.path("test.lua"), "test.lua").step);
}
