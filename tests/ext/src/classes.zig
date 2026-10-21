const std = @import("std");
const py = @import("zypy");

const State = @import("modules.zig").State;

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
        return std.hash.Wyhash.hash(0, std.mem.asBytes(self));
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

/// The number of Bag, Tracker, and Blank instances released, including subclass instances.
var bag_releases: std.atomic.Value(u32) = .init(0);
var tracker_releases: std.atomic.Value(u32) = .init(0);
var blank_releases: std.atomic.Value(u32) = .init(0);

pub fn releases() struct { bags: u32, trackers: u32, blanks: u32 } {
    return .{
        .bags = bag_releases.load(.monotonic),
        .trackers = tracker_releases.load(.monotonic),
        .blanks = blank_releases.load(.monotonic),
    };
}

/// A class without fields, which Python classes can mix in with other bases.
pub const Blank = struct {
    pub const class = py.class(.{ .subclassable = true, .methods = .{ .address = address } });

    pub fn deinit(_: *Blank) void {
        _ = blank_releases.fetchAdd(1, .monotonic);
    }

    fn address(self: *const Blank) usize {
        return @intFromPtr(self);
    }
};

/// A second empty class, incompatible with Blank in multiple inheritance.
pub const OtherBlank = struct {
    pub const class = py.class(.{ .subclassable = true });
};

pub fn blankAddress(blank: *const Blank) usize {
    return @intFromPtr(blank);
}

pub fn newBlank(cls: py.Class(Blank)) !py.Instance(Blank) {
    return cls.new(.{});
}

pub const Bag = struct {
    items: std.ArrayList(i64),
    /// The number of active views that prevent the items from moving.
    exports: usize = 0,

    pub const class = py.class(.{
        .doc = "Integers stored in Zig memory.",
        .subclassable = true,
        .methods = .{
            .append = append,
            .total = total,
            .__len__ = len,
            .__getitem__ = py.function(get, .{ .errors = .{ .OutOfRange = .IndexError } }),
            .__setitem__ = set,
            .__delitem__ = remove,
            .__contains__ = contains,
            .__iter__ = iterate,
            .__buffer__ = contents,
            .__release_buffer__ = release,
        },
    });

    pub fn init(values: ?py.Sequence(i64)) !Bag {
        var bag: Bag = .{ .items = .empty };
        errdefer bag.items.deinit(py.allocator);

        if (values) |sequence| {
            for (0..sequence.len()) |i| try bag.items.append(py.allocator, try sequence.get(i));
        }
        return bag;
    }

    pub fn deinit(self: *Bag) void {
        self.items.deinit(py.allocator);
        _ = bag_releases.fetchAdd(1, .monotonic);
    }

    fn append(self: *Bag, value: i64) !void {
        if (self.exports > 0) return py.raise(.BufferError, "Existing exports of data: object cannot be re-sized");
        try self.items.append(py.allocator, value);
    }

    fn total(self: *const Bag) i64 {
        var sum: i64 = 0;
        for (self.items.items) |x| sum +%= x;
        return sum;
    }

    fn len(self: *const Bag) usize {
        return self.items.items.len;
    }

    fn get(self: *const Bag, index: usize) error{OutOfRange}!i64 {
        if (index >= self.items.items.len) return error.OutOfRange;
        return self.items.items[index];
    }

    fn set(self: *Bag, index: usize, value: i64) !void {
        if (index >= self.items.items.len) return py.raise(.IndexError, "Bag assignment index out of range");
        self.items.items[index] = value;
    }

    fn remove(self: *Bag, index: usize) !void {
        if (index >= self.items.items.len) return py.raise(.IndexError, "Bag deletion index out of range");
        _ = self.items.orderedRemove(index);
    }

    fn contains(self: *const Bag, value: i64) bool {
        return std.mem.indexOfScalar(i64, self.items.items, value) != null;
    }

    fn iterate(self: py.Instance(Bag)) BagIterator {
        return .{ .bag = .init(self) };
    }

    fn contents(self: *Bag) []i64 {
        self.exports += 1;
        return self.items.items;
    }

    fn release(self: *Bag) void {
        self.exports -= 1;
    }
};

/// A read-only buffer that counts active views.
pub const Frozen = struct {
    data: [3]u8 = .{ 1, 2, 3 },
    exports: usize = 0,

    pub const class = py.class(.{
        .fields = .{ .exports = .read_only },
        .methods = .{ .__buffer__ = contents, .__release_buffer__ = release },
    });

    pub fn init() Frozen {
        return .{};
    }

    fn contents(self: *Frozen) []const u8 {
        self.exports += 1;
        return &self.data;
    }

    fn release(self: *Frozen) void {
        self.exports -= 1;
    }
};

pub const BagIterator = struct {
    bag: py.Owned(py.Instance(Bag)),
    index: usize = 0,

    pub const class = py.class(.{ .init = null, .methods = .{ .__next__ = next } });

    fn next(self: *BagIterator) ?i64 {
        const items = self.bag.get().value().items.items;
        if (self.index >= items.len) return null;

        defer self.index += 1;
        return items[self.index];
    }
};

pub fn bagTotal(bag: *const Bag) i64 {
    return bag.total();
}

pub fn makeBag(n: i64) !Bag {
    var bag: Bag = .{ .items = .empty };
    errdefer bag.deinit();

    const count = std.math.cast(usize, n) orelse return py.raise(.ValueError, "make_bag() needs a count of 0 or more");
    for (0..count) |i| try bag.items.append(py.allocator, @intCast(i));
    return bag;
}

pub const Node = struct {
    value: py.Owned(py.Object),
    next: py.Owned(?py.Object) = .init(null),

    pub const class = py.class(.{
        .doc = "A linked list node.",
        .fields = .{ .value = .read_write, .next = .read_write },
        .methods = .{
            .release_value = releaseValue,
            .value_after = py.function(valueAfter, .{ .params = &.{"callback"} }),
        },
    });

    fn releaseValue(self: *Node) void {
        self.value.deinit();
    }

    fn valueAfter(self: Node, callback: py.Object) !py.Object {
        try callback.call(void, .{});
        return self.value.get();
    }
};

/// Call Python, which may modify the original node, then return the copied value.
pub fn valueAfterCall(copy: Node, callback: py.Object) !py.Object {
    try callback.call(void, .{});
    return copy.value.get();
}

/// Return a copied node value after converting an item that may change the original.
pub fn nodeValueInTuple(pair: struct { Node, i64 }) py.Object {
    return pair[0].value.get();
}

pub const Tracker = struct {
    callback: py.Owned(py.Object),
    finalized: bool = false,

    pub const class = py.class(.{
        .doc = "Call a function when freed.",
        .methods = .{ .__del__ = finalize },
        .subclassable = true,
    });

    fn finalize(self: *Tracker) !void {
        self.finalized = true;
        try self.callback.get().call(void, .{});
    }

    pub fn deinit(self: *Tracker) void {
        std.debug.assert(self.finalized);
        _ = tracker_releases.fetchAdd(1, .monotonic);
    }
};

pub const Handle = struct {
    id: u32,

    pub const class = py.class(.{ .doc = null, .init = null, .fields = .{ .id = .read_only } });
};

pub fn openHandle(id: u32) Handle {
    return .{ .id = id };
}

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
    shape.value().name.set(name);
    return shape;
}

pub fn labelLength(copy: Shape) !usize {
    return (try copy.name.get().utf8()).len;
}

pub const Tag = struct {
    name: py.Owned(py.Str),

    pub const class = py.class(.{
        .doc = "A name that weak references and new attributes can attach to.",
        .fields = .{ .name = .read_only },
        .weak_references = true,
        .dict = true,
        .subclassable = true,
    });
};

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

/// A class with a field and dynamic attributes stored in a dict.
pub const Record = struct {
    id: u32,
    extra: py.Owned(py.Dict),

    pub const class = py.class(.{
        .fields = .{ .id = .read_write },
        .methods = .{ .__getattr__ = lookup, .__setattr__ = assign, .__delattr__ = remove },
        .subclassable = true,
    });

    pub fn init(id: u32) !Record {
        const extra = try py.Dict.init();
        defer extra.deinit();

        return .{ .id = id, .extra = .init(extra) };
    }

    fn lookup(self: *const Record, name: py.Str) !?py.Object {
        return self.extra.get().get(py.Object, name);
    }

    fn assign(self: *Record, name: py.Str, value: py.Object) !bool {
        if (std.mem.eql(u8, try name.utf8(), "id")) return false;
        try self.extra.get().set(name, value);
        return true;
    }

    fn remove(self: *Record, name: py.Str) !void {
        if (try self.extra.get().remove(name)) return;
        return py.raiseFmt(.AttributeError, "Record has no attribute '{s}' to delete", .{try name.utf8()});
    }
};

/// A data descriptor with one value shared by all instances of its owning class.
pub const Slot = struct {
    value: py.Owned(?py.Object) = .init(null),
    reads: u32 = 0,

    pub const class = py.class(.{
        .fields = .{ .reads = .read_only },
        .methods = .{ .__get__ = get, .__set__ = set, .__delete__ = remove },
    });

    fn get(self: *Slot, instance: ?py.Object, owner: ?py.Object) !py.Object {
        self.reads += 1;
        if (instance == null) return owner.?;
        return self.value.get() orelse py.raise(.AttributeError, "the slot is empty");
    }

    fn set(self: *Slot, _: py.Object, value: py.Object) void {
        self.value.set(value);
    }

    fn remove(self: *Slot, _: py.Object) void {
        self.value.set(null);
    }
};

/// A data descriptor that does not support deletion.
pub const Fixed = struct {
    value: i64,

    pub const class = py.class(.{ .methods = .{ .__get__ = get, .__set__ = set } });

    fn get(self: *const Fixed, _: ?py.Object, _: ?py.Object) i64 {
        return self.value;
    }

    fn set(self: *Fixed, _: py.Object, value: i64) void {
        self.value = value;
    }
};

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

/// A Zig subclass of Bag, which inherits Bag's special methods and its deinit.
pub const Stack = struct {
    bag: Bag align(py.base_alignment),

    pub const class = py.class(.{ .base = Bag, .methods = .{ .pop = pop, .__class_getitem__ = alias } });

    pub fn init() Stack {
        return .{ .bag = .{ .items = .empty } };
    }

    fn pop(self: *Stack) !i64 {
        return self.bag.items.pop() orelse py.raise(.IndexError, "pop from empty Stack");
    }

    fn alias(cls: py.Class(Stack), item: py.Object) !py.Object {
        const types = try py.import("types");
        defer types.deinit();

        return types.callMethod(py.Object, "GenericAlias", .{ cls, item });
    }
};

/// A Tracker subclass with its own cleanup and an inherited finalizer.
pub const Alarm = struct {
    tracker: Tracker align(py.base_alignment),
    rings: u32 = 0,

    pub const class = py.class(.{ .base = Tracker, .fields = .{ .rings = .read_only } });

    pub fn init(callback: py.Object) Alarm {
        return .{ .tracker = .{ .callback = .init(callback) } };
    }

    pub fn deinit(self: *Alarm) void {
        self.tracker.deinit();
    }
};

/// A Zig subclass of Tag, which inherits weak references and the `__dict__`.
pub const Badge = struct {
    tag: Tag align(py.base_alignment),
    level: u8 = 1,

    pub const class = py.class(.{ .base = Tag, .fields = .{ .level = .read_write } });

    pub fn init(name: py.Str) Badge {
        return .{ .tag = .{ .name = .init(name) } };
    }
};

/// Three numbers accessed by name, with operators that return the called method name.
pub const Names = struct {
    items: [3]i64,

    pub const class = py.class(.{
        .subclassable = true,
        .methods = .{
            .__len__ = len,
            .__getitem__ = py.function(get, .{ .errors = .{ .UnknownName = .KeyError } }),
            .__setitem__ = py.function(set, .{ .errors = .{ .UnknownName = .KeyError } }),
        },
    });

    pub fn init() Names {
        return .{ .items = .{ 1, 2, 3 } };
    }

    fn len(_: *const Names) usize {
        return 3;
    }

    fn get(self: *const Names, name: py.Str) !i64 {
        return self.items[try position(name)];
    }

    fn set(self: *Names, name: py.Str, value: i64) !void {
        self.items[try position(name)] = value;
    }

    fn position(name: py.Str) !usize {
        const text = try name.utf8();
        for ([_][]const u8{ "first", "second", "third" }, 0..) |known, i| {
            if (std.mem.eql(u8, text, known)) return i;
        }
        return error.UnknownName;
    }
};

/// A Names subclass that accesses items by position.
pub const Positions = struct {
    names: Names align(py.base_alignment),

    pub const class = py.class(.{
        .base = Names,
        .subclassable = true,
        .methods = .{
            .__getitem__ = py.function(get, .{ .errors = .{ .OutOfRange = .IndexError } }),
            .__setitem__ = py.function(set, .{ .errors = .{ .OutOfRange = .IndexError } }),
        },
    });

    pub fn init() Positions {
        return .{ .names = .init() };
    }

    fn get(self: *const Positions, index: usize) !i64 {
        if (index >= 3) return error.OutOfRange;
        return self.names.items[index];
    }

    fn set(self: *Positions, index: usize, value: i64) !void {
        if (index >= 3) return error.OutOfRange;
        self.names.items[index] = value;
    }
};

/// A Positions subclass that accesses items by name.
pub const Labels = struct {
    positions: Positions align(py.base_alignment),

    pub const class = py.class(.{ .base = Positions, .methods = .{ .__getitem__ = get } });

    pub fn init() Labels {
        return .{ .positions = .init() };
    }

    fn get(self: *const Labels, name: py.Str) !i64 {
        const text = try name.utf8();
        return if (std.mem.eql(u8, text, "last")) self.positions.names.items[2] else -1;
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
