const std = @import("std");
const py = @import("zypy");

pub fn add(a: i64, b: i64) !i64 {
    return std.math.add(i64, a, b);
}

pub fn quotient(a: i64, b: i64) !i64 {
    return std.math.divTrunc(i64, a, b);
}

pub fn addU8(a: u8, b: u8) u8 {
    return a +% b;
}

pub fn identity128(x: i128) i128 {
    return x;
}

pub fn zero(x: u0) u0 {
    return x;
}

/// Raise `ValueError` with a repeated message to check truncation.
pub fn raiseRepeated(text: py.Str, count: u16) !void {
    const repeated: Repeated = .{ .text = try text.utf8(), .count = count };
    return py.raiseFmt(.ValueError, "{f}", .{repeated});
}

/// Raise `ValueError` with a message that may contain invalid UTF-8.
pub fn raiseBytes(data: []const u8) !void {
    return py.raiseFmt(.ValueError, "bad: {s}", .{data});
}

const Repeated = struct {
    text: []const u8,
    count: u16,

    pub fn format(self: Repeated, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (0..self.count) |_| try w.writeAll(self.text);
    }
};

pub fn half(x: f64) f64 {
    return x / 2;
}

pub fn negate(x: bool) bool {
    return !x;
}

pub fn nothing() void {}

pub fn orDefault(x: ?i64) i64 {
    return x orelse -1;
}

pub fn maybe(give: bool) ?i64 {
    return if (give) 42 else null;
}

pub fn swap(pair: struct { i64, py.Str }) struct { py.Str, i64 } {
    return .{ pair[1], pair[0] };
}

pub fn labelled(n: i64) !struct { py.Str, i64 } {
    return .{ try py.Str.init("label"), n };
}

pub fn fail(kind: u8) !i64 {
    return switch (kind) {
        0 => py.raise(.ValueError, "bad value"),
        1 => error.OutOfMemory,
        else => error.SomethingBroke,
    };
}

pub fn identity(x: py.Object) py.Object {
    return x;
}

pub fn isNone(x: py.Object) bool {
    return x.isNone();
}

pub fn asInt(x: py.Object) !i64 {
    return x.as(i64);
}

pub fn strLen(s: py.Str) !usize {
    return (try s.utf8()).len;
}

pub fn greeting() *const [5:0]u8 {
    return "hello";
}

pub fn reverse(data: []const u8) !py.Bytes {
    const out = try py.Bytes.alloc(data.len);
    for (out.data, 0..) |*byte, i| byte.* = data[data.len - 1 - i];
    return out.bytes;
}

pub fn echoBytes(data: []const u8) []const u8 {
    return data;
}

const User = struct {
    name: py.Str,
    age: u8,
    email: ?py.Str,
    active: bool = true,
};

pub fn describeUser(user: User) struct { py.Str, u8, ?py.Str, bool } {
    return .{ user.name, user.age, user.email, user.active };
}

pub fn newUser(name: py.Str, age: u8) User {
    return .{ .name = name, .age = age, .email = null };
}

pub fn callUser(f: py.Object) !User {
    return f.call(User, .{});
}

const Job = struct {
    data: py.Buffer(f64),
    weight: f64 = 1,
    owner: struct { name: py.Str, admin: bool = false },
};

pub fn jobTotal(job: Job) !struct { f64, py.Str, bool } {
    var total: f64 = 0;
    for (job.data.items()) |x| total += x * job.weight;
    return .{ total, job.owner.name, job.owner.admin };
}

pub fn strArray() ![2]py.Str {
    const first_text = try py.Str.init("one");
    errdefer first_text.deinit();

    return .{ first_text, try py.Str.init("two") };
}

pub fn releaseArray() !void {
    const first_text = try py.Str.init("one");
    errdefer first_text.deinit();

    py.deinit([_]py.Str{ first_text, try py.Str.init("two") });
}

const Record = struct { value: py.Object };

pub fn recordValue(record: Record, observe: py.Object) !struct { py.Object, py.Object } {
    const observed = try observe.call(py.Object, .{});
    return .{ record.value, observed };
}

pub fn callRecord(f: py.Object) !py.Object {
    const record = try f.call(Record, .{});
    defer py.deinit(record);

    return record.value.newRef();
}

/// A plain struct with an `obj` field, like typed references.
const Wrapped = struct { obj: py.Object };

pub fn callWrapped(f: py.Object) !py.Object {
    const record = try f.call(Wrapped, .{});
    defer py.deinit(record);

    return record.obj.newRef();
}

/// A plain struct with an `owned` field, like conversion types.
const Flagged = struct { owned: bool, value: py.Object };

pub fn flagged(record: Flagged) struct { bool, py.Object } {
    return .{ record.owned, record.value };
}

pub fn unicodeDefault(text: py.Str) py.Str {
    return text;
}

pub const add_function = py.function(add, .{ .doc = "Add two numbers." });
