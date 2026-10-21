const std = @import("std");
const c = @import("python");

const class = @import("../class.zig");
const errors = @import("../errors.zig");
const function = @import("../function.zig");
const api = @import("../runtime/api.zig");
const gc = @import("../runtime/gc.zig");
const Object = @import("../types/Object.zig");
const attributes = @import("attributes.zig");
const layout = @import("layout.zig");
const lifecycle = @import("lifecycle.zig");
const slots = @import("slots.zig");

/// The Python type of class `T`, named `name` in module `Module`.
pub fn Type(comptime T: type, comptime Module: type, comptime name: [:0]const u8) type {
    @setEvalBranchQuota(200_000);
    const context = "'" ++ name ++ "'";
    if (!class.isClass(T)) {
        @compileError("py.module: .classes has '" ++ name ++ "', but " ++ @typeName(T) ++
            " has no pub const class = py.class(...) declaration");
    }
    if (@alignOf(T) > class.base_alignment) {
        @compileError(std.fmt.comptimePrint("{s}: the struct needs {d}-byte alignment, but Python's allocator " ++
            "aligns objects to {d} bytes on this target", .{ context, @alignOf(T), class.base_alignment }));
    }

    comptime gc.checkFields(T, context);
    if (@hasDecl(T, "deinit")) {
        const params = @typeInfo(@TypeOf(T.deinit)).@"fn".param_types;
        if (params.len != 1 or (params[0] != *T and params[0] != T and params[0] != *const T)) {
            @compileError(context ++ ": deinit must take only the instance, such as self: *" ++ @typeName(T));
        }
    }

    const definition = class.Definition(T);
    if (definition.Base) |Base| comptime checkBase(T, Base, context);
    const scope: function.Scope = .{ .Module = Module, .Class = T, .class_name = name };
    const Attributes = attributes.GetSet(scope, definition.fields, definition.properties, definition.dict);
    const Constructor = if (definition.constructs) function.Constructor(definition.init, scope) else void;
    const Special = slots.Slots(scope, definition.special);

    const regular: []const [:0]const u8 = blk: {
        var list: []const [:0]const u8 = &.{};
        for (@typeInfo(@TypeOf(definition.methods)).@"struct".field_names) |method| {
            if (!slots.isSpecial(context, method)) list = list ++ .{method};
        }
        break :blk list;
    };

    return struct {
        var method_table: [regular.len + Special.visible.len + 1]c.PyMethodDef = blk: {
            var table: [regular.len + Special.visible.len + 1]c.PyMethodDef = undefined;
            for (regular, 0..) |method, i| table[i] = function.methodDef(method, @field(definition.methods, method), scope);
            for (Special.visible, regular.len..) |method, i| table[i] = method;
            table[table.len - 1] = std.mem.zeroes(c.PyMethodDef);
            break :blk table;
        };

        const type_doc: ?[:0]const u8 = blk: {
            const header: ?[]const u8 = if (definition.constructs) Constructor.header else null;
            if (header == null and definition.doc == null) break :blk null;
            break :blk std.fmt.comptimePrint("{s}{s}", .{ header orelse "", definition.doc orelse "" });
        };

        // The limited API needs explicit offsets for instance dictionaries and weak references.
        var member_table = blk: {
            const parts = layout.layout(T);
            var members: []const c.PyMemberDef = &.{};
            if (parts.dict) |at| members = members ++ .{offsetMember("__dictoffset__", at)};
            if (parts.weak_list) |at| members = members ++ .{offsetMember("__weaklistoffset__", at)};
            break :blk (members ++ .{std.mem.zeroes(c.PyMemberDef)})[0 .. members.len + 1].*;
        };

        const slot_list: []const c.PyType_Slot = blk: {
            var list: []const c.PyType_Slot = &(lifecycle.slots(T) ++ [_]c.PyType_Slot{
                .{ .slot = c.Py_tp_methods, .pfunc = @ptrCast(&method_table) },
                .{ .slot = c.Py_tp_getset, .pfunc = @ptrCast(&Attributes.table) },
            });
            if (member_table.len > 1) list = list ++ .{c.PyType_Slot{ .slot = c.Py_tp_members, .pfunc = @ptrCast(&member_table) }};
            if (type_doc) |text| list = list ++ .{c.PyType_Slot{ .slot = c.Py_tp_doc, .pfunc = @ptrCast(@constCast(text.ptr)) }};
            if (definition.constructs) list = list ++ .{slots.slot(c.Py_tp_new, &Constructor.new)};
            break :blk list ++ Special.list ++ .{c.PyType_Slot{ .slot = 0, .pfunc = null }};
        };

        var slot_table: [slot_list.len]c.PyType_Slot = slot_list[0..slot_list.len].*;

        const flags: c_ulong = c.Py_TPFLAGS_DEFAULT | c.Py_TPFLAGS_IMMUTABLETYPE | c.Py_TPFLAGS_HAVE_GC |
            (if (definition.subclassable) c.Py_TPFLAGS_BASETYPE else 0) |
            (if (definition.constructs) 0 else c.Py_TPFLAGS_DISALLOW_INSTANTIATION) |
            (if (definition.dict and !api.limited) c.Py_TPFLAGS_MANAGED_DICT else 0) |
            (if (definition.weak_references and !api.limited) c.Py_TPFLAGS_MANAGED_WEAKREF else 0);

        /// Create the type for the import `module`, named `qualname`. `base` is the base's type for Zig subclasses.
        /// The result is a new reference.
        pub fn create(module: *c.PyObject, qualname: [*:0]const u8, base: ?*c.PyObject) errors.Error!*c.PyObject {
            var spec: c.PyType_Spec = .{
                .name = qualname,
                .basicsize = @intCast(layout.layout(T).size),
                .itemsize = 0,
                .flags = @intCast(flags),
                .slots = &slot_table,
            };
            return (try Object.own(c.PyType_FromModuleAndSpec(module, &spec, base))).ptr;
        }
    };
}

fn checkBase(comptime T: type, comptime Base: type, comptime context: []const u8) void {
    if (!class.Definition(Base).subclassable) {
        @compileError(context ++ ": its base " ++ @typeName(Base) ++ " doesn't allow subclasses (set .subclassable " ++
            "= true in its py.class)");
    }
    const info = @typeInfo(T).@"struct";
    if (info.field_names.len == 0 or info.field_types[0] != Base or info.field_attrs[0].@"comptime") {
        @compileError(context ++ ": " ++ @typeName(T) ++ " must hold its base in its first field, such as base: " ++
            @typeName(Base) ++ " align(py.base_alignment)");
    }
    // An offset of zero on this target does not guarantee the declared alignment on other targets.
    const field = class.baseField(T);
    if ((info.field_attrs[0].@"align" orelse 0) < class.base_alignment) {
        @compileError(context ++ ": declare the base field as " ++ field ++ ": " ++ @typeName(Base) ++
            " align(py.base_alignment), which keeps it at the start of " ++ @typeName(T) ++ " on every target " ++
            "(Zig orders fields by alignment)");
    }
    if (@offsetOf(T, field) != 0) {
        @compileError(context ++ ": Zig didn't place the base field '" ++ field ++ "' at the start of " ++ @typeName(T));
    }
}

fn offsetMember(comptime name: [:0]const u8, comptime at: usize) c.PyMemberDef {
    return .{ .name = name, .type = c.Py_T_PYSSIZET, .offset = at, .flags = c.Py_READONLY, .doc = null };
}
