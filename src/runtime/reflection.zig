const std = @import("std");

/// Check whether `T` takes part in the conversion protocol: it declares its own `fromPython` or `toPython`.
pub fn isConversionType(comptime T: type) bool {
    return std.meta.hasFn(T, "fromPython") or std.meta.hasFn(T, "toPython");
}

/// Get the type that an optional or an array holds, or `null` for other types.
pub fn elementOf(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .optional => |info| info.child,
        .array => |info| info.child,
        else => null,
    };
}

/// Get the type that a single-item pointer points to, or `null` for other types.
pub fn pointee(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .pointer => |info| if (info.size == .one) info.child else null,
        else => null,
    };
}

/// Get the types of a struct's runtime fields, or `null` for other types. Comptime fields hold no data.
pub fn fieldTypes(comptime T: type) ?[]const type {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => return null,
    };
    var types: []const type = &.{};
    for (info.field_types, info.field_attrs) |Field, attrs| {
        if (!attrs.@"comptime") types = types ++ .{Field};
    }
    return types;
}

/// Check whether `T` is a tuple, such as `struct { i64, f64 }`.
pub fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
}

/// Check whether `predicate` is true for any of `types`.
pub fn any(comptime types: []const type, comptime predicate: fn (type) bool) bool {
    inline for (types) |Type| {
        if (comptime predicate(Type)) return true;
    }
    return false;
}

/// Get the first type that `find` returns for one of `types`, or `null`.
pub fn first(comptime types: []const type, comptime find: fn (type) ?type) ?type {
    inline for (types) |Type| {
        if (comptime find(Type)) |found| return found;
    }
    return null;
}
