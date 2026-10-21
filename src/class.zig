const std = @import("std");

const constructor = @import("class/constructor.zig");
const instances = @import("class/instances.zig");
const layout = @import("class/layout.zig");
const lifecycle = @import("class/lifecycle.zig");
const members = @import("class/members.zig");
const slots = @import("class/slots.zig");
const value = @import("class/value.zig");
const function = @import("function.zig");

pub const Type = @import("class/type_object.zig").Type;
pub const FieldConstructor = constructor.FieldConstructor;
pub const constructorStub = constructor.stub;
pub const base_alignment = layout.base_alignment;
pub const valueOf = layout.valueOf;
pub const instanceOf = layout.instanceOf;
pub const finalized = layout.finalized;
pub const isInstance = instances.isInstance;
pub const isSubclass = instances.isSubclass;
pub const checkInstance = instances.checkInstance;
pub const checkSubclass = instances.checkSubclass;
pub const isTypeOf = lifecycle.isTypeOf;
pub const isZigClass = lifecycle.isZigClass;
pub const registry = lifecycle.registry;
pub const typeObject = lifecycle.typeObject;
pub const copyFrom = value.copyFrom;
pub const copyInto = value.copyInto;
pub const moveInto = value.moveInto;
pub const construct = value.construct;
pub const constructIn = value.constructIn;
pub const receiverKind = value.receiverKind;
pub const receiver = value.receiver;
pub const receivesClass = value.receivesClass;
pub const checkMembers = members.check;

const Option = enum { doc, base, fields, methods, properties, init, subclassable, weak_references, dict };

/// Class options made by `py.class`.
pub fn ClassOptions(comptime Options: type) type {
    return struct {
        options: Options,
    };
}

/// Expose a Zig struct as a Python class. Declare `pub const class = py.class(.{ ... })`
/// in the struct and list it in the module's `.classes`. Available options:
///
/// - `.doc`: the docstring;
/// - `.base`: a subclassable class stored in the first field, with `align(py.base_alignment)`;
/// - `.fields`: exposed fields, such as `.{ .x = .read_write, .y = .read_only }`;
/// - `.methods`: Python names mapped to functions or `py.function(...)`, including special methods;
/// - `.properties`: computed attributes, given as getters or `py.property(...)`;
/// - `.init`: a constructor function or `py.function(...)`; `null` prevents Python construction;
/// - `.subclassable`: allow Python or Zig subclasses;
/// - `.weak_references`: allow weak references to instances;
/// - `.dict`: allow extra attributes through an instance `__dict__`.
///
/// Methods receive an instance first, class methods receive `py.Class(T)`, and static methods receive neither.
/// The default constructor uses the struct's `init` function if present, otherwise one argument per field.
pub fn class(comptime options: anytype) ClassOptions(@TypeOf(options)) {
    if (@typeInfo(@TypeOf(options)) != .@"struct") {
        @compileError("py.class: the options must be a struct literal, such as .{ .doc = \"A point.\" }");
    }
    inline for (@typeInfo(@TypeOf(options)).@"struct".field_names) |field| {
        if (std.meta.stringToEnum(Option, field) == null) {
            @compileError("py.class: unknown option ." ++ field ++ " (expected .doc, .base, .fields, .methods, " ++
                ".properties, .init, .subclassable, .weak_references or .dict)");
        }
    }
    return .{ .options = options };
}

/// Require `T` to be a class supported by `wrapper`, such as "py.Instance".
pub fn requireClass(comptime wrapper: []const u8, comptime T: type) void {
    if (!isClass(T)) {
        @compileError(wrapper ++ "(" ++ @typeName(T) ++ ") needs a class: declare pub const class = py.class(...) in it");
    }
}

/// Check whether `T` is a class: a struct with a `pub const class = py.class(...)` declaration.
pub fn isClass(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "class")) return false;
    const Declared = @TypeOf(T.class);
    return @typeInfo(Declared) == .@"struct" and @hasField(Declared, "options") and
        Declared == ClassOptions(@FieldType(Declared, "options"));
}

/// The options of class `T`, each set to its default when not given.
pub fn Definition(comptime T: type) type {
    const options = T.class.options;
    const Options = @TypeOf(options);
    const BaseClass: ?type = if (@hasField(Options, "base")) baseOf(T, options.base) else null;

    return struct {
        pub const doc: ?[:0]const u8 = if (@hasField(Options, "doc"))
            function.text("py.class(" ++ @typeName(T) ++ "): .doc", options.doc)
        else
            null;
        /// The class that `T` inherits from, or `null`.
        pub const Base = BaseClass;
        pub const fields = if (@hasField(Options, "fields")) options.fields else .{};
        pub const methods = if (@hasField(Options, "methods")) options.methods else .{};
        pub const properties = if (@hasField(Options, "properties")) options.properties else .{};
        pub const subclassable = flag(options, "subclassable");
        pub const weak_references = flag(options, "weak_references") or inherits(BaseClass, "weak_references");
        pub const dict = flag(options, "dict") or inherits(BaseClass, "dict");
        pub const init = blk: {
            if (@hasField(Options, "init")) break :blk options.init;
            if (@hasDecl(T, "init")) break :blk T.init;
            break :blk constructor.fields(T);
        };
        pub const constructs = @TypeOf(init) != @TypeOf(null);
        /// Special methods whose slots this class supplies, including inherited methods that share those slots.
        pub const special: SpecialMethods(T) = .{};
        pub const finalizes = definer(T, "__del__") != null;
    };
}

fn baseOf(comptime T: type, comptime base: anytype) type {
    const context = "py.class(" ++ @typeName(T) ++ "): .base";
    if (@TypeOf(base) != type) {
        @compileError(context ++ " must be a class, not a value of type " ++ @typeName(@TypeOf(base)));
    }
    if (!isClass(base)) {
        @compileError(context ++ " must be a class (a struct with pub const class = py.class(...)), not " ++
            @typeName(base));
    }
    if (base == T) @compileError(context ++ " can't be the class itself");
    return base;
}

fn flag(comptime options: anytype, comptime name: []const u8) bool {
    return if (@hasField(@TypeOf(options), name)) @field(options, name) else false;
}

fn inherits(comptime Base: ?type, comptime option: []const u8) bool {
    const Class = Base orelse return false;
    return @field(Definition(Class), option);
}

/// Get the bases of class `T`, nearest first.
pub fn bases(comptime T: type) []const type {
    var list: []const type = &.{};
    var next = Definition(T).Base;
    while (next) |Base| : (next = Definition(Base).Base) list = list ++ .{Base};
    return list;
}

/// Find the nearest class that defines `name`, or return `null`.
/// A class defining `__eq__` has no `__hash__` unless it defines one too.
pub fn definer(comptime T: type, comptime name: []const u8) ?type {
    const Methods = @TypeOf(Definition(T).methods);
    if (@hasField(Methods, name)) return T;
    if (std.mem.eql(u8, name, "__hash__") and @hasField(Methods, "__eq__")) return null;
    return definer(Definition(T).Base orelse return null, name);
}

/// Check whether classes `A` and `B` have the same method `name`, or both lack it.
pub fn sameMethod(comptime A: type, comptime B: type, comptime name: []const u8) bool {
    const a = definer(A, name) orelse return definer(B, name) == null;
    const b = definer(B, name) orelse return false;
    const first = @field(Definition(a).methods, name);
    const second = @field(Definition(b).methods, name);
    return @TypeOf(first) == @TypeOf(second) and std.meta.eql(first, second);
}

fn SpecialMethods(comptime T: type) type {
    @setEvalBranchQuota(100_000);
    var names: []const []const u8 = &.{};
    var types: []const type = &.{};
    var attrs: []const std.lang.Type.Struct.FieldAttributes = &.{};

    for (slots.names) |name| {
        if (!fillsSlots(T, name)) continue;
        const Owner = definer(T, name) orelse continue;
        const entry = @field(Definition(Owner).methods, name);
        names = names ++ .{name};
        types = types ++ .{@TypeOf(entry)};
        attrs = attrs ++ .{std.lang.Type.Struct.FieldAttributes{ .@"comptime" = true, .default_value_ptr = &entry }};
    }
    return @Struct(.auto, null, names, types, attrs);
}

fn fillsSlots(comptime T: type, comptime name: []const u8) bool {
    // In abi3 builds, __del__ uses a flag after the class's own value, so every class with one fills its slot.
    if (std.mem.eql(u8, name, "__del__")) return true;
    for (slots.sharing(name)) |method| {
        if (@hasField(@TypeOf(Definition(T).methods), method)) return true;
    }
    return false;
}

/// Get the first field of Zig subclass `T`, which holds its base's value.
pub fn baseField(comptime T: type) [:0]const u8 {
    return @typeInfo(T).@"struct".field_names[0];
}

/// Get keyword parameter names accepted by the methods and constructor of `T`.
pub fn keywordNames(comptime T: type) []const [:0]const u8 {
    const definition = Definition(T);
    var names: []const [:0]const u8 = &.{};
    for (@typeInfo(@TypeOf(definition.methods)).@"struct".field_names) |method| {
        names = names ++ function.keywordNames(method, @field(definition.methods, method));
    }
    if (definition.constructs) names = names ++ function.keywordNames("init", definition.init);
    return names;
}
