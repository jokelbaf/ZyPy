const std = @import("std");
const py = @import("zypy");
const c = py.c;

fn add(a: i64, b: i64) !i64 {
    return std.math.add(i64, a, b);
}

const Greeter = struct {
    name: py.Owned(py.Str),

    pub const class = py.class(.{
        .doc = "Greet someone by name.",
        .methods = .{ .greet = greet },
    });

    fn greet(self: *const Greeter) !py.Str {
        var buffer: [256]u8 = undefined;
        return py.Str.init(try std.mem.print(&buffer, "Hello, {s}!", .{try self.name.get().utf8()}));
    }
};

const demo = py.module(.{
    .doc = "Functions and classes provided by the Zig program.",
    .functions = .{
        .add = py.function(add, .{ .doc = "Add two numbers." }),
    },
    .classes = .{ .Greeter = Greeter },
    // ZyPy locks each Greeter while its methods run without the GIL.
    .free_threaded = true,
});

pub fn main(init: std.process.Init) !void {
    const interpreter = try py.Interpreter.init(.{
        .modules = &.{.{ .name = "demo", .init = demo.init }},
        .executable = py.build_python,
        .argv = try init.minimal.args.toSlice(init.arena.allocator()),
    });
    defer interpreter.deinit();

    run() catch |err| {
        if (err == error.PythonError) c.PyErr_Print();
        return err;
    };
}

fn run() !void {
    // Call Python from Zig by passing a dict to json.dumps.
    const user = try py.Dict.init();
    defer user.deinit();

    try user.set("name", "Ann");
    try user.set("scores", [_]f64{ 9.5, 7.0 });

    const json = try py.import("json");
    defer json.deinit();

    const text = try json.callMethodKw(py.Str, "dumps", .{user}, .{ .sort_keys = true });
    defer text.deinit();

    std.debug.print("json.dumps: {s}\n", .{try text.utf8()});

    // Run Python code that imports the Zig module defined above.
    try py.run(
        \\import sys
        \\import demo
        \\print("sys.argv:", sys.argv[1:], flush=True)
        \\print("demo.add:", demo.add(2, 3), flush=True)
        \\print("demo.Greeter:", demo.Greeter("Ann").greet(), flush=True)
    );
    std.debug.print("py.eval: {d}\n", .{try py.eval(i64, "demo.add(40, 2)")});

    // Use Python from another thread, releasing the GIL while waiting for it.
    const thread = try std.Thread.spawn(.{}, greetFromThread, .{});
    py.allowThreads(std.Thread.join, .{thread});
}

fn greetFromThread() void {
    const gil = py.Gil.acquire();
    defer gil.release();

    py.run("print('from a Zig thread:', demo.Greeter('Bo').greet(), flush=True)") catch c.PyErr_Print();
}
