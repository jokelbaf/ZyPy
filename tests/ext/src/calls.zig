const py = @import("zypy");

const buffers = @import("buffers.zig");
const containers = @import("containers.zig");

pub fn getAttr(obj: py.Object, name: py.Str) !py.Object {
    return obj.getAttr(py.Object, try name.utf8());
}

pub fn attrCount(obj: py.Object) !i64 {
    return obj.getAttr(i64, "count");
}

pub fn setAttr(obj: py.Object, name: py.Str, value: py.Object) !void {
    try obj.setAttr(try name.utf8(), value);
}

pub fn hasAttr(obj: py.Object, name: py.Str) !bool {
    return obj.hasAttr(try name.utf8());
}

pub fn delAttr(obj: py.Object, name: py.Str) !void {
    try obj.delAttr(try name.utf8());
}

pub fn callNoArgs(f: py.Object) !py.Object {
    return f.call(py.Object, .{});
}

pub fn callTwo(f: py.Object, a: py.Object, b: py.Object) !py.Object {
    return f.call(py.Object, .{ a, b });
}

pub fn callKw(f: py.Object, x: i64) !py.Object {
    return f.callKw(py.Object, .{ x, "positional" }, .{ .scale = 10, .label = "z", .flag = null });
}

pub fn callMethod(obj: py.Object, name: py.Str, arg: py.Object) !py.Object {
    return obj.callMethod(py.Object, name, .{arg});
}

pub fn sortDescending(list: py.List) !void {
    try list.obj.callMethodKw(void, "sort", .{}, .{ .reverse = true });
}

pub fn callInt(f: py.Object) !i64 {
    return f.call(i64, .{});
}

pub fn callList(f: py.Object) !py.List {
    return f.call(py.List, .{});
}

pub fn callPair(f: py.Object) !struct { i64, py.Str } {
    return f.call(struct { i64, py.Str }, .{});
}

pub fn callOptional(f: py.Object) !?py.Str {
    return f.call(?py.Str, .{});
}

pub fn callBufSum(f: py.Object) !f64 {
    const buf = try f.call(py.Buffer(f64), .{});
    defer buf.deinit();

    return buffers.bufSum(buf);
}

pub fn callSeqSum(f: py.Object) !f64 {
    const xs = try f.call(py.Sequence(f64), .{});
    defer xs.deinit();

    return containers.seqSum(xs);
}

pub fn importModule(name: py.Str) !py.Object {
    return py.import(try name.utf8());
}

pub fn jsonDumps(value: py.Object) !py.Str {
    const json = try py.import("json");
    defer json.deinit();

    return json.callMethodKw(py.Str, "dumps", .{value}, .{ .sort_keys = true, .separators = .{ ",", ":" } });
}

pub fn getOrNone(container: py.Object, key: py.Object) !?py.Object {
    return container.callMethod(py.Object, "__getitem__", .{key}) catch |err| {
        if (!py.exception.matches(.KeyError)) return err;

        py.exception.clear();
        return null;
    };
}

pub fn describe(f: py.Object) !struct { py.Str, py.Str, py.Str } {
    f.call(void, .{}) catch {
        const exc = py.exception.take();
        defer exc.deinit();

        const name = try exc.typeName();
        errdefer name.deinit();
        const message = try exc.message();
        errdefer message.deinit();

        return .{ name, message, try exc.traceback() };
    };
    return py.raise(.AssertionError, "the function didn't raise");
}

pub fn reraiseLookupError(f: py.Object) !void {
    f.call(void, .{}) catch {
        const exc = py.exception.take();
        defer exc.deinit();

        if (exc.matches(.LookupError)) return exc.raise();
        return py.raise(.RuntimeError, "not a LookupError");
    };
}

pub fn exceptionMessage(exc: py.Exception) !py.Str {
    return exc.message();
}

pub fn exceptionArgs(exc: py.Exception) !py.Object {
    return exc.obj.getAttr(py.Object, "args");
}

pub fn raiseGiven(exc: py.Exception) py.Error!void {
    return exc.raise();
}

pub fn runCode(code: py.Str) !void {
    try py.run(try code.utf8());
}

pub fn evalCode(expression: py.Str) !py.Object {
    return py.eval(py.Object, try expression.utf8());
}

pub fn runInNamespace(code: py.Str) !py.Dict {
    const globals = try py.Dict.init();
    errdefer globals.deinit();

    try globals.set("base", 40);
    try py.runIn(globals, try code.utf8());
    return globals;
}

pub fn evalInNamespace(globals: py.Dict, expression: py.Str) !i64 {
    return py.evalIn(i64, globals, try expression.utf8());
}

/// Call `f(1)` `times` times, for benchmarks.
pub fn callRepeatedly(f: py.Object, times: usize) !void {
    for (0..times) |_| try f.call(void, .{1});
}

/// Call `f(1, scale=2, offset=3)` `times` times, for benchmarks.
pub fn callKeywordsRepeatedly(f: py.Object, times: usize) !void {
    for (0..times) |_| try f.callKw(void, .{1}, .{ .scale = 2, .offset = 3 });
}

/// Call `obj.touch(1)` `times` times, for benchmarks.
pub fn callMethodRepeatedly(obj: py.Object, times: usize) !void {
    for (0..times) |_| try obj.callMethod(void, "touch", .{1});
}

/// Call `obj.touch(1, flag=True)` `times` times, for benchmarks.
pub fn callMethodKeywordsRepeatedly(obj: py.Object, times: usize) !void {
    for (0..times) |_| try obj.callMethodKw(void, "touch", .{1}, .{ .flag = true });
}
