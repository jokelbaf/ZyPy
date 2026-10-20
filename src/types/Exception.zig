const c = @import("python");

const errors = @import("../errors.zig");
const run = @import("../run.zig");
const api = @import("../runtime/api.zig");
const Object = @import("Object.zig");
const reference = @import("reference.zig");
const Str = @import("Str.zig");

const Exception = @This();

/// The Python object, for attribute access and calls.
obj: Object,

const methods = reference.Methods(Exception);
pub const own = methods.own;
pub const deinit = methods.deinit;
pub const newRef = methods.newRef;
pub const toPython = methods.toPython;
pub const fromPython = reference.fromPython(Exception, "BaseException", api.isException);

/// Check whether the exception matches a built-in type or a custom `py.exceptionType`.
/// Include subclasses: `.LookupError` matches a `KeyError`.
pub fn matches(self: Exception, comptime kind: anytype) bool {
    const exception = errors.findException(kind) orelse return false;
    defer exception.deinit();

    return c.PyErr_GivenExceptionMatches(self.obj.ptr, exception.ptr) != 0;
}

/// Get the name of the exception's type, such as `KeyError`, as an owned str.
pub fn typeName(self: Exception) errors.Error!Str {
    return Str.own(c.PyType_GetName(api.typeOf(self.obj.ptr)));
}

/// Get the message, `str(exception)`, as an owned str.
pub fn message(self: Exception) errors.Error!Str {
    return Str.own(c.PyObject_Str(self.obj.ptr));
}

/// Get an owned str with the exception and traceback, formatted as Python prints them.
pub fn traceback(self: Exception) errors.Error!Str {
    const traceback_module = try run.import("traceback");
    defer traceback_module.deinit();

    const lines = try traceback_module.callMethod(Object, "format_exception", .{self});
    defer lines.deinit();

    const empty = try Str.init("");
    defer empty.deinit();

    return Str.own(c.PyUnicode_Join(empty.obj.ptr, lines.ptr));
}

/// Raise the exception again: `return exc.raise();`. The caller keeps its reference.
pub fn raise(self: Exception) errors.Error {
    c.PyErr_SetRaisedException(self.obj.newRef().ptr);
    return error.PythonError;
}
