const c = @import("python");

const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const Object = @import("Object.zig");
const reference = @import("reference.zig");

const Tuple = @This();

/// The Python object, for attribute access and calls.
obj: Object,

const methods = reference.Methods(Tuple);
pub const own = methods.own;
pub const deinit = methods.deinit;
pub const newRef = methods.newRef;
pub const toPython = methods.toPython;
pub const fromPython = reference.fromPython(Tuple, "tuple", api.isTuple);

/// Create a tuple with `size` items, initially `None`. Use `set` before sharing it with Python.
pub fn init(size: usize) errors.Error!Tuple {
    const tuple = try own(c.PyTuple_New(reference.ssize(size)));
    errdefer tuple.deinit();

    for (0..size) |i| try tuple.set(i, null);
    return tuple;
}

/// Create a tuple from a Zig slice or array, converting each item.
pub fn fromSlice(items: anytype) errors.Error!Tuple {
    const tuple = try own(c.PyTuple_New(@intCast(items.len)));
    errdefer tuple.deinit();

    for (items, 0..) |item, i| try tuple.set(i, item);
    return tuple;
}

/// Get the number of items.
pub fn len(self: Tuple) usize {
    return api.tupleSize(self.obj.ptr);
}

/// Get item `index` as `T`. Raise `IndexError` if it is out of range.
/// Object references borrow from the tuple; views are owned and need `deinit`.
pub fn get(self: Tuple, comptime T: type, index: usize) errors.Error!T {
    const borrowed = c.PyTuple_GetItem(self.obj.ptr, reference.ssize(index)) orelse return error.PythonError;
    // Keep the item alive because conversion may run Python code that drops the tuple.
    const item = Object.borrow(borrowed).newRef();
    defer item.deinit();

    return conversion.fromPython(T, item);
}

/// Replace item `index` in a tuple created by `init` or `fromSlice`.
/// Raise `SystemError` if the tuple has other references. Tuples cannot be changed once shared.
pub fn set(self: Tuple, index: usize, value: anytype) errors.Error!void {
    const item = try conversion.toPython(value);
    try errors.check(c.PyTuple_SetItem(self.obj.ptr, reference.ssize(index), item.ptr));
}
