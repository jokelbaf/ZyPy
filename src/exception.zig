const c = @import("python");

const errors = @import("errors.zig");
const Exception = @import("types/Exception.zig");

/// Check whether the current exception matches a built-in type or a custom `py.exceptionType`.
/// Include subclasses: `.LookupError` matches a `KeyError`.
pub fn matches(comptime kind: anytype) bool {
    const exception = errors.findException(kind) orelse return false;
    defer exception.deinit();

    return c.PyErr_ExceptionMatches(exception.ptr) != 0;
}

/// Clear the current exception after handling it.
pub fn clear() void {
    c.PyErr_Clear();
}

/// Take ownership of the current exception and clear it from Python. Release it with `deinit`.
/// An exception must be set, for example after catching `error.PythonError`.
pub fn take() Exception {
    const ptr = c.PyErr_GetRaisedException() orelse @panic("py.exception.take: no Python exception is set");
    return .{ .obj = .{ .ptr = ptr, .owned = true } };
}
