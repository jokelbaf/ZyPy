const std = @import("std");
const py = @import("zypy");

/// The number of Bag instances released, subclasses included.
pub var bag_releases: std.atomic.Value(u32) = .init(0);

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

    fn next(self: py.Instance(BagIterator)) ?i64 {
        const iterator = self.value();
        const bag = iterator.bag.get();
        // Lock the bag together with its iterator because concurrent appends can move the items.
        var section: py.CriticalSection = .{};
        section.begin(.{ self, bag });
        defer section.end();

        const items = bag.value().items.items;
        if (iterator.index >= items.len) return null;

        defer iterator.index += 1;
        return items[iterator.index];
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
