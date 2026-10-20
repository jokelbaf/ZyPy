const std = @import("std");
const c = @import("python");

const class = @import("../class.zig");
const api = @import("../runtime/api.zig");
const memory = @import("../runtime/memory.zig");

/// The required alignment of a Zig subclass's base field, as in `shape: Shape align(py.base_alignment)`.
pub const base_alignment: usize = memory.native.toByteUnits();

/// Get a pointer to the value inside an instance of class `T` or of a subclass.
pub fn valueOf(comptime T: type, obj: *c.PyObject) *T {
    return @ptrFromInt(@intFromPtr(obj) + offset(T));
}

/// Get the instance that holds `value`, a pointer into an instance of class `T`.
pub fn instanceOf(comptime T: type, value: *const T) *c.PyObject {
    return @ptrFromInt(@intFromPtr(value) - offset(T));
}

/// Get the abi3 finalization flag for this instance.
pub fn finalized(comptime T: type, obj: *c.PyObject) *bool {
    return @ptrFromInt(@intFromPtr(obj) + layout(T).finalized.?);
}

/// Get the instance dictionary slot in abi3 builds.
pub fn dictSlot(comptime T: type, obj: *c.PyObject) *?*c.PyObject {
    return @ptrFromInt(@intFromPtr(obj) + layout(T).dict.?);
}

/// Instance size and offsets of optional instance data.
pub const Layout = struct {
    finalized: ?usize = null,
    dict: ?usize = null,
    weak_list: ?usize = null,
    size: usize,
};

/// Get the instance size and offsets for class `T`.
pub fn layout(comptime T: type) Layout {
    const definition = class.Definition(T);
    var result: Layout = .{ .size = offset(T) + @sizeOf(T) };
    if (api.limited and definition.finalizes) {
        result.finalized = result.size;
        result.size += 1;
    }
    if (api.limited and definition.dict) result.dict = addPointer(&result.size);
    if (api.limited and definition.weak_references) result.weak_list = addPointer(&result.size);
    // CPython may skip this class's cleanup if its size does not exceed its base's.
    const base_size = if (definition.Base) |Base| layout(Base).size else @sizeOf(c.PyObject);
    result.size = @max(result.size, base_size + 1);
    // Python subclasses may place pointers immediately after this size.
    result.size = std.mem.alignForward(usize, result.size, @alignOf(*c.PyObject));
    return result;
}

fn addPointer(size: *usize) usize {
    const at = std.mem.alignForward(usize, size.*, @alignOf(*c.PyObject));
    size.* = at + @sizeOf(*c.PyObject);
    return at;
}

fn offset(comptime T: type) usize {
    const definition = class.Definition(T);
    const alignment = if (definition.subclassable or definition.Base != null) base_alignment else @alignOf(T);
    return std.mem.alignForward(usize, @sizeOf(c.PyObject), alignment);
}
