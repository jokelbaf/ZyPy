const std = @import("std");

const enum_class = @import("../enum_class.zig");
const function = @import("../function.zig");
const stubs = @import("../stubs.zig");
const annotations = @import("annotations.zig");
const annotation = annotations.annotation;

const Writer = std.Io.Writer;

/// Write the stub for exception type `Type`, using `name`.
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

/// What a function receives before its parameters.
pub const Receiver = enum { none, instance, class, constructor };

/// Write a function or method with its docstring, indented by `indent`.
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
