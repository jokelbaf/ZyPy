const std = @import("std");
const c = @import("python");

const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const lock = @import("../runtime/lock.zig");
const Object = @import("Object.zig");
const reference = @import("reference.zig");

const List = @This();

/// The Python object, for attribute access and calls.
obj: Object,

const methods = reference.Methods(List);
pub const own = methods.own;
pub const deinit = methods.deinit;
pub const newRef = methods.newRef;
pub const toPython = methods.toPython;
pub const fromPython = reference.fromPython(List, "list", api.isList);

/// Create an empty list.
pub fn init() errors.Error!List {
    return own(c.PyList_New(0));
}

/// Create a list from a Zig slice or array, converting each item.
pub fn fromSlice(items: anytype) errors.Error!List {
    const list = try own(c.PyList_New(@intCast(items.len)));
    errdefer list.deinit();

    for (items, 0..) |item, i| {
        const value = try conversion.toPython(item);
        api.fillList(list.obj.ptr, i, value.ptr);
    }
    return list;
}

/// Get the number of items.
pub fn len(self: List) usize {
    return api.listSize(self.obj.ptr);
}

/// Get item `index` as `T`. Raise `IndexError` if it is out of range.
/// Object references borrow from the list; views are owned and need `deinit`.
pub fn get(self: List, comptime T: type, index: usize) errors.Error!T {
    return conversion.fromItem(T, try Object.own(c.PyList_GetItemRef(self.obj.ptr, reference.ssize(index))));
}

/// Replace item `index` with `value`. Raise `IndexError` if it is out of range.
pub fn set(self: List, index: usize, value: anytype) errors.Error!void {
    const item = try conversion.toPython(value);
    try errors.check(c.PyList_SetItem(self.obj.ptr, reference.ssize(index), item.ptr));
}

/// Append `value`.
pub fn append(self: List, value: anytype) errors.Error!void {
    const item = try conversion.toPython(value);
    defer item.deinit();

    try errors.check(c.PyList_Append(self.obj.ptr, item.ptr));
}

/// Insert `value` before item `index`, or append it if `index` is past the end.
pub fn insert(self: List, index: usize, value: anytype) errors.Error!void {
    const item = try conversion.toPython(value);
    defer item.deinit();

    try errors.check(c.PyList_Insert(self.obj.ptr, reference.ssize(index), item.ptr));
}

/// Remove item `index` and return it as `T`. Raise `IndexError` if it is out of range.
/// References and views in the result are owned.
pub fn pop(self: List, comptime T: type, index: usize) errors.Error!T {
    return conversion.take(T, try self.remove(index));
}

fn remove(self: List, index: usize) errors.Error!Object {
    var section: lock.Section = .{};
    section.begin(self.obj.ptr, null);
    defer section.end();

    if (index >= self.len()) return errors.raise(.IndexError, if (self.len() == 0) "pop from empty list" else "pop index out of range");

    const item = try Object.own(c.PyList_GetItemRef(self.obj.ptr, @intCast(index)));
    errdefer item.deinit();

    try errors.check(c.PyList_SetSlice(self.obj.ptr, @intCast(index), @intCast(index + 1), null));
    return item;
}

/// Get a new list with the items from `start` up to, but not including, `end`.
/// Indexes past the end are treated as the list length.
pub fn slice(self: List, start: usize, end: usize) errors.Error!List {
    return own(c.PyList_GetSlice(self.obj.ptr, reference.ssize(start), reference.ssize(end)));
}

/// Remove all items.
pub fn clear(self: List) void {
    _ = if (api.limited) c.PyList_SetSlice(self.obj.ptr, 0, std.math.maxInt(c.Py_ssize_t), null) else c.PyList_Clear(self.obj.ptr);
}
