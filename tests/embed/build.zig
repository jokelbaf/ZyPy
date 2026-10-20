const std = @import("std");
const zypy = @import("zypy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Programs that ship Python don't need an installed one, so they can be cross-compiled.
    if (b.option(bool, "bundle", "Build the program that ships Python") orelse false) {
        _ = zypy.addExecutable(b, .{
            .name = "bundled",
            .root_source_file = b.path("src/bundled.zig"),
            .target = target,
            .optimize = optimize,
            .bundle_python = true,
        });
    } else {
        _ = zypy.addExecutable(b, .{
            .name = "settings",
            .root_source_file = b.path("src/settings.zig"),
            .target = target,
            .optimize = optimize,
        });
        _ = zypy.addExecutable(b, .{
            .name = "threads",
            .root_source_file = b.path("src/threads.zig"),
            .target = target,
            .optimize = optimize,
        });
    }
}
