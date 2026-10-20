const c = @import("python");

const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const Iterator = @import("iterator.zig").Iterator;
const Object = @import("Object.zig");
const reference = @import("reference.zig");

/// A reference to a Python `set`, or a subclass.
pub const Set = SetOf(.mutable);

/// A reference to a Python `frozenset`, or a subclass.
pub const FrozenSet = SetOf(.frozen);

const Kind = enum { mutable, frozen };

fn SetOf(comptime kind: Kind) type {
    return struct {
        const Self = @This();

        /// The Python object, for attribute access and calls.
        obj: Object,

        const methods = reference.Methods(Self);
        pub const own = methods.own;
        pub const deinit = methods.deinit;
        pub const newRef = methods.newRef;
        pub const toPython = methods.toPython;
        pub const fromPython = reference.fromPython(Self, if (kind == .mutable) "set" else "frozenset", isInstance);

        /// Create an empty set.
        pub fn init() errors.Error!Self {
            return own(if (kind == .mutable) c.PySet_New(null) else c.PyFrozenSet_New(null));
        }

        /// Create a set from a Zig slice or array, converting each item.
        pub fn fromSlice(items: anytype) errors.Error!Self {
            const set = try init();
            errdefer set.deinit();

            // PySet_Add can fill a new frozenset before it is shared with Python.
            for (items) |item| try addItem(set, item);
            return set;
        }

        /// Get the number of items.
        pub fn len(self: Self) usize {
            return @intCast(c.PySet_Size(self.obj.ptr));
        }

        /// Check whether `value` is in the set. Unhashable values raise `TypeError`.
        pub fn contains(self: Self, value: anytype) errors.Error!bool {
            const item = try conversion.toPython(value);
            defer item.deinit();

            const found = c.PySet_Contains(self.obj.ptr, item.ptr);
            try errors.check(found);
            return found == 1;
        }

        /// Add `value` to the set.
        pub fn add(self: Self, value: anytype) errors.Error!void {
            if (kind == .frozen) @compileError("py.FrozenSet can't change (use py.Set)");
            try addItem(self, value);
        }

        /// Remove `value` from the set. Return whether it was in the set.
        pub fn discard(self: Self, value: anytype) errors.Error!bool {
            if (kind == .frozen) @compileError("py.FrozenSet can't change (use py.Set)");

            const item = try conversion.toPython(value);
            defer item.deinit();

            const found = c.PySet_Discard(self.obj.ptr, item.ptr);
            try errors.check(found);
            return found == 1;
        }

        /// Iterate over the items, converting each to `T`. Release the iterator with `deinit`.
        /// Do not add or remove items while iterating.
        pub fn iterator(self: Self, comptime T: type) errors.Error!Iterator(T) {
            return Iterator(T).init(self.obj);
        }

        fn addItem(self: Self, value: anytype) errors.Error!void {
            const item = try conversion.toPython(value);
            defer item.deinit();

            try errors.check(c.PySet_Add(self.obj.ptr, item.ptr));
        }

        fn isInstance(ptr: *c.PyObject) bool {
            const set_type = if (kind == .mutable) &c.PySet_Type else &c.PyFrozenSet_Type;
            return c.PyObject_TypeCheck(ptr, set_type) != 0;
        }
    };
}
