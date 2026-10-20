const std = @import("std");
const py = @import("zypy");

pub fn allocatorStress(raw: bool) !void {
    const allocator = if (raw) py.raw_allocator else py.allocator;
    try std.heap.testAllocator(allocator);
    try std.heap.testAllocatorAligned(allocator);
    try std.heap.testAllocatorLargeAlignment(allocator);
    try std.heap.testAllocatorAlignedShrink(allocator);
}

pub fn tracedAllocation(size: usize, raw: bool) !i64 {
    const allocator = if (raw) py.raw_allocator else py.allocator;
    const tracemalloc = try py.import("tracemalloc");
    defer tracemalloc.deinit();

    const before, _ = try tracemalloc.callMethod(struct { i64, i64 }, "get_traced_memory", .{});
    const memory = try allocator.alloc(u8, size);
    defer allocator.free(memory);

    const after, _ = try tracemalloc.callMethod(struct { i64, i64 }, "get_traced_memory", .{});
    return after - before;
}

pub fn joinNumbers(xs: py.Sequence(i64)) !py.Str {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(py.allocator);

    for (0..xs.len()) |i| {
        if (i > 0) try text.appendSlice(py.allocator, ", ");
        try text.print(py.allocator, "{d}", .{try xs.get(i)});
    }
    return py.Str.init(text.items);
}

pub fn greet(name: py.Str, salutation: py.Str, loud: bool) !py.Str {
    var buffer: [256]u8 = undefined;
    const text = try std.mem.print(&buffer, "{s}, {s}{s}", .{ try salutation.utf8(), try name.utf8(), if (loud) "!" else "." });
    return py.Str.init(text);
}

pub fn bind(a: i64, b: i64, c: ?i64, d: i64, e: bool) struct { i64, i64, ?i64, i64, bool } {
    return .{ a, b, c, d, e };
}

pub fn keywordsOnly(x: i64, y: i64, z: i64) i64 {
    return x *% 100 +% y *% 10 +% z;
}

pub fn optionalTail(a: i64, b: ?i64, c: ?i64) struct { i64, ?i64, ?i64 } {
    return .{ a, b, c };
}

pub fn collect(head: i64, rest: py.Args, flag: bool, options: py.Kwargs) !struct { i64, py.Object, bool, py.Object } {
    const extra = try py.Object.init(rest);
    errdefer extra.deinit();

    return .{ head, extra, flag, try py.Object.init(options) };
}

pub fn sumArgs(args: py.Args) !i64 {
    var total: i64 = 0;
    for (0..args.len()) |i| total +%= try args.get(i64, i);
    return total;
}

pub fn kwargNames(kwargs: py.Kwargs) !py.List {
    const names = try py.List.init();
    errdefer names.deinit();

    var entries = kwargs.iterator(py.Str, py.Object);
    while (try entries.next()) |entry| try names.append(entry.key);
    return names;
}

pub fn kwargLookup(kwargs: py.Kwargs) !struct { usize, ?i64, bool } {
    return .{ kwargs.len(), try kwargs.get(i64, "n"), try kwargs.contains("flag") };
}

pub fn positionalAndKwargs(a: i64, kwargs: py.Kwargs) !struct { i64, py.Object } {
    return .{ a, try py.Object.init(kwargs) };
}

pub fn withDefaults(text: py.Str, items: py.List, data: []const u8, factor: f64, count: u8, mode: ?py.Object) !struct {
    py.Str,
    py.List,
    py.Bytes,
    f64,
    u8,
    ?py.Object,
} {
    return .{ text, items, try py.Bytes.init(data), factor, count, mode };
}

const ParseError = error{ InvalidInput, NotFound, Unmapped };

pub fn parse(kind: u8) ParseError!i64 {
    return switch (kind) {
        0 => error.InvalidInput,
        1 => error.NotFound,
        2 => error.Unmapped,
        else => 42,
    };
}

pub fn moduleErrors(kind: u8) !void {
    return switch (kind) {
        0 => error.ModuleWide,
        1 => error.InvalidInput,
        else => error.Unmapped,
    };
}

pub fn sleepMs(ms: u32) void {
    const duration: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.os.linux.nanosleep(&duration, null);
}

pub fn sleepAllowingThreads(ms: u32) void {
    py.allowThreads(sleepMs, .{ms});
}

pub fn sumWithoutGil(data: py.Buffer(f64), factor: f64) f64 {
    var total: f64 = 0;
    for (data.items()) |x| total += x * factor;
    return total;
}

const ThreadCall = struct {
    function: py.Object,
    result: ?py.Object = null,
    failure: ?py.Exception = null,
};

fn callWithGil(call: *ThreadCall) void {
    const gil = py.Gil.acquire();
    defer gil.release();

    // The exception belongs to this thread's state, so take it to raise it in the calling thread.
    call.result = call.function.call(py.Object, .{}) catch {
        call.failure = py.exception.take();
        return;
    };
}

pub fn callFromThread(f: py.Object) !py.Object {
    var call: ThreadCall = .{ .function = f };
    const thread = try std.Thread.spawn(.{}, callWithGil, .{&call});
    py.allowThreads(std.Thread.join, .{thread});

    if (call.failure) |exc| {
        defer exc.deinit();
        return exc.raise();
    }
    return call.result.?;
}

pub fn nestedGil(f: py.Object) !py.Object {
    const gil = py.Gil.acquire();
    defer gil.release();

    return f.call(py.Object, .{});
}

pub const greet_function = py.function(greet, .{
    .doc = "Greet someone.",
    .params = &.{ "name", "/", "greeting", "*", "loud" },
    .defaults = .{ .greeting = "Hello", .loud = false },
});

pub const bind_function = py.function(bind, .{
    .params = &.{ "a", "/", "b", "c", "*", "d", "e" },
    .defaults = .{ .d = 4, .e = false },
});

pub const keywords_only_function = py.function(keywordsOnly, .{ .params = &.{ "*", "x", "y", "z" } });

pub const collect_function = py.function(collect, .{
    .params = &.{ "first", "*rest", "flag", "**options" },
    .defaults = .{ .flag = false },
});

pub const positional_and_kwargs_function = py.function(positionalAndKwargs, .{ .params = &.{ "a", "/", "**kwargs" } });

pub const with_defaults_function = py.function(withDefaults, .{
    .doc = "Return the arguments.",
    .params = .{ "text", "items", "data", "factor", "count", "mode" },
    .defaults = .{ .text = "it's", .items = [_]i64{ 1, 2 }, .data = "raw\n", .factor = 2.0, .count = 3, .mode = null },
});

pub const parse_function = py.function(parse, .{
    .errors = .{ .InvalidInput = .ValueError, .NotFound = .{ .KeyError, "no such key" } },
});

pub const sleep_released_function = py.function(sleepMs, .{ .release_gil = true });

pub const sum_without_gil_function = py.function(sumWithoutGil, .{ .release_gil = true });

pub fn keywordSum(a: i64, b: i64, c: i64, d: i64) i64 {
    return a +% b +% c +% d;
}

pub fn wideSum(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64) i64 {
    return a +% b +% c +% d +% e +% f +% g +% h;
}

pub const keyword_sum_function = py.function(keywordSum, .{ .params = &.{ "a", "b", "*", "c", "d" } });

pub const wide_sum_function = py.function(wideSum, .{
    .params = &.{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" },
});
