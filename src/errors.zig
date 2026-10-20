const std = @import("std");
const c = @import("python");

const conversion = @import("conversion.zig");
const function = @import("function.zig");
const reflection = @import("runtime/reflection.zig");
const Registry = @import("runtime/registry.zig").Registry;
const syntax = @import("syntax.zig");
const Object = @import("types/Object.zig");

/// A Python exception is set, and the caller must pass the error on.
pub const Error = error{PythonError};

/// Raise an exception: `return py.raise(.ValueError, "bad value");`.
/// `kind` is a built-in exception name, or a type made by `py.exceptionType`.
pub fn raise(comptime kind: anytype, message: [:0]const u8) Error {
    const exception = exceptionObject(kind) catch |err| return err;
    defer exception.deinit();

    c.PyErr_SetString(exception.ptr, message.ptr);
    return error.PythonError;
}

/// Raise an exception with a `std.fmt` message. Messages longer than 511 bytes are cut and end with `...`.
pub fn raiseFmt(comptime kind: anytype, comptime format: []const u8, args: anytype) Error {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(buffer[0 .. buffer.len - 1]);
    const end = end: {
        writer.print(format, args) catch {
            // Python decodes the message as UTF-8, so the cut must not split a character.
            const kept = wholeCharacters(buffer[0..@min(writer.end, buffer.len - 4)]);
            buffer[kept..][0..3].* = "...".*;
            break :end kept + 3;
        };
        break :end writer.end;
    };
    buffer[end] = 0;
    return raise(kind, buffer[0..end :0]);
}

fn wholeCharacters(text: []const u8) usize {
    var start = text.len;
    while (start > 0 and text.len - start < 4) {
        start -= 1;
        const length = std.unicode.utf8ByteSequenceLength(text[start]) catch continue;
        return if (start + length > text.len) start else text.len;
    }
    return text.len;
}

const ExceptionOption = enum { base, doc };

/// Define a custom exception and list it in the module's `.exceptions`.
/// Raise it with `py.raise` or map a Zig error to it with `.errors`.
/// Options: `.base` is an exception name or custom exception type (default `.Exception`); `.doc` is the docstring.
pub fn exceptionType(comptime options: anytype) type {
    if (@typeInfo(@TypeOf(options)) != .@"struct") {
        @compileError("py.exceptionType: the options must be a struct literal, such as .{ .base = .ValueError }");
    }
    inline for (@typeInfo(@TypeOf(options)).@"struct".field_names) |field| {
        if (std.meta.stringToEnum(ExceptionOption, field) == null) {
            @compileError("py.exceptionType: unknown option ." ++ field ++ " (expected .base or .doc)");
        }
    }
    const base_kind = if (@hasField(@TypeOf(options), "base")) options.base else .Exception;
    checkKind("py.exceptionType: .base", base_kind);

    return struct {
        pub const zypy_exception_type: ExceptionMarker = .{};
        pub const base = base_kind;
        pub const doc: ?[:0]const u8 = if (@hasField(@TypeOf(options), "doc"))
            function.text("py.exceptionType: .doc", options.doc)
        else
            null;
        pub var registry: Registry(*c.PyObject) = .{};

        /// Get the exception class in the current interpreter. The reference is owned.
        pub fn object() Error!Object {
            return exceptionObject(@This());
        }
    };
}

const ExceptionMarker = struct {};

/// Check whether `kind` is a type made by `py.exceptionType`.
pub fn isCustomException(comptime kind: anytype) bool {
    return @TypeOf(kind) == type and @typeInfo(kind) == .@"struct" and @hasDecl(kind, "zypy_exception_type") and
        @TypeOf(kind.zypy_exception_type) == ExceptionMarker;
}

/// Raise the exception for `err` using the first match in `tables`.
/// Otherwise map `OutOfMemory`, `Overflow`, and `DivisionByZero` to their Python exceptions.
/// Other errors raise `RuntimeError` with the error name.
pub fn raiseZigError(err: anyerror, comptime tables: anytype) Error {
    if (err == error.PythonError) return error.PythonError;

    inline for (tables) |table| {
        inline for (@typeInfo(@TypeOf(table)).@"struct".field_names) |name| {
            if (err == @field(anyerror, name)) {
                const target = @field(table, name);
                return if (comptime isKind(@TypeOf(target))) raise(target, name) else raise(target[0], target[1]);
            }
        }
    }

    switch (err) {
        error.OutOfMemory => _ = c.PyErr_NoMemory(),
        error.Overflow => c.PyErr_SetString(c.PyExc_OverflowError, "Overflow"),
        error.DivisionByZero => c.PyErr_SetString(c.PyExc_ZeroDivisionError, "DivisionByZero"),
        else => c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err).ptr),
    }
    return error.PythonError;
}

/// Check an `.errors` table, such as `.{ .NotFound = .KeyError }`, at compile time.
/// `returned` lists possible errors, or is `null` if the function can return any error.
pub fn checkMapping(comptime context: []const u8, comptime table: anytype, comptime returned: ?[]const [:0]const u8) void {
    const info = @typeInfo(@TypeOf(table));
    if (info != .@"struct" or (info.@"struct".is_tuple and info.@"struct".field_names.len > 0)) {
        @compileError(context ++ ": .errors must be a struct such as .{ .NotFound = .KeyError }");
    }

    for (info.@"struct".field_names) |name| {
        if (std.mem.eql(u8, name, "PythonError")) {
            @compileError(context ++ ": .errors can't map error.PythonError, because its exception is already set");
        }
        if (returned) |names| {
            if (!syntax.contains(names, name)) {
                @compileError(context ++ ": .errors maps error." ++ name ++ ", which the function never returns");
            }
        }
        checkTarget(context, name, @field(table, name));
    }
}

fn checkTarget(comptime context: []const u8, comptime name: []const u8, comptime target: anytype) void {
    const Target = @TypeOf(target);
    if (isKind(Target)) return checkKind(context ++ ": .errors", target);

    const with_message = reflection.isTuple(Target) and @typeInfo(Target).@"struct".field_names.len == 2 and
        isKind(@TypeOf(target[0]));
    if (!with_message) {
        @compileError(context ++ ": .errors maps error." ++ name ++
            " to an exception, such as .ValueError, or to .{ .ValueError, \"message\" }");
    }
    checkKind(context ++ ": .errors", target[0]);
    if (!isMessage(@TypeOf(target[1]))) {
        @compileError(context ++ ": .errors maps error." ++ name ++ " to a message of type " ++
            @typeName(@TypeOf(target[1])) ++ " (use a string literal)");
    }
}

/// Raise `TypeError: expected <type_name>, got <type of obj>`.
pub fn raiseWrongType(comptime type_name: [:0]const u8, obj: Object) Error {
    _ = c.PyErr_Format(c.PyExc_TypeError, "expected " ++ type_name ++ ", got %T", obj.ptr);
    return error.PythonError;
}

/// Escape percent signs in `text` for use in a `PyErr_Format` format string.
pub fn escapeFormat(comptime text: []const u8) []const u8 {
    var escaped: []const u8 = "";
    for (text) |char| escaped = escaped ++ if (char == '%') "%%" else &[_]u8{char};
    return escaped;
}

/// Return `error.PythonError` if a C API call returned a negative number, which means an exception is set.
pub fn check(result: c_int) Error!void {
    if (result < 0) return error.PythonError;
}

/// Get a built-in exception class by name, such as `.KeyError`, or a custom exception class. Release the
/// reference with `deinit`. Raise `RuntimeError` if a custom type isn't loaded in this interpreter.
pub fn exceptionObject(comptime kind: anytype) Error!Object {
    return findException(kind) orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "this exception type isn't loaded in this interpreter " ++
            "(import the module that lists it in .exceptions)");
        return error.PythonError;
    };
}

/// Get an exception class, or return `null` without raising if a custom type isn't loaded. Release the
/// reference with `deinit`.
pub fn findException(comptime kind: anytype) ?Object {
    comptime checkKind("py.raise", kind);
    if (comptime isCustomException(kind)) return kind.registry.find();
    return .borrow(@field(c, "PyExc_" ++ @tagName(kind)));
}

fn isKind(comptime T: type) bool {
    return T == @EnumLiteral() or T == type;
}

fn isMessage(comptime T: type) bool {
    return T == [:0]const u8 or conversion.isStringLiteral(T);
}

fn checkKind(comptime context: []const u8, comptime kind: anytype) void {
    if (isCustomException(kind)) return;
    if (@TypeOf(kind) != @EnumLiteral()) {
        const given = if (@TypeOf(kind) == type) @typeName(kind) else @typeName(@TypeOf(kind));
        @compileError(context ++ ": expected an exception name such as .ValueError, or a type made by " ++
            "py.exceptionType, got " ++ given);
    }
    if (!@hasDecl(c, "PyExc_" ++ @tagName(kind))) {
        @compileError("unknown built-in exception ." ++ @tagName(kind) ++ " (expected a name such as .ValueError)");
    }
}
