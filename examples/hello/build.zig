const std = @import("std");
const zypy = @import("zypy");

pub fn build(b: *std.Build) void {
    _ = zypy.addExtension(b, .{
        .name = "hello",
        .root_source_file = b.path("src/root.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
}
