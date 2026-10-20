const std = @import("std");

const class = @import("../class.zig");
const enum_class = @import("../enum_class.zig");
const errors = @import("../errors.zig");
const gc = @import("../runtime/gc.zig");
const memory = @import("../runtime/memory.zig");
const syntax = @import("../syntax.zig");
const Object = @import("../types/Object.zig");

/// The sections of a module definition that add names to the module.
pub const sections = [_][]const u8{ "functions", "constants", "exceptions", "classes", "enums", "submodules" };

/// Get the Python names in a section such as `.functions`, a struct like `.{ .add = add }`.
pub fn names(comptime option: []const u8, comptime section: anytype) []const [:0]const u8 {
    const info = @typeInfo(@TypeOf(section));
    if (info != .@"struct" or (info.@"struct".is_tuple and info.@"struct".field_names.len > 0)) {
        @compileError("py.module: ." ++ option ++ " must be a struct with Python names, such as .{ .Name = ... }");
    }
    return info.@"struct".field_names;
}

/// Check that the names of all sections are valid Python names, and that each is defined once.
pub fn checkNames(comptime definition: anytype) void {
    @setEvalBranchQuota(100_000);
    for (sections, 0..) |option, i| {
        const section = if (@hasField(@TypeOf(definition), option)) @field(definition, option) else .{};
        for (names(option, section)) |name| {
            syntax.checkName("py.module: ." ++ option, "name", name);
            for (sections[0..i]) |earlier| {
                if (@hasField(@TypeOf(definition), earlier) and @hasField(@TypeOf(@field(definition, earlier)), name)) {
                    @compileError("py.module: '" ++ name ++ "' is in both ." ++ earlier ++ " and ." ++ option ++
                        " (a module has one value per name)");
                }
            }
        }
    }
}

pub fn checkExceptions(comptime exceptions: anytype) void {
    const exception_names = @typeInfo(@TypeOf(exceptions)).@"struct".field_names;
    for (exception_names, 0..) |name, i| {
        const Exception = @field(exceptions, name);
        if (!errors.isCustomException(Exception)) {
            @compileError("py.module: .exceptions has '" ++ name ++ "', which isn't a type made by py.exceptionType");
        }
        for (exception_names[0..i]) |earlier| {
            if (@field(exceptions, earlier) == Exception) {
                @compileError("py.module: '" ++ name ++ "' and '" ++ earlier ++ "' are the same exception type " ++
                    "(py.exceptionType returns the same type for the same options, so give them different .doc texts)");
            }
        }
        if (errors.isCustomException(Exception.base)) {
            for (exception_names[i..]) |later| {
                if (@field(exceptions, later) == Exception.base) {
                    @compileError("py.module: list the base of '" ++ name ++ "' before it in .exceptions");
                }
            }
        }
    }
}

pub fn checkClasses(comptime classes: anytype) void {
    const class_names = @typeInfo(@TypeOf(classes)).@"struct".field_names;
    for (class_names, 0..) |name, i| {
        const T = @field(classes, name);
        if (@TypeOf(T) != type or !class.isClass(T)) {
            @compileError("py.module: .classes has '" ++ name ++ "', which needs to be a struct with a " ++
                "pub const class = py.class(...) declaration");
        }
        for (class_names[0..i]) |earlier| {
            if (@field(classes, earlier) == T) @compileError("py.module: .classes lists " ++ @typeName(T) ++ " twice");
        }
        if (class.Definition(T).Base) |Base| checkBase(classes, name, i, Base);
    }
}

fn checkBase(comptime classes: anytype, comptime name: []const u8, comptime index: usize, comptime Base: type) void {
    const class_names = @typeInfo(@TypeOf(classes)).@"struct".field_names;
    for (class_names[0..index]) |earlier| {
        if (@field(classes, earlier) == Base) return;
    }
    for (class_names[index..]) |later| {
        if (@field(classes, later) == Base) @compileError("py.module: list the base of '" ++ name ++ "' before it in .classes");
    }
    @compileError("py.module: '" ++ name ++ "' inherits from " ++ @typeName(Base) ++ ", so list that class in .classes " ++
        "too, before '" ++ name ++ "' (a class and its base must be in the same module)");
}

pub fn checkEnums(comptime enums: anytype) void {
    const enum_names = @typeInfo(@TypeOf(enums)).@"struct".field_names;
    for (enum_names, 0..) |name, i| {
        const T = @field(enums, name);
        if (@TypeOf(T) != type) {
            @compileError("py.module: .enums has '" ++ name ++ "', which needs to be an enum with a pub const " ++
                "class = py.enumClass(...) declaration");
        }
        enum_class.check(T, name);
        for (enum_names[0..i]) |earlier| {
            if (@field(enums, earlier) == T) @compileError("py.module: .enums lists " ++ @typeName(T) ++ " twice");
        }
    }
}

/// Check that submodules are modules, and that a `.free_threaded` module's submodules are too.
pub fn checkSubmodules(comptime submodules: anytype, comptime free_threaded: bool, comptime isModule: fn (type) bool) void {
    for (@typeInfo(@TypeOf(submodules)).@"struct".field_names) |name| {
        const Submodule = @field(submodules, name);
        if (@TypeOf(Submodule) != type or !isModule(Submodule)) {
            @compileError("py.module: .submodules has '" ++ name ++ "', which isn't a type made by py.module");
        }
        // Python decides whether to enable the GIL when it imports the top-level module.
        if (free_threaded and !Submodule.free_threaded) {
            @compileError("py.module: the module is .free_threaded, so submodule '" ++ name ++
                "' must set .free_threaded = true too: it runs without the GIL as well");
        }
    }
}

pub fn checkState(comptime State: type) void {
    if (State == void) return;
    if (@typeInfo(State) != .@"struct") @compileError("py.module: .state must be a struct type, not " ++ @typeName(State));
    if (@alignOf(State) > memory.native.toByteUnits()) {
        @compileError(std.fmt.comptimePrint("py.module: .state needs {d}-byte alignment, but Python's allocator " ++
            "aligns memory to {d} bytes on this target", .{ @alignOf(State), memory.native.toByteUnits() }));
    }
    gc.checkFields(State, "py.module: .state");

    if (@hasDecl(State, "init")) {
        const params = @typeInfo(@TypeOf(State.init)).@"fn".param_types;
        if (params.len > 1 or (params.len == 1 and params[0] != Object)) {
            @compileError("py.module: " ++ @typeName(State) ++ ".init must take no parameters or the module (py.Object)");
        }
    } else {
        for (@typeInfo(State).@"struct".field_names, @typeInfo(State).@"struct".field_attrs) |field, attrs| {
            if (attrs.default_value_ptr == null) {
                @compileError("py.module: " ++ @typeName(State) ++ " needs an init function, or a default value for '" ++
                    field ++ "'");
            }
        }
    }
}
