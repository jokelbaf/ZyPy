const c = @import("python");

const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const Object = @import("Object.zig");
const reference = @import("reference.zig");

/// A read-only view of an iterable, converting items to `T`. Strings are rejected.
/// Reuse exact lists and tuples; copy other iterables into a list.
pub fn Sequence(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Item = T;

        items: *c.PyObject,
        /// Whether `deinit` releases the view.
        owned: bool = true,

        /// View `obj` as a sequence.
        pub fn init(obj: Object) errors.Error!Self {
            if (api.isStr(obj.ptr)) return errors.raiseWrongType("a sequence", obj);
            if (api.typeOf(obj.ptr) == &c.PyList_Type or api.typeOf(obj.ptr) == &c.PyTuple_Type) {
                return .{ .items = obj.newRef().ptr };
            }

            const list = try Object.own(c.PySequence_List(obj.ptr));
            return .{ .items = list.ptr };
        }

        /// Release an owned view. Borrowed views are unchanged.
        pub fn deinit(self: Self) void {
            if (self.owned) c.Py_DecRef(self.items);
        }

        /// Get the number of items.
        pub fn len(self: Self) usize {
            return @intCast(c.PySequence_Size(self.items));
        }

        /// Get item `index` as `T`. Raise `IndexError` if it is out of range.
        /// Object references borrow from the sequence; views are owned and need `deinit`.
        pub fn get(self: Self, index: usize) errors.Error!T {
            return conversion.fromItem(T, try Object.own(c.PySequence_GetItem(self.items, reference.ssize(index))));
        }

        /// Create an owned view of `obj`.
        pub fn fromPython(obj: Object) errors.Error!Self {
            return init(obj);
        }

        /// Return an owned reference to the list or tuple holding the items.
        pub fn toPython(self: Self) errors.Error!Object {
            return Object.borrow(self.items).newRef();
        }
    };
}

/// Check whether `T` is a type made by `py.Sequence`.
pub fn isSequence(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Item") and @TypeOf(T.Item) == type and T == Sequence(T.Item);
}
