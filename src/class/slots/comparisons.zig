const std = @import("std");
const c = @import("python");

const conversion = @import("../../conversion.zig");
const errors = @import("../../errors.zig");
const api = @import("../../runtime/api.zig");
const Object = @import("../../types/Object.zig");
const slot = @import("../slots.zig").slot;
const operators = @import("operators.zig");

/// The methods that `tp_richcompare` serves.
pub const methods = [_][]const u8{ "__eq__", "__ne__", "__lt__", "__le__", "__gt__", "__ge__" };

/// The comparison and hash slots for `Special`, a `slots.Methods` type.
pub fn Comparisons(comptime Special: type) type {
    const context = Special.context;
    const compares = definesAny(Special, &methods);

    return struct {
        pub const slots: []const c.PyType_Slot = blk: {
            var list: []const c.PyType_Slot = &.{};
            if (Special.has("__hash__")) {
                list = list ++ .{slot(c.Py_tp_hash, &hash)};
            } else if (compares and !Special.has("__eq__")) {
                // Without __eq__, comparisons don't change equality, so keep the identity hash.
                list = list ++ .{slot(c.Py_tp_hash, &identityHash)};
            }
            if (compares) list = list ++ .{slot(c.Py_tp_richcompare, &richCompare)};
            break :blk list;
        };

        fn richCompare(self: [*c]c.PyObject, other: [*c]c.PyObject, op: c_int) callconv(.c) [*c]c.PyObject {
            return operators.slotResult(compare(self.?, other.?, op));
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
            return operators.callOperator(Special, method, self, other, .{});
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
    };
}

fn definesAny(comptime Special: type, comptime names: []const []const u8) bool {
    for (names) |method| {
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
