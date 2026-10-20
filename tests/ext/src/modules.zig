const std = @import("std");
const py = @import("zypy");

const Point = @import("classes.zig").Point;

pub const State = struct {
    calls: u64 = 0,
    version: py.Owned(py.Str),
    cache: py.Owned(py.Dict),
    last: py.Owned(?py.Object) = .init(null),
    released: bool = false,

    pub fn init(this: py.Object) !State {
        const version = try this.getAttr(py.Str, "__version__");
        defer version.deinit();
        const cache = try py.Dict.init();
        defer cache.deinit();

        return .{ .version = .init(version), .cache = .init(cache) };
    }

    pub fn deinit(self: *State) void {
        self.cache.deinit();
        self.released = true;
    }
};

pub fn countCalls(state: *State) u64 {
    state.calls += 1;
    return state.calls;
}

pub fn stateVersion(state: *const State) py.Str {
    return state.version.get();
}

pub fn remember(state: *State, key: py.Object, value: py.Object) !void {
    try state.cache.get().set(key, value);
    state.last.set(value);
}

pub fn recall(state: *State, key: py.Object) !?py.Object {
    return state.cache.get().get(py.Object, key);
}

pub fn lastRemembered(state: *const State) ?py.Object {
    return state.last.get();
}

pub const SyntaxProblem = py.exceptionType(.{ .base = .ValueError, .doc = "The input couldn't be parsed." });

pub const StrictError = py.exceptionType(.{ .base = SyntaxProblem, .doc = "The input broke a strict rule." });

pub const PlainError = py.exceptionType(.{});

pub fn parseNumber(text: py.Str) !i64 {
    return std.fmt.parseInt(i64, try text.utf8(), 10) catch py.raise(SyntaxProblem, "not a number");
}

pub fn strictNumber(n: i64) !i64 {
    if (n < 0) return py.raiseFmt(StrictError, "{d} is negative", .{n});
    return n;
}

pub fn raisePlain() !void {
    return py.raise(PlainError, "plain");
}

const Limit = error{ TooBig, TooSmall };

pub fn limit(n: i64) Limit!i64 {
    if (n > 10) return error.TooBig;
    if (n < 0) return error.TooSmall;
    return n;
}

pub fn classify(f: py.Object) !*const [6:0]u8 {
    f.call(void, .{}) catch {
        if (py.exception.matches(StrictError)) {
            py.exception.clear();
            return "strict";
        }
        const exc = py.exception.take();
        defer exc.deinit();

        if (exc.matches(SyntaxProblem)) return "parse!";
        return exc.raise();
    };
    return "nofail";
}

pub fn parseErrorClass() !py.Object {
    return SyntaxProblem.object();
}

pub fn triple(x: i64) i64 {
    return 3 * x;
}

pub fn subPoint(x: f64) Point {
    return .{ .x = x, .y = -x };
}

pub const deep = py.module(.{
    .doc = "A submodule of a submodule.",
    .constants = .{ .ANSWER = 42 },
    .subinterpreters = true,
    .free_threaded = true,
});

pub const sub = py.module(.{
    .doc = "A submodule.",
    .functions = .{ .triple = triple, .point = subPoint },
    .submodules = .{ .deep = deep },
    .subinterpreters = true,
    .free_threaded = true,
});

const Shadowing = struct {
    int: i64,

    pub const class = py.class(.{
        .fields = .{ .int = .read_write },
        .properties = .{ .property = half },
        .methods = .{ .str = name, .float = half },
    });

    fn half(self: *const Shadowing) f64 {
        return @as(f64, @floatFromInt(self.int)) / 2;
    }

    fn name(_: *const Shadowing) !py.Str {
        return py.Str.init("list");
    }
};

const Mode = enum {
    on,
    off,

    pub const class = py.enumClass(.{});
};

fn same(value: py.Object) py.Object {
    return value;
}

fn sameMode(mode: Mode) Mode {
    return mode;
}

fn emptyList() !py.List {
    return py.List.init();
}

fn total(items: py.Sequence(i64)) !i64 {
    var sum: i64 = 0;
    for (0..items.len()) |i| sum +%= try items.get(i);
    return sum;
}

/// A submodule whose names hide built-in names and the modules that its stub imports.
pub const shadows = py.module(.{
    .doc = "Names that stubs must not confuse with built-in ones.",
    .constants = .{ .int = 1, .builtins = "builtins" },
    .classes = .{ .list = Shadowing },
    .enums = .{ .Mode = Mode },
    .functions = .{
        .typing = same,
        .@"enum" = sameMode,
        .values = emptyList,
        .collections = total,
        .zypy_tests = subPoint,
    },
    .subinterpreters = true,
    .free_threaded = true,
});

const conflicting = py.module(.{ .classes = .{ .Point = Point } });

const FailingState = struct {
    pub fn init() !FailingState {
        return error.SetupFailed;
    }
};

const failing = py.module(.{
    .submodules = .{
        .good = py.module(.{ .submodules = .{ .deep = py.module(.{}) } }),
        .bad = py.module(.{ .state = FailingState }),
    },
});

fn loadModule(comptime Module: type, name: py.Str) !py.Object {
    const machinery = try py.import("importlib.machinery");
    defer machinery.deinit();

    const spec = try machinery.callMethod(py.Object, "ModuleSpec", .{ name, null });
    defer spec.deinit();

    const created = try py.Object.own(py.c.PyModule_FromDefAndSpec(&Module.def, spec.ptr));
    errdefer created.deinit();

    if (py.c.PyModule_ExecDef(created.ptr, &Module.def) < 0) return error.PythonError;
    return created;
}

pub fn loadConflicting(name: py.Str) !py.Object {
    return loadModule(conflicting, name);
}

pub fn loadFailing(name: py.Str) !py.Object {
    return loadModule(failing, name);
}
