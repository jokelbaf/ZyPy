const std = @import("std");
const py = @import("zypy");

fn add(a: i64, b: i64) !i64 {
    return std.math.add(i64, a, b);
}

fn greet(name: py.Str, greeting: py.Str) !py.Str {
    var buffer: [256]u8 = undefined;
    const text = std.mem.print(&buffer, "{s}, {s}!", .{ try greeting.utf8(), try name.utf8() }) catch {
        return py.raise(.ValueError, "name is too long");
    };
    return py.Str.init(text);
}

fn sum(numbers: py.Iterator(f64)) !f64 {
    var total: f64 = 0;
    while (try numbers.next()) |number| total += number;
    return total;
}

fn countWords(words: py.Iterator(py.Object)) !py.Dict {
    const counts = try py.Dict.init();
    errdefer counts.deinit();

    while (try words.next()) |word| {
        const n = try counts.get(i64, word) orelse 0;
        try counts.set(word, n + 1);
    }
    return counts;
}

pub const module = py.module(.{
    .doc = "A Python module written in Zig.",
    .functions = .{
        .add = py.function(add, .{ .doc = "Add two numbers." }),
        .greet = py.function(greet, .{
            .doc = "Greet someone by name.",
            .params = &.{ "name", "greeting" },
            .defaults = .{ .greeting = "Hello" },
        }),
        .sum = py.function(sum, .{ .doc = "Sum any iterable of numbers." }),
        .count_words = py.function(countWords, .{ .doc = "Count how often each word occurs." }),
    },
});

comptime {
    py.exportModule(module);
}
