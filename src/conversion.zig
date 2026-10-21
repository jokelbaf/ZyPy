const std = @import("std");
const c = @import("python");

const class = @import("class.zig");
const aggregates = @import("conversion/aggregates.zig");
const enums = @import("conversion/enums.zig");
const numbers = @import("conversion/numbers.zig");
const errors = @import("errors.zig");
const api = @import("runtime/api.zig");
const borrowed = @import("runtime/borrowed.zig");
const ownership = @import("runtime/ownership.zig");
const Bytes = @import("types/Bytes.zig");
const List = @import("types/List.zig");
const Object = @import("types/Object.zig");
const Str = @import("types/Str.zig");

/// Convert a Python object to the Zig type `T`. Most object references borrow from `obj`.
/// Structs read from mappings keep their own references. Views such as `py.Buffer(T)` are owned.
/// Release owned references and views with `py.deinit`.
pub fn fromPython(comptime T: type, obj: Object) errors.Error!T {
    if (comptime std.meta.hasFn(T, "fromPython")) {
        comptime checkOwnedField(T);
        return T.fromPython(obj);
    }
    if (comptime class.isClass(T)) return class.copyFrom(T, obj.ptr);

    return switch (@typeInfo(T)) {
        .int => numbers.intFromPython(T, obj),
        .float => numbers.floatFromPython(T, obj),
        .bool => numbers.boolFromPython(obj),
        .optional => |info| if (obj.isNone()) null else try fromPython(info.child, obj),
        .@"enum" => enums.fromPython(T, obj),
        .pointer => pointerFromPython(T, obj),
        .@"struct" => |info| if (info.is_tuple) aggregates.tupleFromPython(T, obj) else aggregates.structFromPython(T, obj),
        else => unsupported(T, ""),
    };
}

fn checkOwnedField(comptime T: type) void {
    if (!ownership.hasOwnedFlag(T) or ownership.isReference(T) or std.meta.hasFn(T, "deinit")) return;
    @compileError(@typeName(T) ++ " has an owned field but no deinit: a value with an owned field owns what its " ++
        "fromPython returns and releases it in deinit (remove the field if the value only borrows from the object)");
}

fn pointerFromPython(comptime T: type, obj: Object) errors.Error!T {
    if (T == []const u8) return (try Bytes.fromPython(obj)).slice();

    const Class = comptime ownership.pointedClass(T) orelse
        unsupported(T, "use []const u8, py.Bytes or py.Buffer(T); other pointers convert only to classes");
    return class.checkInstance(Class, obj.ptr);
}

/// Convert a Zig value to an owned Python object without changing the value.
pub fn toPython(value: anytype) errors.Error!Object {
    const T = @TypeOf(value);
    if (comptime std.meta.hasFn(T, "toPython")) return value.toPython();
    if (comptime class.isClass(T)) return class.copyInto(T, value);

    return switch (@typeInfo(T)) {
        .int => numbers.intToPython(T, value),
        .comptime_int => numbers.intToPython(std.math.IntFittingRange(value, value), value),
        .float => .own(c.PyFloat_FromDouble(@floatCast(value))),
        .comptime_float => .own(c.PyFloat_FromDouble(value)),
        .bool => .own(c.PyBool_FromLong(@intFromBool(value))),
        .void, .null => none(),
        .optional => if (value) |v| toPython(v) else none(),
        .@"enum" => enums.toPython(value),
        .enum_literal => (try Str.init(@tagName(value))).obj,
        .array => toPython(&value),
        .pointer => pointerToPython(value),
        .@"struct" => |info| if (info.is_tuple) aggregates.tupleToPython(value) else aggregates.structToPython(value),
        else => unsupported(T, ""),
    };
}

/// Convert a Zig value to an owned Python object, consuming the value even on failure.
pub fn intoPython(value: anytype) errors.Error!Object {
    const T = @TypeOf(value);
    if (comptime class.isClass(T)) return class.moveInto(T, value);
    if (@typeInfo(T) == .optional and comptime class.isClass(@typeInfo(T).optional.child)) {
        return if (value) |inner| class.moveInto(@TypeOf(inner), inner) else none();
    }

    defer ownership.deinit(value);
    return toPythonHeld(value);
}

/// Convert `value` to an owned Python object, keeping borrowed references alive during conversion.
pub fn toPythonHeld(value: anytype) errors.Error!Object {
    const T = @TypeOf(value);
    // Reference conversion cannot call Python; owning values cannot be safely retained.
    const Reference = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    if (comptime ownership.isReference(Reference) or ownership.ownsResources(T)) return toPython(value);

    const held = ownership.retain(ownership.lend(value));
    defer ownership.deinit(held);
    return toPython(held);
}

/// Convert an owned container item to `T`, consuming its reference.
/// Object references borrow from the container. Free-threaded calls keep the item alive until they return.
pub fn fromItem(comptime T: type, item: Object) errors.Error!T {
    const value = fromPython(T, item) catch |err| {
        item.deinit();
        return err;
    };
    try settle(T, value, item);
    return value;
}

/// Release the container item used to create `value`.
/// On free-threaded Python, retain it until the call returns if `value` borrows its data.
/// Release `value` if retaining the item fails.
pub fn settle(comptime T: type, value: T, item: Object) errors.Error!void {
    if (comptime !borrowed.enabled or !ownership.dependsOnSource(T)) return item.deinit();

    borrowed.keep(item) catch |err| {
        ownership.deinit(value);
        return err;
    };
}

/// Convert an owned Python object to `T` and consume its reference.
/// References and views in the result are owned. Use `void` to release the object without a result.
pub fn take(comptime T: type, obj: Object) errors.Error!T {
    const context = "ZyPy can't convert a new object to " ++ @typeName(T);
    if (comptime ownership.holdsByteSlice(T)) {
        @compileError(context ++ ": a []const u8 would point into an object that is released right away (use py.Bytes)");
    }
    if (comptime ownership.pointedClass(T)) |Class| {
        @compileError(context ++ ": the pointer would point into an object that is released right away (use " ++
            "py.Instance(" ++ @typeName(Class) ++ "))");
    }
    if (comptime ownership.holdsOpaque(T)) {
        @compileError(context ++ ": ZyPy can't tell which references it holds (convert to py.Object, then use as())");
    }

    if (comptime ownership.isReference(T)) {
        errdefer obj.deinit();
        return ownership.owning(try fromPython(T, obj));
    }

    defer obj.deinit();
    if (T == void) return;
    return ownership.retain(try fromPython(T, obj));
}

/// Report that ZyPy can't convert `T`, with a `hint` on what to use instead.
pub fn unsupported(comptime T: type, comptime hint: []const u8) noreturn {
    @compileError("ZyPy can't convert " ++ @typeName(T) ++ (if (hint.len > 0) " (" ++ hint ++ ")" else ""));
}

fn none() Object {
    return Object.borrow(api.none()).newRef();
}

fn pointerToPython(value: anytype) errors.Error!Object {
    const T = @TypeOf(value);
    if (comptime isStringLiteral(T)) return (try Str.init(value)).obj;
    if (comptime !isSliceLike(T)) unsupported(T, classPointerHint(T));

    return if (std.meta.Elem(T) == u8) (try Bytes.init(value)).obj else (try List.fromSlice(value)).obj;
}

fn classPointerHint(comptime T: type) []const u8 {
    const info = @typeInfo(T).pointer;
    if (info.size == .one and class.isClass(info.child)) {
        return "return " ++ @typeName(info.child) ++ " or py.Instance(" ++ @typeName(info.child) ++ ") instead";
    }
    return "use a slice, or a pointer to an array";
}

/// Check whether `T` is the type of a string literal: `*const [N:0]u8`.
pub fn isStringLiteral(comptime T: type) bool {
    const pointer = switch (@typeInfo(T)) {
        .pointer => |info| info,
        else => return false,
    };
    return switch (@typeInfo(pointer.child)) {
        .array => |array| pointer.size == .one and array.child == u8 and array.sentinel() == 0,
        else => false,
    };
}

fn isSliceLike(comptime T: type) bool {
    const pointer = @typeInfo(T).pointer;
    return switch (pointer.size) {
        .slice => true,
        .one => @typeInfo(pointer.child) == .array,
        else => false,
    };
}
