const std = @import("std");

const class = @import("../class.zig");
const syntax = @import("../syntax.zig");
const slots = @import("slots.zig");

/// Validate exposed fields, properties, and methods of `T`. Names must be valid and unique.
/// `context` identifies the class in errors.
pub fn check(comptime T: type, comptime context: []const u8) void {
    @setEvalBranchQuota(100_000);
    const definition = class.Definition(T);
    const fields = names(definition.fields);
    const properties = names(definition.properties);
    const methods = names(definition.methods);

    for (fields) |field| {
        if (!@hasField(T, field)) {
            @compileError(context ++ ": .fields has '" ++ field ++ "', which isn't a field of " ++ @typeName(T));
        }
        checkAttribute(context, ".fields", "field", field, definition.dict);
    }
    for (properties) |property| checkAttribute(context, ".properties", "property", property, definition.dict);
    for (methods) |method| {
        syntax.checkName(context ++ ": .methods", "method name", method);
        if (definition.dict and std.mem.eql(u8, method, "__dict__")) {
            @compileError(context ++ ": the class has .dict, so it can't have a method named '__dict__'");
        }
    }

    checkDistinct(context, "field", fields, "property", properties);
    checkDistinct(context, "field", fields, "method", methods);
    checkDistinct(context, "property", properties, "method", methods);
}

fn names(comptime section: anytype) []const [:0]const u8 {
    return @typeInfo(@TypeOf(section)).@"struct".field_names;
}

fn checkAttribute(
    comptime context: []const u8,
    comptime section: []const u8,
    comptime kind: []const u8,
    comptime name: []const u8,
    comptime dict: bool,
) void {
    syntax.checkName(context ++ ": " ++ section, "attribute name", name);
    if (dict and std.mem.eql(u8, name, "__dict__")) {
        @compileError(context ++ ": the class has .dict, so it can't have a " ++ kind ++ " named '__dict__'");
    }
    // Python looks special methods up on the type, where slot wrappers would hide the attribute.
    if (slots.isSpecialName(name)) {
        @compileError(context ++ ": '" ++ name ++ "' is the name of a special method, so it can't be a " ++ kind);
    }
}

fn checkDistinct(
    comptime context: []const u8,
    comptime first_kind: []const u8,
    comptime first: []const [:0]const u8,
    comptime second_kind: []const u8,
    comptime second: []const [:0]const u8,
) void {
    for (first) |name| {
        for (second) |other| {
            if (std.mem.eql(u8, name, other)) {
                @compileError(context ++ ": '" ++ name ++ "' is both a " ++ first_kind ++ " and a " ++ second_kind);
            }
        }
    }
}
