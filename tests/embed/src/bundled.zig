const std = @import("std");
const py = @import("zypy");

fn double(x: i64) i64 {
    return 2 * x;
}

const demo = py.module(.{ .functions = .{ .double = double } });

/// Print where the shipped Python is, and use the standard library and a Zig module.
pub fn main() !void {
    const interpreter = try py.Interpreter.init(.{ .modules = &.{.{ .name = "demo", .init = demo.init }} });
    defer interpreter.deinit();

    try py.run(
        \\import json, sys, demo
        \\print(sys.prefix, sys.executable, "%d.%d" % sys.version_info[:2], json.__file__, demo.double(21), sep="\n")
    );
}
