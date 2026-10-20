const c = @import("python");

const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const vectorcall = @import("vectorcall.zig");

const Object = @This();

/// The object's pointer, for the C API (`py.c`).
ptr: *c.PyObject,
/// Whether `deinit` releases the reference.
owned: bool = false,

/// Convert a Zig value to a new Python object, which is owned. The value is unchanged.
pub fn init(value: anytype) errors.Error!Object {
    return conversion.toPython(value);
}

/// Take a new reference returned by the C API. Null means a Python exception is set.
pub fn own(ptr: ?*c.PyObject) errors.Error!Object {
    return .{ .ptr = ptr orelse return error.PythonError, .owned = true };
}

/// Wrap a borrowed reference, which something else keeps alive.
pub fn borrow(ptr: *c.PyObject) Object {
    return .{ .ptr = ptr };
}

/// Release an owned reference. Borrowed references are unchanged.
pub fn deinit(self: Object) void {
    if (self.owned) c.Py_DecRef(self.ptr);
}

/// Get an owned reference to the same object.
pub fn newRef(self: Object) Object {
    c.Py_IncRef(self.ptr);
    return .{ .ptr = self.ptr, .owned = true };
}

/// Convert to a Zig value of type `T`.
/// Object references borrow from this object; views are owned and need `deinit`.
pub fn as(self: Object, comptime T: type) errors.Error!T {
    return conversion.fromPython(T, self);
}

/// Check whether this is `None`.
pub fn isNone(self: Object) bool {
    return self.ptr == api.none();
}

/// Get attribute `name` as `T`. References and views in the result are owned.
pub fn getAttr(self: Object, comptime T: type, name: [:0]const u8) errors.Error!T {
    return conversion.take(T, try .own(c.PyObject_GetAttrString(self.ptr, name.ptr)));
}

/// Set attribute `name` to `value`, converted to Python. Ownership of `value` is unchanged.
pub fn setAttr(self: Object, name: [:0]const u8, value: anytype) errors.Error!void {
    const item = try conversion.toPython(value);
    defer item.deinit();

    try errors.check(c.PyObject_SetAttrString(self.ptr, name.ptr, item.ptr));
}

/// Check whether the object has attribute `name`. Errors other than `AttributeError` pass on.
pub fn hasAttr(self: Object, name: [:0]const u8) errors.Error!bool {
    const found = c.PyObject_HasAttrStringWithError(self.ptr, name.ptr);
    try errors.check(found);
    return found == 1;
}

/// Delete attribute `name`.
pub fn delAttr(self: Object, name: [:0]const u8) errors.Error!void {
    try errors.check(c.PyObject_DelAttrString(self.ptr, name.ptr));
}

/// Call the object with `args`, a tuple such as `.{ 1, "x" }`, and convert the result to `T`.
/// References and views in the result are owned.
pub fn call(self: Object, comptime T: type, args: anytype) errors.Error!T {
    return vectorcall.call(T, self, args, .{});
}

/// Call the object with `args` and keyword arguments `kwargs`, a struct such as `.{ .indent = 2 }`.
/// References and views in the result are owned.
pub fn callKw(self: Object, comptime T: type, args: anytype, kwargs: anytype) errors.Error!T {
    return vectorcall.call(T, self, args, kwargs);
}

/// Call method `name` with positional `args` and convert the result to `T`.
/// Use a string literal or `py.Str` for `name`. References and views in the result are owned.
pub inline fn callMethod(self: Object, comptime T: type, name: anytype, args: anytype) errors.Error!T {
    return vectorcall.callMethod(T, self, name, args, .{});
}

/// Call method `name` with positional `args` and keyword `kwargs`, converting the result to `T`.
/// Use a string literal or `py.Str` for `name`. References and views in the result are owned.
pub inline fn callMethodKw(self: Object, comptime T: type, name: anytype, args: anytype, kwargs: anytype) errors.Error!T {
    return vectorcall.callMethod(T, self, name, args, kwargs);
}

/// Borrow `obj`.
pub fn fromPython(obj: Object) errors.Error!Object {
    return .borrow(obj.ptr);
}

/// Return an owned reference to this object.
pub fn toPython(self: Object) errors.Error!Object {
    return self.newRef();
}
