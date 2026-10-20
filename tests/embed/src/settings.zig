const std = @import("std");
const py = @import("zypy");

/// Start Python with the home directory from the first argument and print the resulting settings.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const interpreter = try py.Interpreter.init(.{
        .executable = py.build_python,
        .home = args[1],
        .argv = args[2..],
        .search_paths = &.{ "/zypy/first", "/zypy/second" },
        .site = false,
    });
    defer interpreter.deinit();

    try py.run(
        \\import sys
        \\print(sys.base_prefix, sys.path[:2], "site" in sys.modules, sys.argv, sep="\n")
    );
}
