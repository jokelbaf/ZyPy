const c = @import("python");

const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const Object = @import("Object.zig");
const reference = @import("reference.zig");

const Bytes = @This();

/// The Python object, for attribute access and calls.
obj: Object,

const methods = reference.Methods(Bytes);
pub const own = methods.own;
pub const deinit = methods.deinit;
pub const newRef = methods.newRef;
pub const toPython = methods.toPython;
pub const fromPython = reference.fromPython(Bytes, "bytes", api.isBytes);

/// Create bytes holding a copy of `data`.
pub fn init(data: []const u8) errors.Error!Bytes {
    return own(c.PyBytes_FromStringAndSize(data.ptr, @intCast(data.len)));
}

/// Allocate `size` uninitialized bytes and return the owned object with its writable memory.
/// Fill `data` before sharing the object. Python bytes are immutable once shared.
pub fn alloc(size: usize) errors.Error!struct { bytes: Bytes, data: []u8 } {
    const bytes = try own(c.PyBytes_FromStringAndSize(null, reference.ssize(size)));
    return .{ .bytes = bytes, .data = api.bytesData(bytes.obj.ptr)[0..size] };
}

/// Get the contents, valid while the bytes object lives.
pub fn slice(self: Bytes) []const u8 {
    return api.bytesData(self.obj.ptr)[0..self.len()];
}

/// Get the number of bytes.
pub fn len(self: Bytes) usize {
    return api.bytesSize(self.obj.ptr);
}
