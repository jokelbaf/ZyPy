const std = @import("std");

const class = @import("../class.zig");
const function = @import("../function.zig");
const ownership = @import("../runtime/ownership.zig");

/// A constructor taking one argument per runtime field, in declaration order.
/// Arguments move into the new instance.
pub fn FieldConstructor(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    var name_list: []const [:0]const u8 = &.{};
    var type_list: []const type = &.{};
    for (info.field_names, info.field_types, info.field_attrs) |field, Field, attrs| {
        if (attrs.@"comptime") continue;
        if (ownership.holdsByteSlice(Field)) {
            @compileError("field '" ++ field ++ "' of " ++ @typeName(T) ++ " would point into an argument " ++
                "(use py.Bytes, or write an init function that copies it)");
        }
        if (class.isClass(Field) and ownership.hasManualDeinit(Field)) {
            @compileError("field '" ++ field ++ "' of " ++ @typeName(T) ++ " holds a " ++ @typeName(Field) ++
                ", which has a deinit, so the constructor can't copy it from an argument (write an init function)");
        }
        name_list = name_list ++ .{field};
        type_list = type_list ++ .{Field};
    }
    const final_names = name_list[0..name_list.len].*;
    const final_types = type_list[0..type_list.len].*;

    return struct {
        pub const field_names: []const [:0]const u8 = &final_names;
        pub const types: []const type = &final_types;
        pub const Params = @Tuple(&final_types);
        pub const Result = T;
        pub const moves_arguments = true;

        pub fn call(values: Params) T {
            var result: T = undefined;
            inline for (final_names, 0..) |field, i| @field(result, field) = values[i];
            return result;
        }
    };
}

fn FieldDefaults(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    var names: []const []const u8 = &.{};
    var types: []const type = &.{};
    var attrs: []const std.lang.Type.Struct.FieldAttributes = &.{};
    for (info.field_names, info.field_types, info.field_attrs) |field, Field, field_attrs| {
        if (field_attrs.@"comptime" or field_attrs.default_value_ptr == null) continue;
        names = names ++ .{field};
        types = types ++ .{Field};
        attrs = attrs ++ .{std.lang.Type.Struct.FieldAttributes{ .default_value_ptr = field_attrs.default_value_ptr }};
    }
    return @Struct(.auto, null, names, types, attrs);
}

/// Describe the field constructor, including field names and defaults.
pub fn fields(comptime T: type) function.Function(type, struct {
    params: []const [:0]const u8,
    defaults: FieldDefaults(T),
}) {
    return .{ .func = FieldConstructor(T), .options = .{
        .params = FieldConstructor(T).field_names,
        .defaults = .{},
    } };
}

/// Describe the constructor of class `T` for type stubs, or return `null` if Python can't create instances.
pub fn stub(comptime T: type, comptime scope: function.Scope) ?function.Stub {
    const definition = class.Definition(T);
    if (!definition.constructs) return null;
    return function.constructorStub(definition.init, scope);
}
