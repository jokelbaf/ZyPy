const std = @import("std");
const zypy = @import("zypy");

pub fn build(b: *std.Build) void {
    _ = zypy.addExtension(b, .{
        // A submodule of the Python package in python/mixed.
        .name = "mixed._core",
        .root_source_file = b.path("src/root.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
}
