const std = @import("std");

const class = @import("../class.zig");
const attributes = @import("../class/attributes.zig");
const slots = @import("../class/slots.zig");
const enum_class = @import("../enum_class.zig");
const function = @import("../function.zig");
const stubs = @import("../stubs.zig");
const syntax = @import("../syntax.zig");
const annotations = @import("annotations.zig");
const annotation = annotations.annotation;

const Writer = std.Io.Writer;

pub fn writeException(comptime Type: type, comptime name: [:0]const u8, comptime context: stubs.Context, w: *Writer) !void {
    const base = comptime if (@TypeOf(Type.base) == @EnumLiteral())
        context.builtin(@tagName(Type.base))
    else
        annotations.knownName(Type.base, context) orelse context.builtin("Exception");
    try w.print("class {s}({s}):", .{ name, base });

    if (Type.doc) |doc| {
        try w.writeAll("\n");
        try writeDocstring(w, doc, "    ");
    } else {
        try w.writeAll(" ...\n");
    }
}

/// Write an `enum.Enum` class with one member per tag, valued like the tag.
pub fn writeEnum(comptime T: type, comptime name: [:0]const u8, comptime context: stubs.Context, w: *Writer) !void {
    try w.print("class {s}({s}):\n", .{ name, comptime context.qualify("enum", "Enum") });
    if (enum_class.Definition(T).doc) |doc| try writeDocstring(w, doc, "    ");
    for (std.enums.values(T)) |tag| try w.print("    {s} = {d}\n", .{ @tagName(tag), @backingInt(tag) });
}

pub fn writeClass(comptime T: type, comptime name: [:0]const u8, comptime Module: type, comptime context: stubs.Context, w: *Writer) !void {
    const definition = class.Definition(T);
    const scope: function.Scope = .{ .Module = Module, .Class = T, .class_name = name };
    const Methods = @TypeOf(definition.methods);
    const inner = comptime context.inClass(members(T));

    if (!definition.subclassable) try w.print("@{s}\n", .{comptime context.typing("final")});
    if (definition.Base) |Base| {
        try w.print("class {s}({s}):\n", .{ name, comptime annotations.knownName(Base, context).? });
    } else {
        try w.print("class {s}:\n", .{name});
    }

    var empty = true;
    if (definition.doc) |doc| {
        try writeDocstring(w, doc, "    ");
        empty = false;
    }

    inline for (@typeInfo(@TypeOf(definition.fields)).@"struct".field_names) |field| {
        const Field = @FieldType(T, field);
        if (@field(definition.fields, field) == .read_write) {
            try w.print("    {s}: {s}\n", .{ field, comptime annotation(Field, .result, inner) });
        } else {
            try w.print("    @{s}\n{s}    def {s}(self) -> {s}: ...\n", .{
                comptime inner.builtin("property"),         comptime overrideLine(T, field, inner), field,
                comptime annotation(Field, .result, inner),
            });
        }
        empty = false;
    }

    inline for (@typeInfo(@TypeOf(definition.properties)).@"struct".field_names) |property| {
        try writeProperty(property, @field(definition.properties, property), scope, comptime overrideLine(T, property, inner), inner, w);
        empty = false;
    }

    if (comptime class.constructorStub(T, scope)) |constructor| {
        try writeFunction("__init__", constructor, .constructor, "    ", inner, w);
        empty = false;
    }
    if (comptime declaresImplicitly(T, "__iter__")) {
        try w.print("    def __iter__(self) -> {s}: ...\n", .{comptime inner.typing("Self")});
    }
    if (comptime declaresImplicitly(T, "__hash__")) {
        try w.print("    __hash__: {s}[None]\n", .{comptime inner.typing("ClassVar")});
    }
    if (comptime declaresImplicitly(T, "__dict__")) {
        try w.print("    __dict__: {s}[{s}, {s}]\n", .{
            comptime inner.builtin("dict"), comptime inner.builtin("str"), comptime inner.typing("Any"),
        });
        empty = false;
    }

    inline for (@typeInfo(Methods).@"struct".field_names) |method| {
        const entry = @field(definition.methods, method);
        if (comptime slots.isSpecial("'" ++ name ++ "'", method)) {
            try w.writeAll(comptime overrideLine(T, method, inner));
            try writeSpecial(method, entry, scope, inner, w);
        } else {
            const stub = function.stub(method, entry, scope);
            const receiver: Receiver, const decorator = comptime switch (stub.mode) {
                .method => .{ .instance, "" },
                .static => .{ .none, "    @" ++ inner.builtin("staticmethod") ++ "\n" },
                .class_method => .{ .class, "    @" ++ inner.builtin("classmethod") ++ "\n" },
                .function, .constructor => unreachable,
            };
            try w.writeAll(decorator ++ comptime overrideLine(T, method, inner));
            try writeFunction(method, stub, receiver, "    ", inner, w);
        }
        empty = false;
    }

    if (empty) try w.writeAll("    ...\n");
}

fn overrideLine(comptime T: type, comptime name: []const u8, comptime context: stubs.Context) []const u8 {
    for (class.bases(T)) |Base| {
        if (declares(Base, name)) return "    @" ++ context.typing("override") ++ "\n";
    }
    return "";
}

/// Get the names that the stub of class `T` defines in its body.
pub fn members(comptime T: type) []const []const u8 {
    const definition = class.Definition(T);
    var names: []const []const u8 = &.{"__init__"};
    inline for (.{ "__iter__", "__hash__", "__dict__" }) |name| {
        if (declaresImplicitly(T, name)) names = names ++ .{name};
    }
    inline for (.{ definition.fields, definition.properties, definition.methods }) |section| {
        names = names ++ @typeInfo(@TypeOf(section)).@"struct".field_names;
    }
    return names;
}

fn declares(comptime T: type, comptime name: []const u8) bool {
    const definition = class.Definition(T);
    if (@hasField(@TypeOf(definition.methods), name) or @hasField(@TypeOf(definition.fields), name)) return true;
    return @hasField(@TypeOf(definition.properties), name) or declaresImplicitly(T, name);
}

fn declaresImplicitly(comptime T: type, comptime name: []const u8) bool {
    const definition = class.Definition(T);
    const Methods = @TypeOf(definition.methods);
    const Base = definition.Base;
    if (std.mem.eql(u8, name, "__iter__")) return isOwnIterator(T) and !(if (Base) |B| isOwnIterator(B) else false);
    if (std.mem.eql(u8, name, "__hash__")) return @hasField(Methods, "__eq__") and !@hasField(Methods, "__hash__");
    if (std.mem.eql(u8, name, "__dict__")) return definition.dict and !(if (Base) |B| class.Definition(B).dict else false);
    return false;
}

fn isOwnIterator(comptime T: type) bool {
    return class.definer(T, "__next__") != null and class.definer(T, "__iter__") == null;
}

fn writeProperty(
    comptime name: [:0]const u8,
    comptime entry: anytype,
    comptime scope: function.Scope,
    comptime override: []const u8,
    comptime context: stubs.Context,
    w: *Writer,
) !void {
    const definition = attributes.PropertyDefinition(scope.class_name, name, entry);
    const Getter = function.SlotCall(scope.class_name ++ "." ++ name, definition.get, scope, 0);

    try w.print("    @{s}\n{s}    def {s}(self) -> {s}:", .{
        comptime context.builtin("property"), override, name, comptime annotation(Getter.Payload, .result, context),
    });
    if (definition.doc) |doc| {
        try w.writeAll("\n");
        try writeDocstring(w, doc, "        ");
    } else {
        try w.writeAll(" ...\n");
    }
    if (@TypeOf(definition.set) != @TypeOf(null)) {
        const Setter = function.SlotCall(scope.class_name ++ "." ++ name, definition.set, scope, 1);
        try w.print("    @{s}.setter\n    def {s}(self, value: {s}, /) -> None: ...\n", .{
            name, name, comptime annotation(Setter.ParamType(0), .argument, context),
        });
    }
}

fn writeSpecial(
    comptime method: [:0]const u8,
    comptime entry: anytype,
    comptime scope: function.Scope,
    comptime context: stubs.Context,
    w: *Writer,
) !void {
    if (comptime std.mem.eql(u8, method, "__call__")) {
        return writeFunction(method, function.stub(method, entry, scope), .instance, "    ", context, w);
    }
    try w.writeAll(comptime specialLine(method, entry, scope, context));
}

fn specialLine(
    comptime method: [:0]const u8,
    comptime entry: anytype,
    comptime scope: function.Scope,
    comptime context: stubs.Context,
) []const u8 {
    const view = context.builtin("memoryview");
    if (std.mem.eql(u8, method, "__buffer__")) {
        return "    def __buffer__(self, flags: " ++ context.builtin("int") ++ ", /) -> " ++ view ++ ": ...\n";
    }
    if (std.mem.eql(u8, method, "__release_buffer__")) {
        return "    def __release_buffer__(self, buffer: " ++ view ++ ", /) -> None: ...\n";
    }

    const label = scope.class_name ++ "." ++ method;
    const parameters = specialParameters(method, function.slotParameterCount(label, entry, scope));
    const Call = function.SlotCall(label, entry, scope, parameters.len);
    var signature: []const u8 = "self";
    for (parameters, 0..) |parameter, i| {
        const type_text = if (takesAnyObject(method)) context.builtin("object") else annotation(Call.ParamType(i), .argument, context);
        signature = signature ++ ", " ++ parameter ++ ": " ++ type_text;
        // Python lets callers leave out the modulo of __pow__ and the owner class of __get__.
        if (syntax.contains(&.{ "modulo", "owner" }, parameter)) signature = signature ++ " = None";
    }
    if (parameters.len > 0) signature = signature ++ ", /";

    return "    def " ++ method ++ "(" ++ signature ++ ") -> " ++ specialResult(method, Call.Payload, context) ++ ": ...\n";
}

const parameter_names = .{
    .__getitem__ = .{"key"},
    .__setitem__ = .{ "key", "value" },
    .__delitem__ = .{"key"},
    .__contains__ = .{"item"},
    .__getattr__ = .{"name"},
    .__setattr__ = .{ "name", "value" },
    .__delattr__ = .{"name"},
    .__get__ = .{ "instance", "owner" },
    .__set__ = .{ "instance", "value" },
    .__delete__ = .{"instance"},
};

fn specialParameters(comptime method: []const u8, comptime count: usize) []const []const u8 {
    if (@hasField(@TypeOf(parameter_names), method)) return &@field(parameter_names, method);
    if (syntax.contains(&.{ "__pow__", "__rpow__" }, method) and count == 2) return &.{ "other", "modulo" };
    if (slots.isBinary(method)) return &.{"other"};
    return &.{};
}

fn specialResult(comptime method: []const u8, comptime Payload: type, comptime context: stubs.Context) []const u8 {
    // A null result ends the iteration, or means there is no such attribute.
    if (syntax.contains(&.{ "__next__", "__getattr__" }, method) and @typeInfo(Payload) == .optional) {
        return annotation(@typeInfo(Payload).optional.child, .result, context);
    }
    if (isStrMethod(method)) return context.builtin("str");
    // In-place operators that return nothing return the instance.
    if (slots.isInPlace(method) and Payload == void) return context.typing("Self");
    // Attribute hooks may return whether they handled the attribute, which Python doesn't see.
    if (syntax.contains(&.{ "__setattr__", "__delattr__" }, method)) return "None";
    return annotation(Payload, .result, context);
}

fn takesAnyObject(comptime method: []const u8) bool {
    return syntax.contains(&.{ "__eq__", "__ne__", "__contains__" }, method);
}

fn isStrMethod(comptime method: []const u8) bool {
    return syntax.contains(&.{ "__repr__", "__str__" }, method);
}

/// What a function receives before its parameters.
pub const Receiver = enum { none, instance, class, constructor };

pub fn writeFunction(
    comptime name: [:0]const u8,
    comptime stub: function.Stub,
    comptime receiver: Receiver,
    comptime indent: []const u8,
    comptime context: stubs.Context,
    w: *Writer,
) !void {
    const result = if (receiver == .constructor) "None" else comptime annotation(stub.Result, .result, context);
    try w.print("{s}def {s}({s}) -> {s}:", .{ indent, name, comptime parameterList(stub, receiver, context), result });

    if (stub.doc) |doc| {
        try w.writeAll("\n");
        try writeDocstring(w, doc, indent ++ "    ");
    } else {
        try w.writeAll(" ...\n");
    }
}

fn parameterList(comptime stub: function.Stub, comptime receiver: Receiver, comptime context: stubs.Context) []const u8 {
    const params = stub.signature.params;
    var text: []const u8 = switch (receiver) {
        .none => "",
        .instance, .constructor => stub.signature.receiverName("self"),
        .class => stub.signature.receiverName("cls"),
    };
    var star = false;

    for (params, 0..) |param, i| {
        if (param.kind == .keyword_only and !star) {
            text = separate(text) ++ "*";
            star = true;
        }

        const name = param.name orelse switch (param.kind) {
            .var_positional => "args",
            .var_keyword => "kwargs",
            else => std.fmt.comptimePrint("arg{d}", .{i}),
        };
        text = separate(text) ++ switch (param.kind) {
            .var_positional => "*" ++ name ++ ": " ++ context.typing("Any"),
            .var_keyword => "**" ++ name ++ ": " ++ context.typing("Any"),
            else => name ++ ": " ++ annotation(param.type, .argument, context) ++
                if (stub.defaults[i]) |value| " = " ++ value else "",
        };
        if (param.kind == .var_positional) star = true;

        const last_positional_only = param.kind == .positional_only and
            (i + 1 == params.len or params[i + 1].kind != .positional_only);
        if (last_positional_only) text = text ++ ", /";
    }
    return text;
}

fn separate(comptime text: []const u8) []const u8 {
    return if (text.len == 0) text else text ++ ", ";
}

/// Write a docstring, escaping backslashes and quotes as needed.
pub fn writeDocstring(w: *Writer, text: []const u8, indent: []const u8) !void {
    try w.print("{s}\"\"\"", .{indent});
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;

    while (lines.next()) |line| {
        if (!first) {
            try w.writeAll("\n");
            if (line.len > 0) try w.writeAll(indent);
        }
        first = false;

        for (line, 0..) |char, i| {
            // A quote ends the docstring before another quote, or at its end.
            const closing = char == '"' and (if (i + 1 < line.len) line[i + 1] == '"' else lines.peek() == null);
            if (char == '\\') {
                try w.writeAll("\\\\");
            } else if (closing) {
                try w.writeAll("\\\"");
            } else {
                try w.writeByte(char);
            }
        }
    }

    try w.writeAll("\"\"\"\n");
}
