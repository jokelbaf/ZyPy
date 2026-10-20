const std = @import("std");
const zypy = @import("zypy");

pub fn build(b: *std.Build) void {
    const exe = zypy.addExecutable(b, .{
        .name = "embed",
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .bundle_python = b.option(bool, "bundle-python", "Ship Python with the program") orelse false,
    });

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the program").dependOn(&run.step);
}
