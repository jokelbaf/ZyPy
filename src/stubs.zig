const std = @import("std");
const options = @import("zypy_options");

const function = @import("function.zig");
const annotation = @import("stubs/annotations.zig").annotation;
const declarations = @import("stubs/declarations.zig");
const syntax = @import("syntax.zig");

const Writer = std.Io.Writer;

/// Write type stubs for `Module` into `directory`.
/// Use `pkg/_core.pyi` for `pkg._core`, or `pkg/_core/__init__.pyi` plus files for its submodules.
pub fn write(comptime Module: type, io: std.Io, directory: std.Io.Dir, gpa: std.mem.Allocator) !void {
    const name = options.extension orelse @compileError("py.stubs: only extensions have type stubs");
    try writeTree(Module, name, comptime named(Module, name), io, directory, gpa);
}

/// A class or exception and its Python name for type annotations.
pub const Named = struct {
    type: type,
    module: []const u8,
    name: []const u8,
};

/// Names and imports available to type annotations in a stub.
pub const Context = struct {
    module: []const u8,
    known: []const Named,
    defined: []const []const u8,
    imports: []const Import,

    /// Get the qualified annotation name, using an import alias if needed.
    pub fn qualify(comptime self: Context, comptime module: []const u8, comptime name: []const u8) []const u8 {
        for (self.imports) |import| {
            if (std.mem.eql(u8, import.module, module)) return import.name ++ "." ++ name;
        }
        @compileError("py.stubs: " ++ self.module ++ " doesn't import " ++ module);
    }

    /// Name `name` of the `typing` module.
    pub fn typing(comptime self: Context, comptime name: []const u8) []const u8 {
        return self.qualify("typing", name);
    }

    /// Name `name` of the `collections.abc` module.
    pub fn abc(comptime self: Context, comptime name: []const u8) []const u8 {
        return self.qualify("collections.abc", name);
    }

    /// Name the built-in `name`, through the `builtins` module where a definition hides it.
    pub fn builtin(comptime self: Context, comptime name: []const u8) []const u8 {
        return if (syntax.contains(self.defined, name)) self.qualify("builtins", name) else name;
    }

    /// Get the annotation context inside a class defining `members`.
    pub fn inClass(comptime self: Context, comptime members: []const []const u8) Context {
        var inner = self;
        inner.defined = self.defined ++ members;
        return inner;
    }
};

/// A module import with an optional alias.
pub const Import = struct {
    module: []const u8,
    name: []const u8,
};

const standard_modules = [_][]const u8{ "builtins", "collections.abc", "enum", "typing" };

fn named(comptime Module: type, comptime module: []const u8) []const Named {
    const contents = Module.contents;
    var found: []const Named = &.{};
    for (@typeInfo(@TypeOf(contents.classes)).@"struct".field_names) |name| {
        found = found ++ .{Named{ .type = @field(contents.classes, name), .module = module, .name = name }};
    }
    for (@typeInfo(@TypeOf(contents.exceptions)).@"struct".field_names) |name| {
        found = found ++ .{Named{ .type = @field(contents.exceptions, name), .module = module, .name = name }};
    }
    for (@typeInfo(@TypeOf(contents.enums)).@"struct".field_names) |name| {
        found = found ++ .{Named{ .type = @field(contents.enums, name), .module = module, .name = name }};
    }
    for (@typeInfo(@TypeOf(contents.submodules)).@"struct".field_names) |name| {
        found = found ++ named(@field(contents.submodules, name), module ++ "." ++ name);
    }
    return found;
}

fn writeTree(
    comptime Module: type,
    comptime module: []const u8,
    comptime known: []const Named,
    io: std.Io,
    directory: std.Io.Dir,
    gpa: std.mem.Allocator,
) !void {
    @setEvalBranchQuota(1_000_000);
    const submodules = Module.contents.submodules;
    const submodule_names = @typeInfo(@TypeOf(submodules)).@"struct".field_names;
    const path = comptime filePath(module, submodule_names.len > 0);

    const context: Context = comptime .{
        .module = module,
        .known = known,
        .defined = definedNames(Module),
        .imports = importsOf(&standard_modules ++ otherModules(module, known), fileNames(Module)),
    };

    var body: Writer.Allocating = .init(gpa);
    defer body.deinit();
    try writeModule(Module, context, &body.writer);

    var file: Writer.Allocating = .init(gpa);
    defer file.deinit();
    try writeFile(Module, context, body.written(), &file.writer);

    if (std.fs.path.dirname(path)) |parent| try directory.createDirPath(io, parent);
    try directory.writeFile(io, .{ .sub_path = path, .data = file.written() });

    inline for (submodule_names) |name| {
        try writeTree(@field(submodules, name), module ++ "." ++ name, known, io, directory, gpa);
    }
}

fn filePath(comptime module: []const u8, comptime package: bool) []const u8 {
    var path: [module.len]u8 = module[0..module.len].*;
    std.mem.replaceScalar(u8, &path, '.', '/');
    return if (package) path ++ "/__init__.pyi" else path ++ ".pyi";
}

fn writeFile(comptime Module: type, comptime context: Context, body: []const u8, w: *Writer) !void {
    if (Module.contents.doc) |doc| {
        try declarations.writeDocstring(w, doc, "");
        try w.writeAll("\n");
    }

    var imports: usize = 0;
    inline for (context.imports) |import| {
        if (uses(body, import, context.known)) {
            if (comptime std.mem.eql(u8, import.module, import.name)) {
                try w.print("import {s}\n", .{import.module});
            } else {
                try w.print("import {s} as {s}\n", .{ import.module, import.name });
            }
            imports += 1;
        }
    }

    inline for (@typeInfo(@TypeOf(Module.contents.submodules)).@"struct".field_names, 0..) |name, i| {
        if (i == 0 and imports > 0) try w.writeAll("\n");
        try w.print("from . import {s} as {s}\n", .{ name, name });
        imports += 1;
    }

    if (imports > 0) try w.writeAll("\n");
    try w.writeAll(body);
}

fn uses(body: []const u8, comptime import: Import, comptime known: []const Named) bool {
    if (comptime syntax.contains(&standard_modules, import.module)) {
        return std.mem.indexOf(u8, body, import.name ++ ".") != null;
    }
    inline for (known) |entry| {
        if (comptime std.mem.eql(u8, entry.module, import.module)) {
            if (std.mem.indexOf(u8, body, import.name ++ "." ++ entry.name) != null) return true;
        }
    }
    return false;
}

fn otherModules(comptime module: []const u8, comptime known: []const Named) []const []const u8 {
    var modules: []const []const u8 = &.{};
    for (known) |entry| {
        if (std.mem.eql(u8, entry.module, module) or syntax.contains(modules, entry.module)) continue;
        modules = modules ++ .{entry.module};
    }
    return modules;
}

fn importsOf(comptime modules: []const []const u8, comptime taken: []const []const u8) []const Import {
    var imports: []const Import = &.{};
    var names = taken;
    for (modules) |module| {
        var name: []const u8 = module;
        if (syntax.contains(names, module[0 .. std.mem.indexOfScalar(u8, module, '.') orelse module.len])) {
            name = underscored(module);
            while (syntax.contains(names, name)) name = name ++ "_";
        }
        imports = imports ++ .{Import{ .module = module, .name = name }};
        names = names ++ .{name};
    }
    return imports;
}

fn underscored(comptime module: []const u8) []const u8 {
    var name = module[0..module.len].*;
    std.mem.replaceScalar(u8, &name, '.', '_');
    const result = name;
    return &result;
}

fn definedNames(comptime Module: type) []const []const u8 {
    const contents = Module.contents;
    var defined: []const []const u8 = &.{};
    inline for (.{ contents.constants, contents.exceptions, contents.enums, contents.classes, contents.functions, contents.submodules }) |section| {
        for (@typeInfo(@TypeOf(section)).@"struct".field_names) |name| defined = defined ++ .{name};
    }
    return defined;
}

fn fileNames(comptime Module: type) []const []const u8 {
    const classes = Module.contents.classes;
    var names = definedNames(Module);
    for (@typeInfo(@TypeOf(classes)).@"struct".field_names) |name| names = names ++ declarations.members(@field(classes, name));
    return names;
}

fn writeModule(comptime Module: type, comptime context: Context, w: *Writer) !void {
    const contents = Module.contents;
    const scope: function.Scope = .{ .Module = Module };

    var sections: Sections = .{ .w = w };
    inline for (@typeInfo(@TypeOf(contents.constants)).@"struct".field_names) |name| {
        try sections.start(.constant);
        try w.print("{s}: {s}\n", .{ name, comptime annotation(@TypeOf(@field(contents.constants, name)), .result, context) });
    }

    inline for (@typeInfo(@TypeOf(contents.exceptions)).@"struct".field_names) |name| {
        try sections.start(.definition);
        try declarations.writeException(@field(contents.exceptions, name), name, context, w);
    }

    inline for (@typeInfo(@TypeOf(contents.enums)).@"struct".field_names) |name| {
        try sections.start(.definition);
        try declarations.writeEnum(@field(contents.enums, name), name, context, w);
    }

    inline for (@typeInfo(@TypeOf(contents.classes)).@"struct".field_names) |name| {
        try sections.start(.definition);
        try declarations.writeClass(@field(contents.classes, name), name, Module, context, w);
    }

    inline for (@typeInfo(@TypeOf(contents.functions)).@"struct".field_names) |name| {
        try sections.start(.definition);
        const stub = function.stub(name, @field(contents.functions, name), scope);
        try declarations.writeFunction(name, stub, .none, "", context, w);
    }
}

const Sections = struct {
    w: *Writer,
    last: ?Kind = null,

    const Kind = enum { constant, definition };

    fn start(self: *Sections, kind: Kind) !void {
        if (self.last) |last| {
            if (kind == .definition or last != kind) try self.w.writeAll("\n");
        }
        self.last = kind;
    }
};
