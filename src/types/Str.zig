const c = @import("python");

const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const Object = @import("Object.zig");
const reference = @import("reference.zig");

const Str = @This();

/// The Python object, for attribute access and calls.
obj: Object,

const methods = reference.Methods(Str);
pub const own = methods.own;
pub const deinit = methods.deinit;
pub const newRef = methods.newRef;
pub const toPython = methods.toPython;
pub const fromPython = reference.fromPython(Str, "str", api.isStr);

/// Create a str from UTF-8 text. Raise `UnicodeDecodeError` if the text isn't valid UTF-8.
pub fn init(text: []const u8) errors.Error!Str {
    return own(c.PyUnicode_FromStringAndSize(text.ptr, @intCast(text.len)));
}

/// Get UTF-8 text, valid while the str lives. Raise `UnicodeEncodeError` for lone surrogates.
pub fn utf8(self: Str) errors.Error![:0]const u8 {
    var size: c.Py_ssize_t = undefined;
    const text: [*]const u8 = c.PyUnicode_AsUTF8AndSize(self.obj.ptr, &size) orelse return error.PythonError;
    return text[0..@intCast(size) :0];
}
