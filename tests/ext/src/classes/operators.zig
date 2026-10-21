const std = @import("std");
const py = @import("zypy");

pub const Number = struct {
    value: i64,

    pub const class = py.class(.{
        .fields = .{ .value = .read_only },
        .subclassable = true,
        .methods = .{
            .__add__ = add,
            .__iadd__ = addInPlace,
            .__isub__ = subtractInPlace,
            .__imul__ = multiplied,
            .__ipow__ = powerInPlace,
            .__pow__ = power,
            .__rpow__ = powerOf,
            .__divmod__ = divide,
            .__rdivmod__ = divideInto,
            .__repr__ = repr,
            .__eq__ = eql,
            .__hash__ = hash,
        },
    });

    fn add(self: *const Number, other: i64) !Number {
        return .{ .value = try std.math.add(i64, self.value, other) };
    }

    fn addInPlace(self: *Number, other: i64) !void {
        self.value = try std.math.add(i64, self.value, other);
    }

    fn subtractInPlace(self: *Number, other: *const Number) !void {
        self.value = try std.math.sub(i64, self.value, other.value);
    }

    fn multiplied(self: *const Number, factor: i64) !Number {
        return .{ .value = try std.math.mul(i64, self.value, factor) };
    }

    fn powerInPlace(self: *Number, exponent: u32) !void {
        self.value = try checkedPower(self.value, exponent);
    }

    fn power(self: *const Number, exponent: u32, modulo: ?i64) !Number {
        const result = try checkedPower(self.value, exponent);
        const divisor = modulo orelse return .{ .value = result };
        if (divisor == 0) return py.raise(.ValueError, "pow() 3rd argument cannot be 0");
        // @mod overflows for the smallest i64 and -1.
        if (divisor == -1) return .{ .value = 0 };
        return .{ .value = @mod(result, divisor) };
    }

    fn powerOf(self: *const Number, base: i64) !i64 {
        return checkedPower(base, self.value);
    }

    fn divide(self: *const Number, divisor: i64) !struct { i64, i64 } {
        if (divisor == 0) return py.raise(.ZeroDivisionError, "integer division or modulo by zero");
        return .{ try std.math.divFloor(i64, self.value, divisor), @mod(self.value, divisor) };
    }

    fn divideInto(self: *const Number, dividend: i64) !struct { i64, i64 } {
        if (self.value == 0) return py.raise(.ZeroDivisionError, "integer division or modulo by zero");
        return .{ try std.math.divFloor(i64, dividend, self.value), @mod(dividend, self.value) };
    }

    fn checkedPower(base: i64, exponent: i64) !i64 {
        if (exponent < 0) return py.raise(.ValueError, "Number takes no negative powers");
        return std.math.powi(i64, base, exponent) catch error.Overflow;
    }

    fn repr(self: *const Number) !py.Str {
        var buffer: [32]u8 = undefined;
        return py.Str.init(try std.mem.print(&buffer, "Number({d})", .{self.value}));
    }

    fn eql(self: *const Number, other: *const Number) bool {
        return self.value == other.value;
    }

    fn hash(self: *const Number) i64 {
        return self.value;
    }
};

/// A Number subclass with custom addition, comparison, and representation.
/// It inherits the remaining operators and is unhashable.
pub const Score = struct {
    number: Number align(py.base_alignment),

    pub const class = py.class(.{
        .base = Number,
        .methods = .{ .__radd__ = addTo, .__eq__ = eql, .__lt__ = lessThan, .__repr__ = repr },
    });

    pub fn init(value: i64) Score {
        return .{ .number = .{ .value = value } };
    }

    fn addTo(self: *const Score, other: i64) !i64 {
        return std.math.add(i64, other, self.number.value);
    }

    fn eql(self: *const Score, other: *const Number) bool {
        return self.number.value == other.value;
    }

    fn lessThan(self: *const Score, other: *const Number) bool {
        return self.number.value < other.value;
    }

    fn repr(self: *const Score) !py.Str {
        var buffer: [32]u8 = undefined;
        return py.Str.init(try std.mem.print(&buffer, "Score({d})", .{self.number.value}));
    }
};

pub const Marker = struct {
    id: u8 = 0,

    pub const class = py.class(.{
        .subclassable = true,
        .methods = .{
            .__add__ = add,
            .__radd__ = addTo,
            .__sub__ = subtract,
            .__rsub__ = subtractFrom,
            .__mul__ = multiply,
            .__rmul__ = multiplyBy,
            .__pow__ = power,
            .__rpow__ = powerOf,
        },
    });

    fn add(_: *const Marker, _: *const Marker) !py.Str {
        return py.Str.init("Marker.__add__");
    }

    fn addTo(_: *const Marker, _: *const Marker) !py.Str {
        return py.Str.init("Marker.__radd__");
    }

    fn subtract(_: *const Marker, _: i64) !py.Str {
        return py.Str.init("Marker.__sub__");
    }

    fn subtractFrom(_: *const Marker, _: *const Marker) !py.Str {
        return py.Str.init("Marker.__rsub__");
    }

    fn multiply(_: *const Marker, _: *const Marker) !py.Object {
        return py.eval(py.Object, "NotImplemented");
    }

    fn multiplyBy(_: *const Marker, _: *const Marker) !py.Str {
        return py.Str.init("Marker.__rmul__");
    }

    fn power(_: *const Marker, _: *const Marker) !py.Str {
        return py.Str.init("Marker.__pow__");
    }

    fn powerOf(_: *const Marker, _: *const Marker) !py.Str {
        return py.Str.init("Marker.__rpow__");
    }
};

/// A Marker subclass that inherits its operators.
pub const PlainMarker = struct {
    marker: Marker align(py.base_alignment),

    pub const class = py.class(.{ .base = Marker, .subclassable = true });

    pub fn init() PlainMarker {
        return .{ .marker = .{} };
    }
};

/// A Marker subclass that overrides only forward operators.
pub const ForwardMarker = struct {
    marker: Marker align(py.base_alignment),

    pub const class = py.class(.{ .base = Marker, .methods = .{ .__add__ = add, .__pow__ = power } });

    pub fn init() ForwardMarker {
        return .{ .marker = .{} };
    }

    fn add(_: *const ForwardMarker, _: *const Marker) !py.Str {
        return py.Str.init("ForwardMarker.__add__");
    }

    fn power(_: *const ForwardMarker, _: *const Marker) !py.Str {
        return py.Str.init("ForwardMarker.__pow__");
    }
};

/// A PlainMarker subclass that overrides reflected operators.
pub const ReflectedMarker = struct {
    plain: PlainMarker align(py.base_alignment),

    pub const class = py.class(.{ .base = PlainMarker, .methods = .{ .__radd__ = addTo, .__rpow__ = powerOf } });

    pub fn init() ReflectedMarker {
        return .{ .plain = .init() };
    }

    fn addTo(_: *const ReflectedMarker, _: *const Marker) !py.Str {
        return py.Str.init("ReflectedMarker.__radd__");
    }

    fn powerOf(_: *const ReflectedMarker, _: *const Marker) !py.Str {
        return py.Str.init("ReflectedMarker.__rpow__");
    }
};
