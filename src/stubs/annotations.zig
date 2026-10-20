const std = @import("std");

const class = @import("../class.zig");
const enum_class = @import("../enum_class.zig");
const reflection = @import("../runtime/reflection.zig");
const stubs = @import("../stubs.zig");
const syntax = @import("../syntax.zig");
const Args = @import("../types/Args.zig");
const buffer = @import("../types/buffer.zig");
const Bytes = @import("../types/Bytes.zig");
const class_object = @import("../types/class_object.zig");
const Dict = @import("../types/Dict.zig");
const Exception = @import("../types/Exception.zig");
const instance = @import("../types/instance.zig");
const iterator = @import("../types/iterator.zig");
const Kwargs = @import("../types/Kwargs.zig");
const List = @import("../types/List.zig");
const Object = @import("../types/Object.zig");
const owned = @import("../types/owned.zig");
const sequence = @import("../types/sequence.zig");
const set = @import("../types/set.zig");
const Str = @import("../types/Str.zig");
const Tuple = @import("../types/Tuple.zig");

/// The annotation context: parameter types may accept more inputs than return types produce.
pub const Position = enum { argument, result };

/// Write the Python annotation for values of the Zig type `T`.
pub fn annotation(comptime T: type, comptime position: Position, comptime context: stubs.Context) []const u8 {
    const any = context.typing("Any");
    if (T == Object) return if (position == .argument) context.builtin("object") else any;
    if (T == Str) return context.builtin("str");
    if (T == Bytes) return context.builtin("bytes");
    if (T == List) return context.builtin("list") ++ "[" ++ any ++ "]";
    if (T == Tuple) return context.builtin("tuple") ++ "[" ++ any ++ ", ...]";
    if (T == Dict) return context.builtin("dict") ++ "[" ++ any ++ ", " ++ any ++ "]";
    if (T == set.Set) return context.builtin("set") ++ "[" ++ any ++ "]";
    if (T == set.FrozenSet) return context.builtin("frozenset") ++ "[" ++ any ++ "]";
    if (T == Exception) return context.builtin("BaseException");
    if (T == Args or T == Kwargs) return any;

    return switch (@typeInfo(T)) {
        .int, .comptime_int => context.builtin("int"),
        .float, .comptime_float => context.builtin("float"),
        .bool => context.builtin("bool"),
        .void, .null => "None",
        .enum_literal => context.builtin("str"),
        .optional => |info| annotation(info.child, position, context) ++ " | None",
        .error_union => |info| annotation(info.payload, position, context),
        .@"enum" => enumAnnotation(T, context),
        .pointer => |info| pointerAnnotation(info, position, context),
        .array => |info| listAnnotation(info.child, position, context),
        .@"struct" => |info| structAnnotation(T, info, position, context),
        else => any,
    };
}

fn enumAnnotation(comptime T: type, comptime context: stubs.Context) []const u8 {
    if (enum_class.isEnumClass(T)) return knownName(T, context) orelse context.typing("Any");

    var text: []const u8 = context.typing("Literal") ++ "[";
    for (@typeInfo(T).@"enum".field_names, 0..) |tag, i| {
        if (i > 0) text = text ++ ", ";
        text = text ++ (syntax.string(tag, '"') orelse "...");
    }
    return text ++ "]";
}

fn pointerAnnotation(comptime info: std.lang.Type.Pointer, comptime position: Position, comptime context: stubs.Context) []const u8 {
    switch (info.size) {
        .slice => return listAnnotation(info.child, position, context),
        .one => {},
        else => return context.typing("Any"),
    }
    if (class.isClass(info.child)) return knownName(info.child, context) orelse context.typing("Any");

    const array = switch (@typeInfo(info.child)) {
        .array => |array| array,
        else => return context.typing("Any"),
    };
    if (array.child == u8 and array.sentinel() == 0) return context.builtin("str");
    return listAnnotation(array.child, position, context);
}

fn listAnnotation(comptime Item: type, comptime position: Position, comptime context: stubs.Context) []const u8 {
    if (Item == u8) return context.builtin("bytes");
    return context.builtin("list") ++ "[" ++ annotation(Item, position, context) ++ "]";
}

fn structAnnotation(comptime T: type, comptime info: std.lang.Type.Struct, comptime position: Position, comptime context: stubs.Context) []const u8 {
    const any = context.typing("Any");
    if (info.is_tuple) {
        const tuple = context.builtin("tuple");
        if (info.field_types.len == 0) return tuple ++ "[()]";
        var text: []const u8 = tuple ++ "[";
        for (info.field_types, 0..) |Field, i| text = text ++ (if (i > 0) ", " else "") ++ annotation(Field, position, context);
        return text ++ "]";
    }

    if (class.isClass(T)) return knownName(T, context) orelse any;
    if (class_object.isClassObject(T)) return context.builtin("type") ++ "[" ++ (knownName(T.Value, context) orelse any) ++ "]";
    if (instance.isInstanceType(T)) return knownName(T.Value, context) orelse any;
    if (owned.isOwned(T)) return annotation(@FieldType(T, "value"), position, context);
    if (buffer.isBuffer(T)) return context.abc("Buffer");
    if (iterator.isIterator(T)) {
        const kind = if (position == .argument) "Iterable" else "Iterator";
        return context.abc(kind) ++ "[" ++ annotation(T.Item, position, context) ++ "]";
    }
    if (sequence.isSequence(T)) {
        const kind = if (position == .argument) "Iterable" else "Sequence";
        return context.abc(kind) ++ "[" ++ annotation(T.Item, position, context) ++ "]";
    }

    if (reflection.isConversionType(T)) return any;
    const key = context.builtin("str") ++ ", " ++ any;
    return if (position == .argument) context.abc("Mapping") ++ "[" ++ key ++ "]" else context.builtin("dict") ++ "[" ++ key ++ "]";
}

/// Get the annotation name for an exported class or exception, qualified if necessary.
pub fn knownName(comptime T: type, comptime context: stubs.Context) ?[]const u8 {
    for (context.known) |entry| {
        if (entry.type == T) {
            return if (std.mem.eql(u8, entry.module, context.module)) entry.name else context.qualify(entry.module, entry.name);
        }
    }
    return null;
}
