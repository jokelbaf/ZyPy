const std = @import("std");
const py = @import("zypy");

const State = @import("../modules.zig").State;

pub const Point = struct {
    x: f64,
    y: f64,

    pub const class = py.class(.{
        .doc = "A point in 2D.",
        .init = py.function(init, .{ .params = &.{ "x", "y" }, .defaults = .{ .y = 0.0 } }),
        .fields = .{ .x = .read_write, .y = .read_only },
        .properties = .{
            .length = py.property(norm, .{ .doc = "The distance from the origin." }),
            .coordinates = py.property(coordinates, .{ .set = setCoordinates, .doc = null }),
        },
        .methods = .{
            .norm = norm,
            .scale = py.function(scaleBy, .{ .doc = "Scale the point in place.", .params = &.{"factor"} }),
            .scaled = py.function(scaled, .{ .params = &.{"factor"} }),
            .origin = origin,
            .hypot = py.function(hypot, .{ .params = &.{ "dx", "dy" } }),
            .__repr__ = repr,
            .__eq__ = eql,
            .__lt__ = lessThan,
            .__hash__ = hash,
            .__add__ = plus,
            .__neg__ = opposite,
            .__mul__ = times,
            .__rmul__ = times,
        },
    });

    pub fn init(x: f64, y: f64) Point {
        return .{ .x = x, .y = y };
    }

    fn norm(self: *const Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    fn coordinates(self: Point) struct { f64, f64 } {
        return .{ self.x, self.y };
    }

    fn setCoordinates(self: *Point, value: struct { f64, f64 }) void {
        self.x, self.y = value;
    }

    fn scaleBy(self: *Point, factor: f64) void {
        self.x *= factor;
        self.y *= factor;
    }

    fn scaled(self: Point, factor: f64) Point {
        return .{ .x = self.x * factor, .y = self.y * factor };
    }

    fn origin() Point {
        return .{ .x = 0, .y = 0 };
    }

    fn hypot(dx: f64, dy: f64) f64 {
        return @sqrt(dx * dx + dy * dy);
    }

    fn repr(self: *const Point) !py.Str {
        var buffer: [64]u8 = undefined;
        return py.Str.init(try std.mem.print(&buffer, "Point({d}, {d})", .{ self.x, self.y }));
    }

    fn eql(self: *const Point, other: *const Point) bool {
        return self.x == other.x and self.y == other.y;
    }

    fn lessThan(self: *const Point, other: *const Point) bool {
        return self.norm() < other.norm();
    }

    fn hash(self: *const Point) u64 {
        // Equal values need equal hashes: adding 0.0 normalizes -0.0 to 0.0.
        const values = [_]f64{ self.x + 0.0, self.y + 0.0 };
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&values));
    }

    fn plus(self: *const Point, other: *const Point) Point {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    fn opposite(self: Point) Point {
        return .{ .x = -self.x, .y = -self.y };
    }

    fn times(self: *const Point, factor: f64) Point {
        return .{ .x = self.x * factor, .y = self.y * factor };
    }
};

pub fn midpoint(a: *const Point, b: *const Point) Point {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}

pub fn pointX(p: Point) f64 {
    return p.x;
}

pub fn maybePoint(give: bool) ?Point {
    return if (give) .{ .x = 1, .y = 2 } else null;
}

pub fn pointPair() struct { Point, Point } {
    return .{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 } };
}

pub fn shift(p: py.Instance(Point), dx: f64) py.Instance(Point) {
    var section: py.CriticalSection = .{};
    section.begin(.{p});
    defer section.end();

    p.value().x += dx;
    return p;
}

pub fn newInstance(x: f64) !py.Instance(Point) {
    return py.Instance(Point).init(.{ .x = x, .y = x });
}

pub fn totalX(points: py.Sequence(*const Point)) !f64 {
    var total: f64 = 0;
    for (0..points.len()) |i| total += (try points.get(i)).x;
    return total;
}

pub fn callPoint(f: py.Object) !Point {
    return f.call(Point, .{});
}

pub const Counter = struct {
    count: i64 = 0,
    step: i64 = 1,

    pub const class = py.class(.{
        .doc = "Count calls.",
        .fields = .{ .count = .read_only, .step = .read_write },
        .methods = .{
            .__call__ = py.function(call, .{ .params = &.{"times"}, .defaults = .{ .times = 1 } }),
            .__bool__ = isNonZero,
            .module_calls = moduleCalls,
            .total_calls = py.function(totalCalls, .{ .params = &.{} }),
            .from_calls = fromCalls,
        },
        .subclassable = true,
    });

    fn call(self: *Counter, times: i64) !i64 {
        self.count = try std.math.add(i64, self.count, try std.math.mul(i64, self.step, times));
        return self.count;
    }

    fn isNonZero(self: Counter) bool {
        return self.count != 0;
    }

    fn moduleCalls(_: *const Counter, state: *State) u64 {
        return state.calls;
    }

    fn totalCalls(state: *const State) u64 {
        return state.calls;
    }

    fn fromCalls(cls: py.Class(Counter), state: *const State) !py.Instance(Counter) {
        return cls.new(.{ .count = @intCast(state.calls) });
    }
};

pub const Pair = struct {
    items: py.Owned([2]py.Object),

    pub const class = py.class(.{ .doc = "Two objects.", .fields = .{ .items = .read_only } });

    pub fn init(first_item: py.Object, second_item: py.Object) Pair {
        return .{ .items = .init(.{ first_item, second_item }) };
    }
};
