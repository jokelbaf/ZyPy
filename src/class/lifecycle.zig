const std = @import("std");
const c = @import("python");

const class = @import("../class.zig");
const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const gc = @import("../runtime/gc.zig");
const ownership = @import("../runtime/ownership.zig");
const Registry = @import("../runtime/registry.zig").Registry;
const Object = @import("../types/Object.zig");
const layout = @import("layout.zig");

/// Allocation, cleanup, and garbage collection slots for class `T`.
pub fn slots(comptime T: type) [4]c.PyType_Slot {
    return .{
        .{ .slot = c.Py_tp_alloc, .pfunc = @ptrCast(@constCast(&allocate)) },
        .{ .slot = c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&Functions(T).dealloc)) },
        .{ .slot = c.Py_tp_traverse, .pfunc = @ptrCast(@constCast(&Functions(T).traverse)) },
        .{ .slot = c.Py_tp_clear, .pfunc = @ptrCast(@constCast(&Functions(T).clear)) },
    };
}

/// The type objects of class `T`, one entry per import of its module.
pub fn registry(comptime T: type) *Registry(*c.PyObject) {
    return &Functions(T).types;
}

/// Get an owned reference to `T`'s type in the latest import in this interpreter.
/// Raise `RuntimeError` if its module is not loaded.
pub fn typeObject(comptime T: type) errors.Error!Object {
    return registry(T).find() orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "class " ++ @typeName(T) ++ " isn't loaded in this interpreter " ++
            "(import the module that lists it in .classes)");
        return error.PythonError;
    };
}

/// Check whether `tp` is the type of class `T` itself, not a subclass, from any import of its module.
pub fn isTypeOf(comptime T: type, tp: *c.PyTypeObject) bool {
    return api.typeSlot(c.destructor, tp, "tp_dealloc", c.Py_tp_dealloc) == &Functions(T).dealloc;
}

/// Check whether `tp` represents a Zig class. Python subclasses are excluded.
pub fn isZigClass(tp: *c.PyTypeObject) bool {
    return @intFromPtr(api.typeSlot(c.allocfunc, tp, "tp_alloc", c.Py_tp_alloc)) == @intFromPtr(&allocate);
}

fn allocate(tp: ?*c.PyTypeObject, items: c.Py_ssize_t) callconv(.c) [*c]c.PyObject {
    return c.PyType_GenericAlloc(tp, items);
}

fn Functions(comptime T: type) type {
    const definition = class.Definition(T);

    return struct {
        var types: Registry(*c.PyObject) = .{};

        fn dealloc(self: [*c]c.PyObject) callconv(.c) void {
            // Each class needs a distinct function address, even if Zig could merge identical functions.
            std.mem.doNotOptimizeAway(&types);

            const obj: *c.PyObject = self.?;
            const tp = api.typeOf(obj);
            if (definition.finalizes and !finalize(obj, tp)) return;

            c.PyObject_GC_UnTrack(obj);
            // Weak reference callbacks and deinit can run Python code, which must not replace an exception.
            const exception = c.PyErr_GetRaisedException();
            if (definition.weak_references) c.PyObject_ClearWeakRefs(obj);
            if (definition.dict) clearDict(obj);
            ownership.release(layout.valueOf(T, obj));
            c.PyErr_SetRaisedException(exception);

            api.typeSlot(c.freefunc, tp, "tp_free", c.Py_tp_free).?(obj);
            c.Py_DecRef(@ptrCast(@alignCast(tp)));
        }

        fn finalize(obj: *c.PyObject, tp: *c.PyTypeObject) bool {
            if (!api.limited) return c.PyObject_CallFinalizerFromDealloc(obj) == 0;
            // Python subclasses' subtype_dealloc already ran it.
            if (layout.finalized(T, obj).* or api.typeSlot(c.destructor, tp, "tp_dealloc", c.Py_tp_dealloc) != &dealloc) {
                return true;
            }
            // The limited API has no PyObject_CallFinalizerFromDealloc, so hold a reference while __del__ runs.
            c.Py_IncRef(obj);
            api.typeSlot(c.destructor, tp, "tp_finalize", c.Py_tp_finalize).?(obj);
            c.Py_DecRef(obj);
            return false;
        }

        fn traverse(self: [*c]c.PyObject, visitor: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
            // Instances of heap types reference their type.
            const result = visitor.?(@ptrCast(@alignCast(api.typeOf(self.?))), arg);
            if (result != 0) return result;
            // Python subclasses visit only a __dict__ they add themselves, so the class visits its own.
            if (definition.dict) {
                const dict_result = visitDict(self.?, visitor, arg);
                if (dict_result != 0) return dict_result;
            }
            return gc.visit(layout.valueOf(T, self.?), visitor, arg);
        }

        fn clear(self: [*c]c.PyObject) callconv(.c) c_int {
            if (definition.dict) clearDict(self.?);
            gc.clear(layout.valueOf(T, self.?));
            return 0;
        }

        fn visitDict(obj: *c.PyObject, visitor: c.visitproc, arg: ?*anyopaque) c_int {
            if (!api.limited) return c.PyObject_VisitManagedDict(obj, visitor, arg);
            const dict = layout.dictSlot(T, obj).* orelse return 0;
            return visitor.?(dict, arg);
        }

        fn clearDict(obj: *c.PyObject) void {
            if (!api.limited) return c.PyObject_ClearManagedDict(obj);
            const slot = layout.dictSlot(T, obj);
            const dict = slot.* orelse return;
            slot.* = null;
            c.Py_DecRef(dict);
        }
    };
}
