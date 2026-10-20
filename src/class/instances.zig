const c = @import("python");

const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const layout = @import("layout.zig");
const lifecycle = @import("lifecycle.zig");

/// Check whether `obj` is an instance of class `T` or of a subclass, from any import of its module.
pub fn isInstance(comptime T: type, obj: *c.PyObject) bool {
    return isSubclass(T, api.typeOf(obj));
}

/// Check whether `tp` represents `T` or a subclass from any import of its module.
pub fn isSubclass(comptime T: type, tp: *c.PyTypeObject) bool {
    var current: ?*c.PyTypeObject = tp;
    while (current) |checked| : (current = baseType(checked)) {
        if (lifecycle.isTypeOf(T, checked)) return true;
    }
    return false;
}

/// Check whether `tp` represents `T` or a Python subclass. Zig subclasses are excluded.
pub fn holdsOnly(comptime T: type, tp: *c.PyTypeObject) bool {
    var current: ?*c.PyTypeObject = tp;
    while (current) |checked| : (current = baseType(checked)) {
        if (lifecycle.isTypeOf(T, checked)) return true;
        if (lifecycle.isZigClass(checked)) return false;
    }
    return false;
}

/// Get a pointer to the value inside `obj`, or raise `TypeError` if it isn't an instance of class `T`.
pub fn checkInstance(comptime T: type, obj: *c.PyObject) errors.Error!*T {
    if (isInstance(T, obj)) return layout.valueOf(T, obj);

    const expected = try lifecycle.typeObject(T);
    defer expected.deinit();

    _ = c.PyErr_Format(c.PyExc_TypeError, "expected %N, got %T", expected.ptr, obj);
    return error.PythonError;
}

/// Raise `TypeError` unless `obj` is the type of class `T` or of a subclass.
pub fn checkSubclass(comptime T: type, obj: *c.PyObject) errors.Error!void {
    if (api.isType(obj) and isSubclass(T, @ptrCast(obj))) return;

    const expected = try lifecycle.typeObject(T);
    defer expected.deinit();

    _ = c.PyErr_Format(c.PyExc_TypeError, "expected a subclass of %N, got %R", expected.ptr, obj);
    return error.PythonError;
}

fn baseType(tp: *c.PyTypeObject) ?*c.PyTypeObject {
    return api.typeSlot(?*c.PyTypeObject, tp, "tp_base", c.Py_tp_base);
}
