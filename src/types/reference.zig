const std = @import("std");
const c = @import("python");

const errors = @import("../errors.zig");
const Object = @import("Object.zig");

/// Convert an index or size to `Py_ssize_t`, clamping values that are too large.
/// CPython then reports its usual error for out-of-range values.
pub fn ssize(value: usize) c.Py_ssize_t {
    return std.math.cast(c.Py_ssize_t, value) orelse std.math.maxInt(c.Py_ssize_t);
}

/// Shared ownership and conversion methods for typed object references.
pub fn Methods(comptime Self: type) type {
    return struct {
        /// Take a new reference returned by the C API. Null means a Python exception is set.
        pub fn own(ptr: ?*c.PyObject) errors.Error!Self {
            return .{ .obj = try .own(ptr) };
        }

        /// Release the reference if it's owned. Does nothing for borrowed references.
        pub fn deinit(self: Self) void {
            self.obj.deinit();
        }

        /// Get an owned reference to the same object.
        pub fn newRef(self: Self) Self {
            return .{ .obj = self.obj.newRef() };
        }

        /// Return an owned reference to this object.
        pub fn toPython(self: Self) errors.Error!Object {
            return self.obj.newRef();
        }
    };
}

/// Borrow an object accepted by `isInstance`, or raise `TypeError` with `type_name`.
pub fn fromPython(
    comptime Self: type,
    comptime type_name: [:0]const u8,
    comptime isInstance: fn (*c.PyObject) bool,
) fn (Object) errors.Error!Self {
    return struct {
        fn fromPython(obj: Object) errors.Error!Self {
            if (!isInstance(obj.ptr)) return errors.raiseWrongType(type_name, obj);
            return .{ .obj = .borrow(obj.ptr) };
        }
    }.fromPython;
}
