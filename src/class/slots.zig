const std = @import("std");
const c = @import("python");

const class = @import("../class.zig");
const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const function = @import("../function.zig");
const api = @import("../runtime/api.zig");
const syntax = @import("../syntax.zig");
const Object = @import("../types/Object.zig");
const Attributes = @import("slots/attributes.zig").Attributes;
const Buffers = @import("slots/buffers.zig").Buffers;
const Comparisons = @import("slots/comparisons.zig").Comparisons;
const Containers = @import("slots/containers.zig").Containers;
const Descriptors = @import("slots/descriptors.zig").Descriptors;
const operators = @import("slots/operators.zig");
const Operators = operators.Operators;

pub const isBinary = operators.isBinary;
pub const isInPlace = operators.isInPlace;

const Name = enum {
    __del__,
    __repr__,
    __str__,
    __hash__,
    __bool__,
    __eq__,
    __ne__,
    __lt__,
    __le__,
    __gt__,
    __ge__,
    __len__,
    __getitem__,
    __setitem__,
    __delitem__,
    __contains__,
    __iter__,
    __next__,
    __call__,
    __buffer__,
    __release_buffer__,
    __neg__,
    __pos__,
    __abs__,
    __invert__,
    __int__,
    __float__,
    __index__,
    __add__,
    __sub__,
    __mul__,
    __matmul__,
    __truediv__,
    __floordiv__,
    __mod__,
    __lshift__,
    __rshift__,
    __and__,
    __or__,
    __xor__,
    __radd__,
    __rsub__,
    __rmul__,
    __rmatmul__,
    __rtruediv__,
    __rfloordiv__,
    __rmod__,
    __rlshift__,
    __rrshift__,
    __rand__,
    __ror__,
    __rxor__,
    __divmod__,
    __rdivmod__,
    __pow__,
    __rpow__,
    __iadd__,
    __isub__,
    __imul__,
    __imatmul__,
    __itruediv__,
    __ifloordiv__,
    __imod__,
    __ilshift__,
    __irshift__,
    __iand__,
    __ior__,
    __ixor__,
    __ipow__,
    __getattr__,
    __setattr__,
    __delattr__,
    __get__,
    __set__,
    __delete__,
};

pub const names = @typeInfo(Name).@"enum".field_names;

const unsupported = [_][]const u8{ "__await__", "__aiter__", "__anext__" };

// CPython inherits tp_richcompare and tp_hash together.
const shared = [_][]const []const u8{
    &.{ "__eq__", "__ne__", "__lt__", "__le__", "__gt__", "__ge__", "__hash__" },
    &.{ "__iter__", "__next__" },
    &.{ "__setitem__", "__delitem__" },
    &.{ "__buffer__", "__release_buffer__" },
    &.{ "__setattr__", "__delattr__" },
    &.{ "__set__", "__delete__" },
};

/// Check whether `method`, a name in a class's `.methods`, is a special method that fills a slot.
/// Special methods ZyPy can't fill are compile errors.
pub fn isSpecial(comptime context: []const u8, comptime method: []const u8) bool {
    for (unsupported) |name| {
        if (std.mem.eql(u8, method, name)) @compileError(context ++ ": ZyPy doesn't support " ++ method ++ " yet");
    }
    if (std.mem.eql(u8, method, "__getattribute__")) {
        @compileError(context ++ ": ZyPy doesn't support __getattribute__ (use __getattr__, which runs when the " ++
            "usual lookup finds nothing)");
    }
    if (std.mem.eql(u8, method, "__init__") or std.mem.eql(u8, method, "__new__")) {
        @compileError(context ++ ": use an init function or the .init option instead of " ++ method);
    }
    return std.meta.stringToEnum(Name, method) != null;
}

/// Check whether `name` is a special method name, such as `__len__` or `__init__`, supported or not.
pub fn isSpecialName(comptime name: []const u8) bool {
    const others = unsupported ++ [_][]const u8{ "__getattribute__", "__init__", "__new__" };
    return std.meta.stringToEnum(Name, name) != null or syntax.contains(&others, name);
}

/// Get the special methods that share type slots with `method`, `method` included.
pub fn sharing(comptime method: []const u8) []const []const u8 {
    for (shared) |group| {
        if (syntax.contains(group, method)) return group;
    }
    return operators.forms(method) orelse &.{method};
}

/// Make a type slot for the C function `func`.
pub fn slot(comptime id: c_int, comptime func: anytype) c.PyType_Slot {
    return .{ .slot = id, .pfunc = @ptrCast(@constCast(func)) };
}

/// Make a method that replaces the wrapper CPython makes from a slot for `name` (`METH_COEXIST`).
pub fn methodEntry(comptime name: [:0]const u8, comptime func: anytype, comptime flags: c_int) c.PyMethodDef {
    return .{ .ml_name = name, .ml_meth = @ptrCast(func), .ml_flags = flags | c.METH_COEXIST, .ml_doc = null };
}

/// The type slots for the special methods of a class, `methods` (its `Definition(T).special`).
pub fn Slots(comptime scope: function.Scope, comptime methods: anytype) type {
    const Special = Methods(scope, methods);

    return struct {
        pub const list: []const c.PyType_Slot = Operators(Special).slots ++ Comparisons(Special).slots ++
            Containers(Special).slots ++ Buffers(Special).slots ++ Attributes(Special).slots ++
            Descriptors(Special).slots ++ CallSlots(Special).slots ++ Finalizer(Special).slots;
        /// Methods that override slot wrappers which would call the wrong Zig method.
        pub const visible: []const c.PyMethodDef = Operators(Special).methods ++ Attributes(Special).methods ++
            Finalizer(Special).methods;
    };
}

/// The special methods of a class, and calls to them, for the slot adapters.
pub fn Methods(comptime class_scope: function.Scope, comptime class_methods: anytype) type {
    return struct {
        pub const scope = class_scope;
        pub const methods = class_methods;
        pub const name = scope.class_name;
        pub const context = "'" ++ name ++ "'";

        /// Check whether the class defines `method`.
        pub fn has(comptime method: []const u8) bool {
            return @hasField(@TypeOf(methods), method);
        }

        /// A call to `method` with `arity` arguments after the instance.
        pub fn Call(comptime method: [:0]const u8, comptime arity: usize) type {
            return function.SlotCall(name ++ "." ++ method, @field(methods, method), scope, arity);
        }

        /// Get the number of arguments `method` takes after the instance.
        pub fn parameterCount(comptime method: [:0]const u8) usize {
            return function.slotParameterCount(name ++ "." ++ method, @field(methods, method), scope);
        }

        /// Get the type of the first parameter of `method` after the instance, such as the key of `__getitem__`.
        pub fn KeyOf(comptime method: [:0]const u8, comptime arity: usize) type {
            return Call(method, arity).ParamType(0);
        }

        /// Call a special method and move its result into a Python object. `null` means `NotImplemented`.
        pub fn callObject(
            comptime method: [:0]const u8,
            comptime arity: usize,
            self: *c.PyObject,
            args: anytype,
            comptime on_type_error: Call(method, arity).OnTypeError,
        ) errors.Error!?Object {
            const Method = Call(method, arity);
            const convert = struct {
                fn convert(value: Method.Payload) errors.Error!Object {
                    return conversion.intoPython(value);
                }
            }.convert;
            return Method.invoke(self, args, on_type_error, convert);
        }

        /// Call a special method and return its result as a Zig value, such as the `bool` of `__bool__`.
        pub fn callValue(
            comptime method: [:0]const u8,
            comptime arity: usize,
            self: *c.PyObject,
            args: anytype,
        ) errors.Error!Call(method, arity).Payload {
            const Method = Call(method, arity);
            const convert = struct {
                fn convert(value: Method.Payload) errors.Error!Method.Payload {
                    return value;
                }
            }.convert;
            return (try Method.invoke(self, args, .raise, convert)).?;
        }

        /// Call a special method that returns nothing, such as `__setitem__`.
        pub fn callVoid(comptime method: [:0]const u8, comptime arity: usize, self: *c.PyObject, args: anytype) errors.Error!void {
            if (Call(method, arity).Payload != void) {
                @compileError(context ++ ": " ++ method ++ " must return void or an error union of it");
            }
            return callValue(method, arity, self, args);
        }

        /// Call a special method whose slot cannot return errors, such as `__del__`.
        /// Report failures as unraisable and preserve any existing exception.
        pub fn callUnraisable(comptime method: [:0]const u8, self: *c.PyObject) void {
            const exception = c.PyErr_GetRaisedException();
            defer c.PyErr_SetRaisedException(exception);

            callVoid(method, 0, self, .{}) catch c.PyErr_WriteUnraisable(self);
        }
    };
}

fn CallSlots(comptime Special: type) type {
    return struct {
        const slots: []const c.PyType_Slot = if (Special.has("__call__"))
            &.{slot(c.Py_tp_call, &function.CallSlot(Special.methods.__call__, Special.scope).callTuple)}
        else
            &.{};
    };
}

fn Finalizer(comptime Special: type) type {
    return struct {
        const slots: []const c.PyType_Slot = if (Special.has("__del__")) &.{slot(c.Py_tp_finalize, &finalize)} else &.{};

        const methods: []const c.PyMethodDef = if (Special.has("__del__"))
            &.{methodEntry("__del__", &delete, c.METH_NOARGS)}
        else
            &.{};

        fn finalize(self: [*c]c.PyObject) callconv(.c) void {
            // ZyPy runs __del__ itself in abi3 builds, and this flag keeps it to one run per instance, as in Python.
            if (api.limited) {
                const done = class.finalized(Special.scope.Class.?, self.?);
                if (done.*) return;
                done.* = true;
            }
            Special.callUnraisable("__del__", self.?);
        }

        fn delete(self: [*c]c.PyObject, _: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            Special.callVoid("__del__", 0, self.?, .{}) catch return null;
            return Object.borrow(api.none()).newRef().ptr;
        }
    };
}
