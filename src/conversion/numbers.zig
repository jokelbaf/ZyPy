const std = @import("std");
const builtin = @import("builtin");
const c = @import("python");

const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const Bytes = @import("../types/Bytes.zig");
const Object = @import("../types/Object.zig");

const native_bytes = 0x030E0000;

const endian = if (builtin.cpu.arch.endian() == .little) "little" else "big";

/// Convert an `int`, or an object with `__index__`, to the integer type `T`.
pub fn intFromPython(comptime T: type, obj: Object) errors.Error!T {
    if (comptime !api.hasLimited(native_bytes)) return intFromIndex(T, obj);

    const info = @typeInfo(T).int;
    // A u0 still needs a byte: PyLong_AsNativeBytes asks for one to hold 0.
    const Whole = @Int(info.signedness, @max(1, @sizeOf(T)) * 8);
    const flags = c.Py_ASNATIVEBYTES_NATIVE_ENDIAN | c.Py_ASNATIVEBYTES_ALLOW_INDEX | switch (info.signedness) {
        .signed => 0,
        .unsigned => c.Py_ASNATIVEBYTES_UNSIGNED_BUFFER | c.Py_ASNATIVEBYTES_REJECT_NEGATIVE,
    };

    var whole: Whole = undefined;
    const needed = c.PyLong_AsNativeBytes(obj.ptr, &whole, @sizeOf(Whole), flags);
    if (needed < 0) return error.PythonError;
    if (needed > @sizeOf(Whole)) return outOfRange(T);

    return std.math.cast(T, whole) orelse outOfRange(T);
}

/// Convert an integer of type `T` to an `int`.
pub fn intToPython(comptime T: type, value: T) errors.Error!Object {
    const info = @typeInfo(T).int;
    if (info.bits <= 64) return .own(switch (info.signedness) {
        .signed => c.PyLong_FromLongLong(value),
        .unsigned => c.PyLong_FromUnsignedLongLong(value),
    });

    const Whole = @Int(info.signedness, @sizeOf(T) * 8);
    const whole: Whole = value;
    if (comptime !api.hasLimited(native_bytes)) {
        const bytes = try Bytes.init(std.mem.asBytes(&whole));
        defer bytes.deinit();

        const int: Object = .borrow(@ptrCast(@alignCast(&c.PyLong_Type)));
        return int.callMethodKw(Object, "from_bytes", .{ bytes, endian }, .{ .signed = info.signedness == .signed });
    }
    return .own(switch (info.signedness) {
        .signed => c.PyLong_FromNativeBytes(&whole, @sizeOf(Whole), c.Py_ASNATIVEBYTES_NATIVE_ENDIAN),
        .unsigned => c.PyLong_FromUnsignedNativeBytes(&whole, @sizeOf(Whole), c.Py_ASNATIVEBYTES_NATIVE_ENDIAN),
    });
}

fn intFromIndex(comptime T: type, obj: Object) errors.Error!T {
    const info = @typeInfo(T).int;
    const index = try Object.own(c.PyNumber_Index(obj.ptr));
    defer index.deinit();

    if (info.bits > 64) {
        const zero = try Object.own(c.PyLong_FromLong(0));
        defer zero.deinit();

        const negative = c.PyObject_RichCompareBool(index.ptr, zero.ptr, c.Py_LT);
        try errors.check(negative);
        if (info.signedness == .unsigned and negative == 1) return errors.raise(.ValueError, "Cannot convert negative int");

        const Whole = @Int(info.signedness, @sizeOf(T) * 8);
        const bytes = index.callMethodKw(Bytes, "to_bytes", .{ @sizeOf(Whole), endian }, .{
            .signed = info.signedness == .signed,
        }) catch return overflowAsOutOfRange(T);
        defer bytes.deinit();

        var whole: Whole = undefined;
        @memcpy(std.mem.asBytes(&whole), bytes.slice());
        return std.math.cast(T, whole) orelse outOfRange(T);
    }

    var overflow: c_int = 0;
    const value = c.PyLong_AsLongLongAndOverflow(index.ptr, &overflow);
    if (value == -1 and c.PyErr_Occurred() != null) return error.PythonError;

    const negative = overflow < 0 or (overflow == 0 and value < 0);
    if (info.signedness == .unsigned and negative) return errors.raise(.ValueError, "Cannot convert negative int");
    if (overflow == 0) return std.math.cast(T, value) orelse outOfRange(T);
    if (info.signedness == .signed or info.bits < 64) return outOfRange(T);

    const large = c.PyLong_AsUnsignedLongLong(index.ptr);
    if (large == std.math.maxInt(c_ulonglong) and c.PyErr_Occurred() != null) return overflowAsOutOfRange(T);
    return std.math.cast(T, large) orelse outOfRange(T);
}

fn overflowAsOutOfRange(comptime T: type) errors.Error {
    if (c.PyErr_ExceptionMatches(c.PyExc_OverflowError) == 0) return error.PythonError;
    c.PyErr_Clear();
    return outOfRange(T);
}

fn outOfRange(comptime T: type) errors.Error {
    return errors.raise(.OverflowError, "int out of range for " ++ @typeName(T));
}

/// Convert a `float`, or an object with `__float__` or `__index__`, to the float type `T`.
pub fn floatFromPython(comptime T: type, obj: Object) errors.Error!T {
    const value = c.PyFloat_AsDouble(obj.ptr);
    if (value == -1.0 and c.PyErr_Occurred() != null) return error.PythonError;
    return @floatCast(value);
}

/// Get the truth value of any object, as `bool(obj)` does.
pub fn boolFromPython(obj: Object) errors.Error!bool {
    const truth = c.PyObject_IsTrue(obj.ptr);
    try errors.check(truth);
    return truth != 0;
}
