const std = @import("std");
const c = @import("python");

const class = @import("../../class.zig");
const conversion = @import("../../conversion.zig");
const errors = @import("../../errors.zig");
const api = @import("../../runtime/api.zig");
const Object = @import("../../types/Object.zig");
const Methods = @import("../slots.zig").Methods;
const methodEntry = @import("../slots.zig").methodEntry;
const slot = @import("../slots.zig").slot;

const BinaryOp = struct {
    forward: [:0]const u8,
    reflected: [:0]const u8,
    slot: c_int,
    /// The `PyNumberMethods` field of the slot.
    field: []const u8,
};

const binary_ops = [_]BinaryOp{
    .{ .forward = "__add__", .reflected = "__radd__", .slot = c.Py_nb_add, .field = "nb_add" },
    .{ .forward = "__sub__", .reflected = "__rsub__", .slot = c.Py_nb_subtract, .field = "nb_subtract" },
    .{ .forward = "__mul__", .reflected = "__rmul__", .slot = c.Py_nb_multiply, .field = "nb_multiply" },
    .{ .forward = "__matmul__", .reflected = "__rmatmul__", .slot = c.Py_nb_matrix_multiply, .field = "nb_matrix_multiply" },
    .{ .forward = "__truediv__", .reflected = "__rtruediv__", .slot = c.Py_nb_true_divide, .field = "nb_true_divide" },
    .{ .forward = "__floordiv__", .reflected = "__rfloordiv__", .slot = c.Py_nb_floor_divide, .field = "nb_floor_divide" },
    .{ .forward = "__mod__", .reflected = "__rmod__", .slot = c.Py_nb_remainder, .field = "nb_remainder" },
    .{ .forward = "__lshift__", .reflected = "__rlshift__", .slot = c.Py_nb_lshift, .field = "nb_lshift" },
    .{ .forward = "__rshift__", .reflected = "__rrshift__", .slot = c.Py_nb_rshift, .field = "nb_rshift" },
    .{ .forward = "__and__", .reflected = "__rand__", .slot = c.Py_nb_and, .field = "nb_and" },
    .{ .forward = "__or__", .reflected = "__ror__", .slot = c.Py_nb_or, .field = "nb_or" },
    .{ .forward = "__xor__", .reflected = "__rxor__", .slot = c.Py_nb_xor, .field = "nb_xor" },
    .{ .forward = "__divmod__", .reflected = "__rdivmod__", .slot = c.Py_nb_divmod, .field = "nb_divmod" },
};

const power_op: BinaryOp = .{ .forward = "__pow__", .reflected = "__rpow__", .slot = c.Py_nb_power, .field = "nb_power" };

const InPlaceOp = struct { method: [:0]const u8, slot: c_int };

const in_place_ops = [_]InPlaceOp{
    .{ .method = "__iadd__", .slot = c.Py_nb_inplace_add },
    .{ .method = "__isub__", .slot = c.Py_nb_inplace_subtract },
    .{ .method = "__imul__", .slot = c.Py_nb_inplace_multiply },
    .{ .method = "__imatmul__", .slot = c.Py_nb_inplace_matrix_multiply },
    .{ .method = "__itruediv__", .slot = c.Py_nb_inplace_true_divide },
    .{ .method = "__ifloordiv__", .slot = c.Py_nb_inplace_floor_divide },
    .{ .method = "__imod__", .slot = c.Py_nb_inplace_remainder },
    .{ .method = "__ilshift__", .slot = c.Py_nb_inplace_lshift },
    .{ .method = "__irshift__", .slot = c.Py_nb_inplace_rshift },
    .{ .method = "__iand__", .slot = c.Py_nb_inplace_and },
    .{ .method = "__ior__", .slot = c.Py_nb_inplace_or },
    .{ .method = "__ixor__", .slot = c.Py_nb_inplace_xor },
    .{ .method = "__ipow__", .slot = c.Py_nb_inplace_power },
};

const UnaryOp = struct { method: [:0]const u8, slot: c_int };

const unary_ops = [_]UnaryOp{
    .{ .method = "__repr__", .slot = c.Py_tp_repr },
    .{ .method = "__str__", .slot = c.Py_tp_str },
    .{ .method = "__neg__", .slot = c.Py_nb_negative },
    .{ .method = "__pos__", .slot = c.Py_nb_positive },
    .{ .method = "__abs__", .slot = c.Py_nb_absolute },
    .{ .method = "__invert__", .slot = c.Py_nb_invert },
    .{ .method = "__int__", .slot = c.Py_nb_int },
    .{ .method = "__float__", .slot = c.Py_nb_float },
    .{ .method = "__index__", .slot = c.Py_nb_index },
};

const comparisons = [_][]const u8{ "__eq__", "__ne__", "__lt__", "__le__", "__gt__", "__ge__" };

/// Get the forward and reflected methods sharing a binary operator slot, or `null` for other methods.
pub fn forms(comptime method: []const u8) ?[]const []const u8 {
    for (binary_ops ++ .{power_op}) |op| {
        if (std.mem.eql(u8, method, op.forward) or std.mem.eql(u8, method, op.reflected)) {
            return &.{ op.forward, op.reflected };
        }
    }
    return null;
}

/// Check whether `method` takes another operand, such as `__add__` or `__eq__`.
pub fn isBinary(comptime method: []const u8) bool {
    if (forms(method) != null) return true;
    for (comparisons) |name| {
        if (std.mem.eql(u8, method, name)) return true;
    }
    return isInPlace(method);
}

/// Check whether a special method is an in-place operator, such as `__iadd__`.
pub fn isInPlace(comptime method: []const u8) bool {
    for (in_place_ops) |op| {
        if (std.mem.eql(u8, method, op.method)) return true;
    }
    return false;
}

/// The operator slots for `Special`, a `slots.Methods` type.
pub fn Operators(comptime Special: type) type {
    const context = Special.context;
    const Class = Special.scope.Class.?;
    const compares = definesAny(Special, &comparisons);

    return struct {
        pub const slots: []const c.PyType_Slot = blk: {
            var list: []const c.PyType_Slot = &.{};
            for (unary_ops) |op| {
                if (Special.has(op.method)) list = list ++ .{slot(op.slot, &Unary(op.method).call)};
            }
            if (Special.has("__hash__")) {
                list = list ++ .{slot(c.Py_tp_hash, &hash)};
            } else if (compares and !Special.has("__eq__")) {
                // Without __eq__, comparisons don't change equality, so keep the identity hash.
                list = list ++ .{slot(c.Py_tp_hash, &identityHash)};
            }
            if (compares) list = list ++ .{slot(c.Py_tp_richcompare, &richCompare)};
            if (Special.has("__bool__")) list = list ++ .{slot(c.Py_nb_bool, &truth)};
            for (binary_ops) |op| {
                if (Special.has(op.forward) or Special.has(op.reflected)) list = list ++ .{slot(op.slot, &Binary(op).call)};
            }
            if (Special.has("__pow__") or Special.has("__rpow__")) list = list ++ .{slot(c.Py_nb_power, &power)};
            for (in_place_ops) |op| {
                if (Special.has(op.method)) list = list ++ .{slot(op.slot, &InPlace(op.method).call)};
            }
            break :blk list;
        };

        /// Explicit operator methods must call the requested method rather than dispatch by operand types.
        pub const methods: []const c.PyMethodDef = blk: {
            var list: []const c.PyMethodDef = &.{};
            for (binary_ops) |op| {
                if (Special.has(op.forward) or Special.has(op.reflected)) list = list ++ .{
                    methodEntry(op.forward, &BinaryMethod(op.forward).call, c.METH_O),
                    methodEntry(op.reflected, &BinaryMethod(op.reflected).call, c.METH_O),
                };
            }
            if (Special.has("__pow__") or Special.has("__rpow__")) list = list ++ .{
                methodEntry("__pow__", &PowerMethod("__pow__").call, c.METH_FASTCALL),
                methodEntry("__rpow__", &PowerMethod("__rpow__").call, c.METH_FASTCALL),
            };
            break :blk list;
        };

        fn Unary(comptime method: [:0]const u8) type {
            return struct {
                fn call(self: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
                    const result = Special.callObject(method, 0, self.?, .{}, .raise) catch return null;
                    return result.?.ptr;
                }
            };
        }

        fn Binary(comptime op: BinaryOp) type {
            return struct {
                fn call(a: [*c]c.PyObject, b: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
                    return slotResult(dispatch(op, &call, a.?, b.?, .{}));
                }
            };
        }

        fn power(a: [*c]c.PyObject, b: [*c]c.PyObject, modulo: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            return slotResult(dispatch(power_op, &power, a.?, b.?, .{modulo.?}));
        }

        fn dispatch(comptime op: BinaryOp, comptime func: anytype, a: *c.PyObject, b: *c.PyObject, extra: anytype) errors.Error!?Object {
            const left = hasSlot(op, a, func);
            const right = hasSlot(op, b, func);
            if (left and right) {
                if (try callOperator(Special, op.forward, a, b, extra)) |result| return result;
                // As in Python, the reflected method isn't tried for two operands of the same class.
                if (api.typeOf(a) == api.typeOf(b)) return null;
                return callOperator(Special, op.reflected, b, a, extra);
            }
            if (left) {
                if (fromSubclass(a, b)) return null;
                return callOperator(Special, op.forward, a, b, extra);
            }
            if (!right) return null;
            inline for (comptime class.bases(Class)) |Base| {
                if (comptime class.definer(Base, op.forward) == null) continue;
                if (class.isTypeOf(Base, api.typeOf(a)) and isSubtype(b, a)) return fromBase(op, Base, a, b, extra);
            }
            return callOperator(Special, op.reflected, b, a, extra);
        }

        fn fromBase(comptime op: BinaryOp, comptime Base: type, a: *c.PyObject, b: *c.PyObject, extra: anytype) errors.Error!?Object {
            const Owner = class.definer(Base, op.forward).?;
            const Forward = Methods(Special.scope.of(Owner), class.Definition(Owner).methods);
            if (comptime class.sameMethod(Class, Base, op.reflected)) {
                if (try callOperator(Forward, op.forward, a, b, extra)) |result| return result;
                return callOperator(Special, op.reflected, b, a, extra);
            }
            if (try callOperator(Special, op.reflected, b, a, extra)) |result| return result;
            return callOperator(Forward, op.forward, a, b, extra);
        }

        fn BinaryMethod(comptime method: [:0]const u8) type {
            return struct {
                fn call(self: [*c]c.PyObject, other: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
                    return slotResult(callOperator(Special, method, self.?, other.?, .{}));
                }
            };
        }

        fn PowerMethod(comptime method: [:0]const u8) type {
            return struct {
                fn call(self: [*c]c.PyObject, args: [*c]const [*c]c.PyObject, count: c.Py_ssize_t) callconv(.c) [*c]c.PyObject {
                    return slotResult(apply(self.?, args, @intCast(count)));
                }

                fn apply(self: *c.PyObject, args: [*c]const [*c]c.PyObject, count: usize) errors.Error!?Object {
                    if (count == 0) return errors.raise(.TypeError, "expected at least 1 argument, got 0");
                    if (count > 2) return errors.raiseFmt(.TypeError, "expected at most 2 arguments, got {d}", .{count});
                    return callOperator(Special, method, self, args[0].?, .{if (count == 2) args[1].? else api.none()});
                }
            };
        }

        fn InPlace(comptime method: [:0]const u8) type {
            return struct {
                const call = if (std.mem.eql(u8, method, "__ipow__")) ternary else binary;

                fn binary(self: [*c]c.PyObject, other: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
                    return slotResult(apply(self.?, other.?));
                }

                fn ternary(self: [*c]c.PyObject, other: [*c]c.PyObject, _: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
                    return binary(self, other);
                }

                fn apply(self: *c.PyObject, other: *c.PyObject) errors.Error!?Object {
                    const Method = Special.Call(method, 1);
                    const convert = struct {
                        fn convert(value: Method.Payload) errors.Error!?Object {
                            if (Method.Payload == void) return null;
                            return try conversion.intoPython(value);
                        }
                    }.convert;
                    // `null` means NotImplemented: the operand didn't convert, so Python tries the binary operator.
                    const result = try Method.invoke(self, .{other}, .not_implemented, convert) orelse return null;
                    return result orelse Object.borrow(self).newRef();
                }
            };
        }

        fn richCompare(self: [*c]c.PyObject, other: [*c]c.PyObject, op: c_int) callconv(.c) [*c]c.PyObject {
            return slotResult(compare(self.?, other.?, op));
        }

        fn compare(self: *c.PyObject, other: *c.PyObject, op: c_int) errors.Error!?Object {
            return switch (op) {
                c.Py_EQ => callBinary("__eq__", self, other),
                c.Py_NE => notEqual(self, other),
                c.Py_LT => callBinary("__lt__", self, other),
                c.Py_LE => callBinary("__le__", self, other),
                c.Py_GT => callBinary("__gt__", self, other),
                c.Py_GE => callBinary("__ge__", self, other),
                else => null,
            };
        }

        fn notEqual(self: *c.PyObject, other: *c.PyObject) errors.Error!?Object {
            if (comptime Special.has("__ne__") or !Special.has("__eq__")) return callBinary("__ne__", self, other);
            return negate(try callBinary("__eq__", self, other));
        }

        fn callBinary(comptime method: [:0]const u8, self: *c.PyObject, other: *c.PyObject) errors.Error!?Object {
            return callOperator(Special, method, self, other, .{});
        }

        fn negate(result: ?Object) errors.Error!?Object {
            const obj = result orelse return null;
            defer obj.deinit();

            const is_true = c.PyObject_IsTrue(obj.ptr);
            try errors.check(is_true);
            return try conversion.toPython(is_true == 0);
        }

        fn hash(self: [*c]c.PyObject) callconv(.c) c.Py_hash_t {
            const value = Special.callValue("__hash__", 0, self.?, .{}) catch return -1;
            if (@typeInfo(@TypeOf(value)) != .int) @compileError(context ++ ": __hash__ must return an integer");
            const result = hashOf(value);
            // -1 means an error to CPython.
            return if (result == -1) -2 else result;
        }

        fn identityHash(self: [*c]c.PyObject) callconv(.c) c.Py_hash_t {
            return api.typeSlot(c.hashfunc, &c.PyBaseObject_Type, "tp_hash", c.Py_tp_hash).?(self);
        }

        fn truth(self: [*c]c.PyObject) callconv(.c) c_int {
            const value = Special.callValue("__bool__", 0, self.?, .{}) catch return -1;
            if (@TypeOf(value) != bool) @compileError(context ++ ": __bool__ must return bool");
            return @intFromBool(value);
        }
    };
}

fn callOperator(
    comptime Special: type,
    comptime method: [:0]const u8,
    self: *c.PyObject,
    other: *c.PyObject,
    extra: anytype,
) errors.Error!?Object {
    if (comptime !Special.has(method)) return null;
    const result = try switch (extra.len) {
        0 => Special.callObject(method, 1, self, .{other}, .not_implemented),
        1 => callPower(Special, method, self, other, extra[0]),
        else => comptime unreachable,
    } orelse return null;

    if (result.ptr == api.notImplemented()) {
        result.deinit();
        return null;
    }
    return result;
}

fn callPower(
    comptime Special: type,
    comptime method: [:0]const u8,
    self: *c.PyObject,
    other: *c.PyObject,
    modulo: *c.PyObject,
) errors.Error!?Object {
    switch (comptime Special.parameterCount(method)) {
        1 => {
            if (modulo != api.none()) return null;
            return Special.callObject(method, 1, self, .{other}, .not_implemented);
        },
        2 => {
            if (@typeInfo(Special.Call(method, 2).ParamType(1)) != .optional) {
                @compileError(Special.context ++ ": the modulo parameter of " ++ method ++ " must be optional, " ++
                    "such as ?i64, because a ** b passes none");
            }
            return Special.callObject(method, 2, self, .{ other, modulo }, .not_implemented);
        },
        else => @compileError(Special.context ++ ": " ++ method ++ " must take the other operand, and optionally a " ++
            "modulo, after the instance"),
    }
}

fn fromSubclass(a: *c.PyObject, b: *c.PyObject) bool {
    return class.isZigClass(api.typeOf(b)) and isSubtype(b, a);
}

fn isSubtype(b: *c.PyObject, a: *c.PyObject) bool {
    return api.typeOf(b) != api.typeOf(a) and c.PyType_IsSubtype(api.typeOf(b), api.typeOf(a)) != 0;
}

fn slotResult(result: errors.Error!?Object) [*c]c.PyObject {
    const obj = result catch return null;
    return if (obj) |found| found.ptr else notImplemented();
}

fn hasSlot(comptime op: BinaryOp, obj: *c.PyObject, func: anytype) bool {
    if (api.limited) return c.PyType_GetSlot(api.typeOf(obj), op.slot) == @as(*const anyopaque, func);
    const number = api.typeOf(obj).*.tp_as_number orelse return false;
    return @field(number.*, op.field) == @as(@FieldType(c.PyNumberMethods, op.field), func);
}

fn definesAny(comptime Special: type, comptime methods: []const []const u8) bool {
    for (methods) |method| {
        if (Special.has(method)) return true;
    }
    return false;
}

fn hashOf(value: anytype) c.Py_hash_t {
    const V = @TypeOf(value);
    const fits = std.math.minInt(V) >= std.math.minInt(c.Py_hash_t) and std.math.maxInt(V) <= std.math.maxInt(c.Py_hash_t);
    if (comptime fits) return value;

    const raw: @Int(.unsigned, @bitSizeOf(V)) = @bitCast(value);
    const truncated: @Int(.unsigned, @bitSizeOf(c.Py_hash_t)) = @truncate(raw);
    return @bitCast(truncated);
}

fn notImplemented() *c.PyObject {
    return Object.borrow(api.notImplemented()).newRef().ptr;
}
