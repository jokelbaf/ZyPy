const std = @import("std");
const zypy = @import("zypy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = zypy.addExtension(b, .{
        .name = "zypy_tests",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = zypy.addExtension(b, .{
        .name = "zypy_tests_single",
        .root_source_file = b.path("src/single.zig"),
        .target = target,
        .optimize = optimize,
    });
}
