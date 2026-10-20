const py = @import("zypy");

fn answer() i64 {
    return 42;
}

fn readItems(list: py.List, rounds: usize) !void {
    for (0..rounds) |_| _ = try list.get(py.Object, 0);
}

pub const module = py.module(.{ .functions = .{ .answer = answer, .read_items = readItems } });

comptime {
    py.exportModule(module);
}
