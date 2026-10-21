const c = @import("python");

const Object = @import("../types/Object.zig");
const api = @import("api.zig");
const ownership = @import("ownership.zig");

const CriticalSection = @This();

raw: if (api.free_threaded) c.PyCriticalSection2 else void = undefined,
locked: enum { none, one, two } = .none,

/// Lock one or two objects passed as a tuple of Python references or C API pointers. Pointers may be null.
/// Group objects used together in one section; Python may release outer locks while a thread waits.
pub fn begin(self: *CriticalSection, objects: anytype) void {
    const count = comptime countObjects(@TypeOf(objects));
    if (!api.free_threaded) return;

    const first = pointer(objects[0]);
    const second: ?*c.PyObject = if (count == 2) pointer(objects[1]) else null;
    const one = first orelse second orelse return;
    if (if (first != null) second else null) |other| {
        c.PyCriticalSection2_Begin(&self.raw, one, other);
        self.locked = .two;
    } else {
        c.PyCriticalSection_Begin(&self.raw._cs_base, one);
        self.locked = .one;
    }
}

/// Unlock what `begin` locked, if anything.
pub fn end(self: *CriticalSection) void {
    if (!api.free_threaded) return;

    switch (self.locked) {
        .none => {},
        .one => c.PyCriticalSection_End(&self.raw._cs_base),
        .two => c.PyCriticalSection2_End(&self.raw),
    }
    self.locked = .none;
}

fn countObjects(comptime Objects: type) usize {
    const types = switch (@typeInfo(Objects)) {
        .@"struct" => |info| if (info.is_tuple) info.field_types else &.{},
        else => &.{},
    };
    if (types.len == 0 or types.len > 2) {
        @compileError("py.CriticalSection.begin: expected one or two objects, such as .{bag} or .{ self, bag }, " ++
            "got " ++ @typeName(Objects));
    }
    for (types) |T| {
        if (!isPointer(T) and !ownership.isReference(T)) {
            @compileError("py.CriticalSection.begin: expected py.Object, a typed reference such as " ++
                "py.Instance(T), or a C API pointer, got " ++ @typeName(T));
        }
    }
    return types.len;
}

fn isPointer(comptime T: type) bool {
    return T == *c.PyObject or T == ?*c.PyObject or T == [*c]c.PyObject;
}

fn pointer(object: anytype) ?*c.PyObject {
    const T = @TypeOf(object);
    if (comptime isPointer(T)) return object;
    return if (T == Object) object.ptr else object.obj.ptr;
}
