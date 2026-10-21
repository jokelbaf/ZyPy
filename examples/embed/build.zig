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

    // Run the installed copy so bundled Python can be found in ../lib.
    const run = std.Build.Step.Run.create(b, "run embed");
    run.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = exe.out_filename } });
    run.addPassthruArgs();
    run.step.dependOn(b.getInstallStep());

    b.step("run", "Run the program").dependOn(&run.step);
}
