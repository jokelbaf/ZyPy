const std = @import("std");

const enum_class = @import("../enum_class.zig");
const function = @import("../function.zig");
const syntax = @import("../syntax.zig");

/// Check whether `T` can use a Zig default value without creating Python objects or views.
pub fn isPlain(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .void => true,
        .@"enum" => !std.meta.hasFn(T, "fromPython"),
        .optional => |info| isPlain(info.child),
        .pointer => T == []const u8,
        .@"struct" => |info| !std.meta.hasFn(T, "fromPython") and allPlain(info.field_types),
        else => false,
    };
}

fn allPlain(comptime types: []const type) bool {
    for (types) |Type| {
        if (!isPlain(Type)) return false;
    }
    return true;
}

/// Convert a default value to `T`, reporting incompatible types or out-of-range values.
pub fn coerce(comptime T: type, comptime value: anytype, comptime what: []const u8) T {
    const V = @TypeOf(value);
    if (V == T) return value;

    const fits = switch (@typeInfo(T)) {
        .optional => |info| return if (V == @TypeOf(null)) null else coerce(info.child, value, what),
        .int => V == comptime_int or @typeInfo(V) == .int,
        .float => V == comptime_float or V == comptime_int or @typeInfo(V) == .float,
        .bool => V == bool,
        .@"enum" => V == @EnumLiteral(),
        else => true,
    };
    if (!fits) @compileError(what ++ " must have type " ++ @typeName(T) ++ ", not " ++ @typeName(V));

    switch (@typeInfo(T)) {
        .int => return std.math.cast(T, value) orelse @compileError(what ++ " is out of range for " ++ @typeName(T)),
        .@"enum" => {
            if (!@hasField(T, @tagName(value))) {
                @compileError(what ++ " ." ++ @tagName(value) ++ " isn't a tag of " ++ @typeName(T));
            }
            return @field(T, @tagName(value));
        },
        else => return value,
    }
}

/// Render a default `value` of type `T` as Python code, or `...` if it has no literal.
pub fn render(comptime T: type, comptime value: anytype, comptime what: []const u8) []const u8 {
    const V = @TypeOf(value);
    if (V == @TypeOf(null)) return "None";
    if (V == T and @typeInfo(T) == .@"struct" and @hasDecl(T, "zypy_owned")) {
        return render(@FieldType(T, "value"), value.value, what);
    }
    if (isPlain(T)) return renderValue(T, coerce(T, value, what));
    return renderValue(V, value);
}

fn renderValue(comptime T: type, comptime value: T) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => if (value) "True" else "False",
        .int, .comptime_int => std.fmt.comptimePrint("{d}", .{value}),
        .float, .comptime_float => syntax.float(value) orelse "...",
        .optional => |info| if (value) |inner| renderValue(info.child, inner) else "None",
        // inspect accepts only literals in text signatures, so enum members cannot appear here.
        .@"enum" => if (enum_class.isEnumClass(T)) "..." else syntax.string(@tagName(value), '\'') orelse "...",
        .enum_literal => syntax.string(@tagName(value), '\'') orelse "...",
        .pointer => renderText(T, value),
        else => "...",
    };
}

fn renderText(comptime T: type, comptime value: T) []const u8 {
    if (T == []const u8) return syntax.bytes(value);
    if (!function.isText(T)) return "...";
    return syntax.string(value, '\'') orelse "...";
}
