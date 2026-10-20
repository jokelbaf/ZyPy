const c = @import("python");

const conversion = @import("../../conversion.zig");
const errors = @import("../../errors.zig");
const api = @import("../../runtime/api.zig");
const Object = @import("../../types/Object.zig");
const methodEntry = @import("../slots.zig").methodEntry;
const slot = @import("../slots.zig").slot;

/// The attribute slots for `Special`, a `slots.Methods` type.
pub fn Attributes(comptime Special: type) type {
    const context = Special.context;

    return struct {
        pub const slots: []const c.PyType_Slot = blk: {
            var list: []const c.PyType_Slot = &.{};
            if (Special.has("__getattr__")) list = list ++ .{slot(c.Py_tp_getattro, &getAttribute)};
            if (Special.has("__setattr__") or Special.has("__delattr__")) {
                list = list ++ .{slot(c.Py_tp_setattro, &setAttribute)};
            }
            break :blk list;
        };

        /// Keep `__getattr__` separate from normal lookup so a subclass's hook can override it.
        pub const methods: []const c.PyMethodDef = if (Special.has("__getattr__")) &.{
            methodEntry("__getattribute__", &c.PyObject_GenericGetAttr, c.METH_O),
            methodEntry("__getattr__", &getAttributeHook, c.METH_O),
        } else &.{};

        fn getAttribute(self: [*c]c.PyObject, name: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            if (c.PyObject_GenericGetAttr(self, name)) |found| return found;
            if (c.PyErr_ExceptionMatches(c.PyExc_AttributeError) == 0) return null;

            // Keep the lookup's AttributeError for when __getattr__ finds nothing either.
            const missing = c.PyErr_GetRaisedException();
            const found = fallback(self.?, name.?) catch {
                c.Py_DecRef(missing);
                return null;
            };
            const obj = found orelse {
                c.PyErr_SetRaisedException(missing);
                return null;
            };
            c.Py_DecRef(missing);
            return obj.ptr;
        }

        fn getAttributeHook(self: [*c]c.PyObject, name: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            if (!api.isStr(name.?)) {
                _ = c.PyErr_Format(c.PyExc_TypeError, "attribute name must be string, not '%T'", name);
                return null;
            }
            const found = fallback(self.?, name.?) catch return null;
            if (found) |obj| return obj.ptr;

            _ = c.PyErr_Format(c.PyExc_AttributeError, "'%T' object has no attribute '%U'", self, name);
            return null;
        }

        fn fallback(self: *c.PyObject, name: *c.PyObject) errors.Error!?Object {
            const Method = Special.Call("__getattr__", 1);
            const convert = struct {
                fn convert(value: Method.Payload) errors.Error!?Object {
                    if (@typeInfo(Method.Payload) != .optional) return try conversion.intoPython(value);
                    const inner = value orelse return null;
                    return try conversion.intoPython(inner);
                }
            }.convert;
            return (try Method.invoke(self, .{name}, .raise, convert)).?;
        }

        fn setAttribute(self: [*c]c.PyObject, name: [*c]c.PyObject, value: [*c]c.PyObject) callconv(.c) c_int {
            assign(self.?, name.?, value) catch return -1;
            return 0;
        }

        fn assign(self: *c.PyObject, name: *c.PyObject, value: ?*c.PyObject) errors.Error!void {
            const handled = if (value) |new|
                try hook("__setattr__", 2, self, .{ name, new })
            else
                try hook("__delattr__", 1, self, .{name});
            if (!handled) try errors.check(c.PyObject_GenericSetAttr(self, name, value));
        }

        fn hook(comptime method: [:0]const u8, comptime arity: usize, self: *c.PyObject, args: anytype) errors.Error!bool {
            if (comptime !Special.has(method)) return false;
            switch (Special.Call(method, arity).Payload) {
                void => {
                    try Special.callValue(method, arity, self, args);
                    return true;
                },
                bool => return Special.callValue(method, arity, self, args),
                else => @compileError(context ++ ": " ++ method ++ " must return void, or bool to say whether it " ++
                    "handled the attribute (or an error union of them)"),
            }
        }
    };
}
