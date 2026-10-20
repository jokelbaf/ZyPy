const c = @import("python");

const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const Object = @import("Object.zig");

const Args = @This();

/// Argument pointers, valid until the call returns.
items: []const [*c]c.PyObject,

/// Get the number of arguments.
pub fn len(self: Args) usize {
    return self.items.len;
}

/// Get argument `index` as `T`. Raise `IndexError` if it is out of range.
/// Object references borrow from the call; views are owned and need `deinit`.
pub fn get(self: Args, comptime T: type, index: usize) errors.Error!T {
    if (index >= self.items.len) return errors.raise(.IndexError, "argument index out of range");
    return conversion.fromPython(T, .borrow(self.items[index]));
}

/// Return an owned tuple of the arguments.
pub fn toPython(self: Args) errors.Error!Object {
    const tuple = try Object.own(c.PyTuple_New(@intCast(self.items.len)));
    errdefer tuple.deinit();

    for (self.items, 0..) |item, i| {
        try errors.check(c.PyTuple_SetItem(tuple.ptr, @intCast(i), Object.borrow(item).newRef().ptr));
    }
    return tuple;
}

/// A compile error: `py.Args` can only be a parameter of an exported function.
pub fn fromPython(_: Object) errors.Error!Args {
    @compileError("py.Args can only be a parameter of an exported function (use py.Tuple or py.Sequence(T) instead)");
}
