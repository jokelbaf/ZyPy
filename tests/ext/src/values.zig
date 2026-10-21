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

const Color = enum { red, green, blue };

pub fn nextColor(color: Color) Color {
    return switch (color) {
        .red => .green,
        .green => .blue,
        .blue => .red,
    };
}

pub fn colorNames(colors: py.Sequence(Color)) !py.List {
    const names = try py.List.init();
    errdefer names.deinit();

    for (0..colors.len()) |i| try names.append(try colors.get(i));
    return names;
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

const Quoted = enum { plain, @"say \"hi\"" };

pub fn quotedTag(tag: Quoted) Quoted {
    return tag;
}

pub fn unicodeDefault(text: py.Str) py.Str {
    return text;
}

pub const add_function = py.function(add, .{ .doc = "Add two numbers." });

pub const next_color_function = py.function(nextColor, .{ .params = &.{"color"}, .defaults = .{ .color = .blue } });

/// An enum class whose members keep the tags' explicit values.
pub const Level = enum(u8) {
    low = 1,
    medium = 5,
    high = 10,

    pub const class = py.enumClass(.{ .doc = "How much." });
};

/// An enum class with implicit member values starting at zero.
pub const Direction = enum {
    north,
    east,
    south,
    west,

    pub const class = py.enumClass(.{});
};

pub fn raiseLevel(level: Level) Level {
    return switch (level) {
        .low => .medium,
        .medium, .high => .high,
    };
}

pub fn turn(direction: Direction) Direction {
    return switch (direction) {
        .north => .east,
        .east => .south,
        .south => .west,
        .west => .north,
    };
}

pub fn levels() [3]Level {
    return .{ .low, .medium, .high };
}

pub fn callLevel(f: py.Object) !Level {
    return f.call(Level, .{});
}

pub const turn_function = py.function(turn, .{ .params = &.{"direction"}, .defaults = .{ .direction = .north } });

/// A 256-member enum class for tests and benchmarks.
pub const Wide = enum(u8) {
    m0,
    m1,
    m2,
    m3,
    m4,
    m5,
    m6,
    m7,
    m8,
    m9,
    m10,
    m11,
    m12,
    m13,
    m14,
    m15,
    m16,
    m17,
    m18,
    m19,
    m20,
    m21,
    m22,
    m23,
    m24,
    m25,
    m26,
    m27,
    m28,
    m29,
    m30,
    m31,
    m32,
    m33,
    m34,
    m35,
    m36,
    m37,
    m38,
    m39,
    m40,
    m41,
    m42,
    m43,
    m44,
    m45,
    m46,
    m47,
    m48,
    m49,
    m50,
    m51,
    m52,
    m53,
    m54,
    m55,
    m56,
    m57,
    m58,
    m59,
    m60,
    m61,
    m62,
    m63,
    m64,
    m65,
    m66,
    m67,
    m68,
    m69,
    m70,
    m71,
    m72,
    m73,
    m74,
    m75,
    m76,
    m77,
    m78,
    m79,
    m80,
    m81,
    m82,
    m83,
    m84,
    m85,
    m86,
    m87,
    m88,
    m89,
    m90,
    m91,
    m92,
    m93,
    m94,
    m95,
    m96,
    m97,
    m98,
    m99,
    m100,
    m101,
    m102,
    m103,
    m104,
    m105,
    m106,
    m107,
    m108,
    m109,
    m110,
    m111,
    m112,
    m113,
    m114,
    m115,
    m116,
    m117,
    m118,
    m119,
    m120,
    m121,
    m122,
    m123,
    m124,
    m125,
    m126,
    m127,
    m128,
    m129,
    m130,
    m131,
    m132,
    m133,
    m134,
    m135,
    m136,
    m137,
    m138,
    m139,
    m140,
    m141,
    m142,
    m143,
    m144,
    m145,
    m146,
    m147,
    m148,
    m149,
    m150,
    m151,
    m152,
    m153,
    m154,
    m155,
    m156,
    m157,
    m158,
    m159,
    m160,
    m161,
    m162,
    m163,
    m164,
    m165,
    m166,
    m167,
    m168,
    m169,
    m170,
    m171,
    m172,
    m173,
    m174,
    m175,
    m176,
    m177,
    m178,
    m179,
    m180,
    m181,
    m182,
    m183,
    m184,
    m185,
    m186,
    m187,
    m188,
    m189,
    m190,
    m191,
    m192,
    m193,
    m194,
    m195,
    m196,
    m197,
    m198,
    m199,
    m200,
    m201,
    m202,
    m203,
    m204,
    m205,
    m206,
    m207,
    m208,
    m209,
    m210,
    m211,
    m212,
    m213,
    m214,
    m215,
    m216,
    m217,
    m218,
    m219,
    m220,
    m221,
    m222,
    m223,
    m224,
    m225,
    m226,
    m227,
    m228,
    m229,
    m230,
    m231,
    m232,
    m233,
    m234,
    m235,
    m236,
    m237,
    m238,
    m239,
    m240,
    m241,
    m242,
    m243,
    m244,
    m245,
    m246,
    m247,
    m248,
    m249,
    m250,
    m251,
    m252,
    m253,
    m254,
    m255,

    pub const class = py.enumClass(.{});
};

pub fn wideValue(member: Wide) u8 {
    return @backingInt(member);
}

pub fn wideMember(value: u8) Wide {
    return @fromBackingInt(value);
}
