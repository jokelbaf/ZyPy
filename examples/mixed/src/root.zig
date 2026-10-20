const py = @import("zypy");

fn mean(numbers: py.Iterator(f64)) !f64 {
    var total: f64 = 0;
    var count: usize = 0;
    while (try numbers.next()) |number| {
        total += number;
        count += 1;
    }
    if (count == 0) return py.raise(.ValueError, "mean of an empty sequence");
    return total / @as(f64, @floatFromInt(count));
}

pub const module = py.module(.{
    .doc = "The fast parts of mixed, written in Zig.",
    .functions = .{
        .mean = py.function(mean, .{ .doc = "Get the arithmetic mean of numbers." }),
    },
});

comptime {
    py.exportModule(module);
}
