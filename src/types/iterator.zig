const c = @import("python");

const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const memory = @import("../runtime/memory.zig");
const Object = @import("Object.zig");

/// Read a Python iterable one item at a time, converting each item to `T`. Strings are rejected.
pub fn Iterator(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Item = T;

        // Share state so borrowed copies advance the iterator that the owner cleans up.
        const State = struct {
            iterator: *c.PyObject,
            item: ?*c.PyObject = null,
        };

        state: *State,
        /// Whether `deinit` releases the iterator.
        owned: bool = true,

        /// Start iterating over `obj`.
        pub fn init(obj: Object) errors.Error!Self {
            if (api.isStr(obj.ptr)) return errors.raiseWrongType("an iterable other than str", obj);

            const iterator = try Object.own(c.PyObject_GetIter(obj.ptr));
            errdefer iterator.deinit();

            const state = memory.allocator.create(State) catch return errors.raiseZigError(error.OutOfMemory, .{});
            state.* = .{ .iterator = iterator.ptr };
            return .{ .state = state };
        }

        /// Release an owned iterator and its current item. Borrowed iterators are unchanged.
        pub fn deinit(self: Self) void {
            if (!self.owned) return;

            if (self.state.item) |item| c.Py_DecRef(item);
            c.Py_DecRef(self.state.iterator);
            memory.allocator.destroy(self.state);
        }

        /// Get the next item as `T`, or `null` when iteration ends.
        /// Object references borrow until the next `next` or the owner calls `deinit`. Views are owned and need
        /// `deinit`.
        pub fn next(self: Self) errors.Error!?T {
            if (self.state.item) |item| {
                self.state.item = null;
                c.Py_DecRef(item);
            }

            const item = c.PyIter_Next(self.state.iterator) orelse {
                if (c.PyErr_Occurred() != null) return error.PythonError;
                return null;
            };
            self.state.item = item;
            return try conversion.fromPython(T, .borrow(item));
        }

        /// Create an owned iterator over `obj`.
        pub fn fromPython(obj: Object) errors.Error!Self {
            return init(obj);
        }

        /// Return an owned reference to the underlying Python iterator.
        pub fn toPython(self: Self) errors.Error!Object {
            return Object.borrow(self.state.iterator).newRef();
        }
    };
}

/// Check whether `T` is a type made by `py.Iterator`.
pub fn isIterator(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Item") and @TypeOf(T.Item) == type and T == Iterator(T.Item);
}
