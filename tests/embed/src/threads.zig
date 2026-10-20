const std = @import("std");
const py = @import("zypy");

const Tally = struct {
    count: i64 = 0,

    pub const class = py.class(.{ .fields = .{ .count = .read_only }, .methods = .{ .add = add } });

    fn add(self: *Tally, amount: i64) void {
        self.count += amount;
    }
};

const shared = py.module(.{ .classes = .{ .Tally = Tally }, .free_threaded = true });

const threads = 4;
const rounds = 2000;

/// Print GIL status, the final count, and references retained after scoped reads.
pub fn main() !void {
    const interpreter = try py.Interpreter.init(.{
        .modules = &.{.{ .name = "shared", .init = shared.init }},
        .executable = py.build_python,
    });
    defer interpreter.deinit();

    try py.run(
        \\import shared, sys
        \\tally = shared.Tally()
        \\words = [f"word{i:02}" for i in range(64)]
    );

    var workers: [threads]std.Thread = undefined;
    for (&workers, 0..) |*worker, i| worker.* = try std.Thread.spawn(.{}, work, .{i});
    for (workers) |worker| py.allowThreads(std.Thread.join, .{worker});

    try py.run("print(sys._is_gil_enabled(), tally.count)");
    try readInScopes();
}

fn readInScopes() !void {
    const words = try py.eval(py.List, "words");
    defer words.deinit();

    const before = try py.eval(i64, "sys.getrefcount(words[0])");
    for (0..rounds) |_| {
        const scope: py.BorrowScope = .begin();
        defer scope.end();

        _ = try words.get(py.Str, 0);
    }
    const after = try py.eval(i64, "sys.getrefcount(words[0])");

    const main_module = try py.import("__main__");
    defer main_module.deinit();

    try main_module.setAttr("held", after - before);
    try py.run("print(held)");
}

fn work(index: usize) void {
    const gil = py.Gil.acquire();
    defer gil.release();

    count(index) catch py.c.PyErr_Print();
}

fn count(index: usize) !void {
    const tally = try py.eval(py.Object, "tally");
    defer tally.deinit();
    const words = try py.eval(py.List, "words");
    defer words.deinit();

    for (0..rounds) |i| {
        // Release each round's reads, which would otherwise stay until the thread releases the GIL.
        const scope: py.BorrowScope = .begin();
        defer scope.end();

        try tally.callMethod(void, "add", .{1});
        const word = try words.get(py.Str, (i + index) % 64);
        const replacement = try py.Str.init(if (i % 2 == 0) "even" else "odd");
        defer replacement.deinit();

        try words.set((i + index + 1) % 64, replacement);
        if ((try word.utf8()).len == 0) return error.EmptyWord;
    }
}
