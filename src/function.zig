const std = @import("std");
const c = @import("python");

const callable = @import("function/callable.zig");
const parameters = @import("function/parameters.zig");
const Signature = @import("function/Signature.zig");
const Wrapper = @import("function/wrapper.zig").Wrapper;

pub const SlotCall = @import("function/slot_call.zig").SlotCall;
pub const slotParameterCount = @import("function/slot_call.zig").parameterCount;

const Option = enum { doc, params, defaults, errors, release_gil };

/// A Zig function and its export options, created by `py.function`.
pub fn Function(comptime Fn: type, comptime Options: type) type {
    return struct {
        func: Fn,
        options: Options,
    };
}

/// Set export options for a function in a module's `.functions` or a class's `.methods`:
///
/// - `.doc`: the docstring;
/// - `.params`: parameter names and the markers `"/"`, `"*"`, `"*name"` and `"**name"`;
/// - `.defaults`: parameter defaults, such as `.{ .greeting = "Hello" }`;
/// - `.errors`: error mappings, such as `.{ .NotFound = .KeyError }`;
/// - `.release_gil`: release the GIL during the call so other Python threads can run.
///
/// All options are optional.
pub fn function(comptime func: anytype, comptime options: anytype) Function(@TypeOf(func), @TypeOf(options)) {
    @setEvalBranchQuota(10_000);
    if (@typeInfo(@TypeOf(options)) != .@"struct") {
        @compileError("py.function: the options must be a struct literal, such as .{ .doc = \"Add two numbers.\" }");
    }
    inline for (@typeInfo(@TypeOf(options)).@"struct".field_names) |field| {
        if (std.meta.stringToEnum(Option, field) == null) {
            @compileError("py.function: unknown option ." ++ field ++
                " (expected .doc, .params, .defaults, .errors or .release_gil)");
        }
    }
    return .{ .func = func, .options = options };
}

/// Function export options with defaults applied. Accept a function or `py.function(...)`.
pub fn Definition(comptime name: []const u8, comptime entry: anytype) type {
    const context = "'" ++ name ++ "'";
    const Entry = @TypeOf(entry);
    const exported = blk: {
        if (@typeInfo(Entry) == .@"fn") break :blk function(entry, .{});
        if (isFunction(Entry)) break :blk entry;
        @compileError(context ++ " must be a function or py.function(...), got " ++ @typeName(Entry));
    };
    const Options = @TypeOf(exported.options);
    const options = exported.options;

    return struct {
        pub const func = exported.func;
        pub const doc: ?[:0]const u8 = if (@hasField(Options, "doc")) text(context ++ ": .doc", options.doc) else null;
        pub const params: ?[]const []const u8 = if (@hasField(Options, "params")) parameters.list(context, options.params) else null;
        pub const defaults = if (@hasField(Options, "defaults")) table(context ++ ": .defaults", options.defaults) else .{};
        pub const errors = if (@hasField(Options, "errors")) options.errors else .{};
        pub const release_gil: bool = if (@hasField(Options, "release_gil")) options.release_gil else false;
        pub const given = @typeInfo(Options).@"struct".field_names;
    };
}

fn isFunction(comptime Entry: type) bool {
    if (@typeInfo(Entry) != .@"struct" or !@hasField(Entry, "func") or !@hasField(Entry, "options")) return false;
    return Entry == Function(@FieldType(Entry, "func"), @FieldType(Entry, "options"));
}

/// Get named parameters accepted by a function or `py.function` entry.
/// Exclude "/", "*", "*args", and "**kwargs" markers.
pub fn keywordNames(comptime name: []const u8, comptime entry: anytype) []const [:0]const u8 {
    const params = Definition(name, entry).params orelse return &.{};
    var names: []const [:0]const u8 = &.{};
    for (params) |param| {
        if (std.mem.eql(u8, param, "/") or std.mem.startsWith(u8, param, "*")) continue;
        names = names ++ .{std.fmt.comptimePrint("{s}", .{param})};
    }
    return names;
}

/// Check that a docstring option is UTF-8 text without zero bytes, or `null`.
pub fn text(comptime context: []const u8, comptime value: anytype) ?[:0]const u8 {
    const Value = @TypeOf(value);
    if (Value == @TypeOf(null)) return null;
    if (@typeInfo(Value) == .optional) {
        const inner = value orelse return null;
        return text(context, inner);
    }

    if (!isText(Value)) @compileError(context ++ " must be a string or null, not " ++ @typeName(Value));
    const doc: []const u8 = value;
    @setEvalBranchQuota(1_000 + 10 * doc.len);
    // Python reads docstrings as C strings and decodes them as UTF-8.
    if (std.mem.indexOfScalar(u8, doc, 0) != null) @compileError(context ++ " can't contain zero bytes");
    if (!std.unicode.utf8ValidateSlice(doc)) @compileError(context ++ " must be UTF-8 text");
    return std.fmt.comptimePrint("{s}", .{doc});
}

/// Check whether `T` is a byte slice or a pointer to a byte array.
pub fn isText(comptime T: type) bool {
    const pointer = switch (@typeInfo(T)) {
        .pointer => |info| info,
        else => return false,
    };
    return switch (pointer.size) {
        .slice => pointer.child == u8,
        .one => @typeInfo(pointer.child) == .array and @typeInfo(pointer.child).array.child == u8,
        else => false,
    };
}

fn table(comptime context: []const u8, comptime value: anytype) @TypeOf(value) {
    const info = @typeInfo(@TypeOf(value));
    if (info != .@"struct" or (info.@"struct".is_tuple and info.@"struct".field_names.len > 0)) {
        @compileError(context ++ " must be a struct such as .{ .greeting = \"Hello\" }");
    }
    return value;
}

/// The module and optional class that define a function.
pub const Scope = struct {
    Module: type,
    Class: ?type = null,
    class_name: [:0]const u8 = "",

    /// Get the scope of class `T` in this module.
    pub fn of(comptime self: Scope, comptime T: type) Scope {
        const classes = self.Module.contents.classes;
        for (@typeInfo(@TypeOf(classes)).@"struct".field_names) |name| {
            if (@field(classes, name) == T) return .{ .Module = self.Module, .Class = T, .class_name = name };
        }
        @compileError("py.module: .classes doesn't list " ++ @typeName(T));
    }
};

/// The wrapper's calling convention and the meaning of `self`.
pub const Mode = enum {
    /// A module function: `self` is the module.
    function,
    /// An instance method: `self` is the instance.
    method,
    /// A static method: `self` is null, or the class for static methods that take the module's state.
    static,
    /// A class method: `self` is the class it's called on.
    class_method,
    /// A class constructor (`tp_new`): `self` is null, and the result becomes an instance of a given type.
    constructor,
};

fn modeOf(comptime Fn: type, comptime scope: Scope) Mode {
    const Class = scope.Class orelse return .function;
    if (callable.takesReceiver(Fn, Class)) return .method;
    return if (callable.takesClass(Fn, Class)) .class_method else .static;
}

/// Get the display name: `greet`, `Point.scale`, or `Point` for a constructor.
pub fn labelOf(comptime name: [:0]const u8, comptime scope: Scope, comptime mode: Mode) [:0]const u8 {
    return switch (mode) {
        .function => name,
        .method, .static, .class_method => scope.class_name ++ "." ++ name,
        .constructor => scope.class_name,
    };
}

/// Create a Python method table entry from a Zig function or a `py.function` value.
pub fn methodDef(comptime name: [:0]const u8, comptime entry: anytype, comptime scope: Scope) c.PyMethodDef {
    const definition = Definition(name, entry);
    const wrapper = Wrapper(name, definition, scope, modeOf(@TypeOf(definition.func), scope));
    return .{
        .ml_name = name,
        .ml_meth = @ptrCast(&wrapper.call),
        .ml_flags = wrapper.flags,
        .ml_doc = wrapper.doc,
    };
}

/// A constructor wrapper for a function, `py.function(...)`, or a field constructor.
pub fn Constructor(comptime entry: anytype, comptime scope: Scope) type {
    const definition = Definition(scope.class_name ++ ".init", entry);
    if (definition.doc != null) {
        @compileError("'" ++ scope.class_name ++ "': put the class docstring in py.class(.{ .doc = ... })");
    }
    return Wrapper(scope.class_name, definition, scope, .constructor);
}

/// The wrapper of `__call__` (`tp_call`), which binds arguments like a method.
pub fn CallSlot(comptime entry: anytype, comptime scope: Scope) type {
    const definition = Definition(scope.class_name ++ ".__call__", entry);
    if (!callable.takesReceiver(@TypeOf(definition.func), scope.Class.?)) {
        @compileError("'" ++ scope.class_name ++ ".__call__' must take the instance first, such as self: *" ++
            @typeName(scope.Class.?));
    }
    return Wrapper("__call__", definition, scope, .method);
}

/// What a type stub needs to know about an exported function.
pub const Stub = struct {
    signature: Signature,
    /// Parameter defaults as Python code, or `null` for required parameters.
    defaults: []const ?[]const u8,
    Result: type,
    doc: ?[]const u8,
    mode: Mode,
};

/// Describe a function in a module's `.functions` or a class's `.methods` for type stubs.
pub fn stub(comptime name: [:0]const u8, comptime entry: anytype, comptime scope: Scope) Stub {
    const definition = Definition(name, entry);
    return describe(name, definition, scope, modeOf(@TypeOf(definition.func), scope));
}

/// Describe a class constructor for type stubs.
pub fn constructorStub(comptime entry: anytype, comptime scope: Scope) Stub {
    return describe(scope.class_name, Definition(scope.class_name ++ ".init", entry), scope, .constructor);
}

fn describe(comptime name: [:0]const u8, comptime definition: type, comptime scope: Scope, comptime mode: Mode) Stub {
    const label = labelOf(name, scope, mode);
    const Callable = callable.Callable("'" ++ label ++ "'", definition.func);
    const roles = callable.hiddenRoles(Callable.types, scope, mode);
    const signature: Signature = comptime .init(label, Callable.types, definition.params, definition.defaults, &roles);

    var rendered: [signature.params.len]?[]const u8 = undefined;
    for (signature.params, 0..) |param, i| rendered[i] = signature.renderDefault(param, definition.defaults);
    const final = rendered;
    return .{
        .signature = signature,
        .defaults = &final,
        .Result = Callable.Result,
        .doc = definition.doc,
        .mode = mode,
    };
}
