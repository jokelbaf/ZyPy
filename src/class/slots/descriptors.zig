const c = @import("python");

const errors = @import("../../errors.zig");
const api = @import("../../runtime/api.zig");
const slot = @import("../slots.zig").slot;

/// The descriptor slots for `Special`, a `slots.Methods` type.
pub fn Descriptors(comptime Special: type) type {
    return struct {
        pub const slots: []const c.PyType_Slot = blk: {
            var list: []const c.PyType_Slot = &.{};
            if (Special.has("__get__")) list = list ++ .{slot(c.Py_tp_descr_get, &get)};
            if (Special.has("__set__") or Special.has("__delete__")) list = list ++ .{slot(c.Py_tp_descr_set, &set)};
            break :blk list;
        };

        fn get(self: [*c]c.PyObject, instance: [*c]c.PyObject, owner: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            // Python's __get__ gets None where CPython passes null.
            const args = .{ orNone(instance), orNone(owner) };
            const result = Special.callObject("__get__", 2, self.?, args, .raise) catch return null;
            return result.?.ptr;
        }

        fn set(self: [*c]c.PyObject, instance: [*c]c.PyObject, value: [*c]c.PyObject) callconv(.c) c_int {
            apply(self.?, instance.?, value) catch return -1;
            return 0;
        }

        fn apply(self: *c.PyObject, instance: *c.PyObject, value: ?*c.PyObject) errors.Error!void {
            if (value) |new| {
                if (comptime !Special.has("__set__")) return missing(self, "__set__");
                return Special.callVoid("__set__", 2, self, .{ instance, new });
            }
            if (comptime !Special.has("__delete__")) return missing(self, "__delete__");
            return Special.callVoid("__delete__", 1, self, .{instance});
        }

        fn missing(self: *c.PyObject, comptime method: [:0]const u8) errors.Error {
            _ = c.PyErr_Format(c.PyExc_AttributeError, "'%T' object has no attribute '" ++ method ++ "'", self);
            return error.PythonError;
        }
    };
}

fn orNone(obj: ?*c.PyObject) *c.PyObject {
    return obj orelse api.none();
}
