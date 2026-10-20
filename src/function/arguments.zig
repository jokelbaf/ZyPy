const c = @import("python");

const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const lock = @import("../runtime/lock.zig");
const memory = @import("../runtime/memory.zig");
const Object = @import("../types/Object.zig");

/// The items of an argument tuple as an array, borrowed from the tuple.
pub const TupleItems = struct {
    tuple: *c.PyObject,
    copies: if (api.limited) union { small: [8][*c]c.PyObject, large: [][*c]c.PyObject } else void,

    pub fn init(tuple: *c.PyObject) errors.Error!TupleItems {
        if (!api.limited) return .{ .tuple = tuple, .copies = {} };

        const count = api.tupleSize(tuple);
        var self: TupleItems = .{ .tuple = tuple, .copies = undefined };
        if (count <= 8) {
            self.copies = .{ .small = undefined };
        } else {
            const copies = memory.allocator.alloc([*c]c.PyObject, count) catch return errors.raiseZigError(error.OutOfMemory, .{});
            self.copies = .{ .large = copies };
        }
        for (self.slice(), 0..) |*item, i| item.* = c.PyTuple_GetItem(tuple, @intCast(i));
        return self;
    }

    pub fn deinit(self: *TupleItems) void {
        if (api.limited and api.tupleSize(self.tuple) > 8) memory.allocator.free(self.copies.large);
    }

    pub fn slice(self: *TupleItems) [][*c]c.PyObject {
        const count = api.tupleSize(self.tuple);
        if (api.limited) return if (count <= 8) self.copies.small[0..count] else self.copies.large;

        // The translated tuple struct declares one item, so index through a many-item pointer.
        const items: [*][*c]c.PyObject = @ptrCast(&@as(*c.PyTupleObject, @ptrCast(self.tuple)).ob_item);
        return items[0..count];
    }
};

/// Keyword names and values for vectorcall, each held by an owned reference.
pub const KeywordArguments = struct {
    names: *c.PyObject,
    values: []const [*c]c.PyObject,

    pub fn init(dict: *c.PyObject) errors.Error!KeywordArguments {
        // PyDict_Next lends its results: keep other threads from changing the dict meanwhile.
        var section: lock.Section = .{};
        section.begin(dict, null);
        defer section.end();

        const count: usize = @intCast(c.PyDict_Size(dict));
        const names = try Object.own(c.PyTuple_New(@intCast(count)));
        errdefer names.deinit();

        const values = memory.allocator.alloc([*c]c.PyObject, count) catch return errors.raiseZigError(error.OutOfMemory, .{});
        var filled: usize = 0;
        errdefer {
            for (values[0..filled]) |value| c.Py_DecRef(value);
            memory.allocator.free(values);
        }

        var position: c.Py_ssize_t = 0;
        var key: [*c]c.PyObject = null;
        var value: [*c]c.PyObject = null;
        while (filled < count and c.PyDict_Next(dict, &position, &key, &value) != 0) {
            // PyTuple_SetItem takes the key's reference even when it fails.
            try errors.check(c.PyTuple_SetItem(names.ptr, @intCast(filled), Object.borrow(key).newRef().ptr));
            values[filled] = Object.borrow(value).newRef().ptr;
            filled += 1;
        }
        return .{ .names = names.ptr, .values = values };
    }

    pub fn deinit(self: KeywordArguments) void {
        for (self.values) |value| c.Py_DecRef(value);
        memory.allocator.free(self.values);
        c.Py_DecRef(self.names);
    }
};
