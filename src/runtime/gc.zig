const std = @import("std");
const c = @import("python");

const Object = @import("../types/Object.zig");
const owned = @import("../types/owned.zig");
const api = @import("api.zig");
const ownership = @import("ownership.zig");
const reflection = @import("reflection.zig");

/// Check whether values of `T` hold Python references that the garbage collector should see.
pub fn holdsReferences(comptime T: type) bool {
    if (ownership.isReference(T)) return true;
    if (owned.isOwned(T)) return holdsReferences(@FieldType(T, "value"));
    if (reflection.elementOf(T)) |Element| return holdsReferences(Element);

    const fields = reflection.fieldTypes(T) orelse return false;
    if (std.meta.hasFn(T, "fromPython")) return false;
    return reflection.any(fields, holdsReferences);
}

/// Call `visitor` on each Python reference in `value.*` for `tp_traverse`.
/// Stop at the first nonzero result.
pub fn visit(value: anytype, visitor: c.visitproc, arg: ?*anyopaque) c_int {
    const T = @typeInfo(@TypeOf(value)).pointer.child;
    if (comptime !holdsReferences(T)) return 0;

    if (T == Object) return visitor.?(value.ptr, arg);
    if (comptime ownership.isReference(T)) return visit(&value.obj, visitor, arg);
    if (comptime owned.isOwned(T)) return visit(&value.value, visitor, arg);

    switch (@typeInfo(T)) {
        .optional => if (value.*) |*inner| return visit(inner, visitor, arg),
        .array => for (value) |*item| {
            const result = visit(item, visitor, arg);
            if (result != 0) return result;
        },
        .@"struct" => |info| inline for (info.field_names, info.field_attrs) |name, attrs| {
            if (!attrs.@"comptime") {
                const result = visit(&@field(value, name), visitor, arg);
                if (result != 0) return result;
            }
        },
        else => {},
    }
    return 0;
}

/// Release references in `value.*` to break cycles. Replace optional references with `null` and others with `None`.
/// Later cleanup remains safe.
pub fn clear(value: anytype) void {
    const T = @typeInfo(@TypeOf(value)).pointer.child;
    if (comptime !holdsReferences(T)) return;

    if (T == Object) {
        const old = value.*;
        // None is immortal, so releasing it again later does nothing.
        value.* = .{ .ptr = api.none(), .owned = true };
        return old.deinit();
    }
    if (comptime ownership.isReference(T)) return clear(&value.obj);
    if (comptime owned.isOwned(T)) return clear(&value.value);

    switch (@typeInfo(T)) {
        .optional => if (value.*) |*inner| {
            if (comptime ownership.isReference(@TypeOf(inner.*))) {
                const old = inner.*;
                value.* = null;
                return old.deinit();
            }
            clear(inner);
        },
        .array => for (value) |*item| clear(item),
        .@"struct" => |info| inline for (info.field_names, info.field_attrs) |name, attrs| {
            if (!attrs.@"comptime") clear(&@field(value, name));
        },
        else => {},
    }
}

/// Check whether `T` holds Python references or views outside `py.Owned` fields.
/// Classes and module state reject these fields because copies would share ownership.
pub fn holdsUnmanaged(comptime T: type) bool {
    if (owned.isOwned(T)) return false;
    if (ownership.isReference(T) or reflection.isConversionType(T)) return true;
    if (reflection.elementOf(T)) |Element| return holdsUnmanaged(Element);

    const fields = reflection.fieldTypes(T) orelse return false;
    return reflection.any(fields, holdsUnmanaged);
}

/// Check that class or module state fields use `py.Owned` for Python references.
/// Reject raw pointers into class instances because they do not keep the instance alive.
pub fn checkFields(comptime T: type, comptime context: []const u8) void {
    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_types) |name, Field| {
        if (ownership.pointedClass(Field)) |Class| {
            @compileError(context ++ ": field '" ++ name ++ "' points into an instance of " ++ @typeName(Class) ++
                " without keeping it alive, so declare it as py.Owned(py.Instance(" ++ @typeName(Class) ++ "))");
        }
        if (holdsUnmanaged(Field)) {
            @compileError(context ++ ": field '" ++ name ++ "' holds Python objects, so declare it as py.Owned(" ++
                pythonTypeName(Field) ++ "), which keeps a reference for " ++ @typeName(T) ++
                " (read it with get, change it with set)");
        }
    }
}

fn pythonTypeName(comptime T: type) []const u8 {
    const name = @typeName(T);
    var text: []const u8 = "";
    var i = 0;
    while (i < name.len) : (i += 1) {
        if (std.mem.startsWith(u8, name[i..], "types.") and (i == 0 or !std.ascii.isAlphanumeric(name[i - 1]))) {
            text = text ++ "py.";
            i += "types.".len - 1;
        } else {
            text = text ++ name[i .. i + 1];
        }
    }
    return text;
}
