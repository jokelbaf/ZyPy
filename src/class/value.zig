const c = @import("python");

const class = @import("../class.zig");
const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const borrowed = @import("../runtime/borrowed.zig");
const CriticalSection = @import("../runtime/CriticalSection.zig");
const ownership = @import("../runtime/ownership.zig");
const Class = @import("../types/class_object.zig").Class;
const Instance = @import("../types/instance.zig").Instance;
const Object = @import("../types/Object.zig");
const instances = @import("instances.zig");

/// Copy an instance value for a parameter of type `T`. Object references in the copy borrow from the instance.
pub fn copyFrom(comptime T: type, obj: *c.PyObject) errors.Error!T {
    if (comptime ownership.hasManualDeinit(T)) {
        @compileError(@typeName(T) ++ " has a deinit, so ZyPy can't hand out copies of it (take *const " ++
            @typeName(T) ++ " instead)");
    }
    const value = try class.checkInstance(T, obj);
    if (!borrowed.enabled) return ownership.lend(value.*);

    // Another thread may change the instance: copy it while it's locked, and keep what the copy borrows.
    var section: CriticalSection = .{};
    section.begin(.{obj});
    defer section.end();

    try borrowed.keepReferences(value);
    return ownership.lend(value.*);
}

/// Create an instance with a copy of `value` and its own object references. Leave `value` unchanged.
pub fn copyInto(comptime T: type, value: T) errors.Error!Object {
    if (comptime ownership.ownsResources(T)) {
        @compileError(@typeName(T) ++ " owns resources (it has a deinit or holds a view), so ZyPy can't copy it " ++
            "into Python (return it from the function, or use py.Instance(" ++ @typeName(T) ++ ").init)");
    }
    const tp = try class.typeObject(T);
    defer tp.deinit();

    return construct(T, @ptrCast(tp.ptr), ownership.lend(value));
}

/// Move `value` into a new instance. Release `value` if creating the instance fails.
pub fn moveInto(comptime T: type, value: T) errors.Error!Object {
    const tp = class.typeObject(T) catch |err| {
        var rest = value;
        ownership.release(&rest);
        return err;
    };
    defer tp.deinit();

    return construct(T, @ptrCast(tp.ptr), value);
}

/// Create an instance of `T` or a subclass, taking ownership of `value`, even on failure.
pub fn construct(comptime T: type, subtype: *c.PyTypeObject, value: T) errors.Error!Object {
    const alloc = api.typeSlot(c.allocfunc, subtype, "tp_alloc", c.Py_tp_alloc) orelse &c.PyType_GenericAlloc;
    const obj = Object.own(alloc(subtype, 0)) catch |err| {
        var rest = value;
        ownership.release(&rest);
        return err;
    };
    class.valueOf(T, obj.ptr).* = ownership.retain(value);
    return obj;
}

/// Create an instance of `subtype`, taking ownership of `contents`, even on failure.
/// Raise `TypeError` for Zig subclasses of `T`.
pub fn constructIn(comptime T: type, subtype: *c.PyTypeObject, contents: T) errors.Error!Object {
    if (instances.holdsOnly(T, subtype)) return construct(T, subtype, contents);

    var rest = contents;
    ownership.release(&rest);
    const expected = try class.typeObject(T);
    defer expected.deinit();

    _ = c.PyErr_Format(c.PyExc_TypeError, "cannot create '%N' instances from a '%N' value", subtype, expected.ptr);
    return error.PythonError;
}

/// How a method receives its instance.
pub const ReceiverKind = enum { pointer, value, instance };

/// Get how `R` receives an instance of `T` or its bases, or `null` if it cannot.
pub fn receiverKind(comptime R: type, comptime T: type) ?ReceiverKind {
    if (R == *T or R == *const T) return .pointer;
    if (R == T) return .value;
    if (R == Instance(T)) return .instance;
    const Base = class.Definition(T).Base orelse return null;
    return receiverKind(R, Base);
}

/// Get a method receiver as `R` from a type-checked instance. Copied references borrow from the instance.
pub fn receiver(comptime R: type, comptime T: type, obj: *c.PyObject) R {
    switch (comptime receiverKind(R, T).?) {
        .pointer => return class.valueOf(@typeInfo(R).pointer.child, obj),
        .value => {
            if (comptime ownership.hasManualDeinit(R)) {
                @compileError(@typeName(R) ++ " has a deinit, so its methods must take the instance as *T or *const T");
            }
            return ownership.lend(class.valueOf(R, obj).*);
        },
        .instance => return .{ .obj = .borrow(obj) },
    }
}

/// Check whether `R` is a class-method receiver for `T` or one of its bases.
pub fn receivesClass(comptime R: type, comptime T: type) bool {
    if (R == Class(T)) return true;
    const Base = class.Definition(T).Base orelse return false;
    return receivesClass(R, Base);
}
