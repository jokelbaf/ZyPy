const std = @import("std");
const py = @import("zypy");

pub const Shape = struct {
    name: py.Owned(py.Str),
    sides: u32,

    pub const class = py.class(.{
        .subclassable = true,
        .properties = .{
            .label = py.property(label, .{ .set = setLabel, .doc = "The shape's name." }),
            .sides = sideCount,
        },
        .methods = .{
            .describe = summary,
            .triangle = py.function(triangle, .{ .params = &.{"name"}, .doc = "Make a shape with three sides." }),
            .kind = kind,
        },
    });

    fn label(self: *const Shape) py.Str {
        return self.name.get();
    }

    fn setLabel(self: *Shape, name: py.Str) void {
        self.name.set(name);
    }

    fn sideCount(self: *const Shape) u32 {
        return self.sides;
    }

    fn summary(self: *const Shape) !py.Str {
        var buffer: [128]u8 = undefined;
        return py.Str.init(try std.mem.print(&buffer, "{s} with {d} sides", .{ try self.name.get().utf8(), self.sides }));
    }

    fn triangle(cls: py.Class(Shape), name: py.Str) !py.Instance(Shape) {
        return cls.new(.{ .name = .init(name), .sides = 3 });
    }

    fn kind(cls: py.Class(Shape)) !py.Str {
        return cls.obj.getAttr(py.Str, "__name__");
    }
};

/// Create an instance through the class's constructor, which runs `__init__` of Python subclasses.
pub fn buildShape(cls: py.Class(Shape), name: py.Str, sides: u32) !py.Instance(Shape) {
    return cls.obj.call(py.Instance(Shape), .{ name, sides });
}

/// Rename a shape, which may be an instance of a subclass, and return it.
pub fn relabel(shape: py.Instance(Shape), name: py.Str) py.Instance(Shape) {
    var section: py.CriticalSection = .{};
    section.begin(.{shape});
    defer section.end();

    shape.value().name.set(name);
    return shape;
}

pub fn labelLength(copy: Shape) !usize {
    return (try copy.name.get().utf8()).len;
}

/// A Shape subclass with an extra field, extra methods, and its own `describe`.
pub const Square = struct {
    shape: Shape align(py.base_alignment),
    side: f64,

    pub const class = py.class(.{
        .doc = "A shape with four equal sides.",
        .base = Shape,
        .subclassable = true,
        .fields = .{ .side = .read_write },
        .methods = .{ .area = area, .describe = summary },
    });

    pub fn init(name: py.Str, side: f64) Square {
        return .{ .shape = .{ .name = .init(name), .sides = 4 }, .side = side };
    }

    fn area(self: *const Square) f64 {
        return self.side * self.side;
    }

    fn summary(self: *const Square) !py.Str {
        const base = try self.shape.summary();
        defer base.deinit();

        var buffer: [160]u8 = undefined;
        return py.Str.init(try std.mem.print(&buffer, "{s} of side {d}", .{ try base.utf8(), self.side }));
    }
};

/// A nested Zig subclass using a field-based constructor.
pub const Prism = struct {
    square: Square align(py.base_alignment),
    height: f64 = 1,

    pub const class = py.class(.{ .base = Square, .fields = .{ .height = .read_only }, .methods = .{ .volume = volume } });

    fn volume(self: *const Prism) f64 {
        return self.square.area() * self.height;
    }
};

/// A self-iterator with `__next__` and parameters named `self` and `cls`.
pub const Countdown = struct {
    left: u32,

    pub const class = py.class(.{
        .subclassable = true,
        .fields = .{ .left = .read_only },
        .methods = .{
            .__next__ = next,
            .restart = py.function(restart, .{ .params = &.{"self"} }),
            .starting = py.function(starting, .{ .params = &.{"cls"} }),
        },
    });

    fn next(self: *Countdown) ?u32 {
        if (self.left == 0) return null;
        defer self.left -= 1;
        return self.left;
    }

    fn restart(countdown: *Countdown, from: u32) void {
        countdown.left = from;
    }

    fn starting(class_object: py.Class(Countdown), from: u32) !py.Instance(Countdown) {
        return class_object.new(.{ .left = from });
    }
};

/// A Countdown subclass that counts down by two.
pub const DoubleCountdown = struct {
    countdown: Countdown align(py.base_alignment),

    pub const class = py.class(.{ .base = Countdown, .methods = .{ .__next__ = next } });

    pub fn init(from: u32) DoubleCountdown {
        return .{ .countdown = .{ .left = from } };
    }

    fn next(self: *DoubleCountdown) ?u32 {
        const left = self.countdown.next() orelse return null;
        _ = self.countdown.next();
        return left;
    }
};
