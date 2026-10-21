const std = @import("std");
const py = @import("zypy");

const collections = @import("collections.zig");

/// The number of Tracker and Blank instances released, subclasses included.
var tracker_releases: std.atomic.Value(u32) = .init(0);
var blank_releases: std.atomic.Value(u32) = .init(0);

/// Get the number of released Bag, Tracker, and Blank instances.
pub fn releases() struct { bags: u32, trackers: u32, blanks: u32 } {
    return .{
        .bags = collections.bag_releases.load(.monotonic),
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

/// Return a node key's value after converting a dict value that may change the node.
pub fn nodeKeyValue(entries: py.Dict) !py.Object {
    var iterator = entries.iterator(Node, i64);
    const entry = try iterator.next() orelse return py.raise(.ValueError, "expected an entry");
    return entry.key.value.get();
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

pub const Handle = struct {
    id: u32,

    pub const class = py.class(.{ .doc = null, .init = null, .fields = .{ .id = .read_only } });
};

pub fn openHandle(id: u32) Handle {
    return .{ .id = id };
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

/// A Zig subclass of Tag, which inherits weak references and the `__dict__`.
pub const Badge = struct {
    tag: Tag align(py.base_alignment),
    level: u8 = 1,

    pub const class = py.class(.{ .base = Tag, .fields = .{ .level = .read_write } });

    pub fn init(name: py.Str) Badge {
        return .{ .tag = .{ .name = .init(name) } };
    }
};
