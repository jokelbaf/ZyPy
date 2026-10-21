const std = @import("std");
const c = @import("python");

const class = @import("../class.zig");
const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const function = @import("../function.zig");
const borrowed = @import("../runtime/borrowed.zig");
const lock = @import("../runtime/lock.zig");
const ownership = @import("../runtime/ownership.zig");
const Object = @import("../types/Object.zig");

/// A computed attribute made by `py.property`.
pub fn Property(comptime Getter: type, comptime Options: type) type {
    return struct {
        get: Getter,
        options: Options,
    };
}

const PropertyOption = enum { set, doc };

/// Define a computed attribute with getter `get`, which takes an instance and returns its value.
/// Options: `.set` takes `*T` and a new value and returns `void` or `!void`; `.doc` sets the docstring.
pub fn property(comptime get: anytype, comptime options: anytype) Property(@TypeOf(get), @TypeOf(options)) {
    if (@typeInfo(@TypeOf(options)) != .@"struct") {
        @compileError("py.property: the options must be a struct literal, such as .{ .doc = \"The length.\" }");
    }
    inline for (@typeInfo(@TypeOf(options)).@"struct".field_names) |field| {
        if (std.meta.stringToEnum(PropertyOption, field) == null) {
            @compileError("py.property: unknown option ." ++ field ++ " (expected .set or .doc)");
        }
    }
    return .{ .get = get, .options = options };
}

/// Field and property accessors for a class, including an optional `__dict__`.
pub fn GetSet(comptime scope: function.Scope, comptime fields: anytype, comptime properties: anytype, comptime dict: bool) type {
    const T = scope.Class.?;
    const context = "'" ++ scope.class_name ++ "'";
    const field_names = @typeInfo(@TypeOf(fields)).@"struct".field_names;
    const property_names = @typeInfo(@TypeOf(properties)).@"struct".field_names;

    for (field_names) |field| {
        if (!@hasField(T, field)) {
            @compileError(context ++ ": .fields has '" ++ field ++ "', which isn't a field of " ++ @typeName(T));
        }
        if (dict and std.mem.eql(u8, field, "__dict__")) {
            @compileError(context ++ ": the class has .dict, so it can't have a field named '__dict__'");
        }
        for (property_names) |prop| {
            if (std.mem.eql(u8, field, prop)) @compileError(context ++ ": '" ++ field ++ "' is both a field and a property");
        }
    }

    for (property_names) |prop| {
        if (dict and std.mem.eql(u8, prop, "__dict__")) {
            @compileError(context ++ ": the class has .dict, so it can't have a property named '__dict__'");
        }
    }
    const extra = @intFromBool(dict);

    return struct {
        pub const names = field_names ++ property_names;

        /// The attribute table. CPython retains a pointer to it.
        pub var table: [names.len + extra + 1]c.PyGetSetDef = blk: {
            var entries: [names.len + extra + 1]c.PyGetSetDef = undefined;
            for (field_names, 0..) |field, i| {
                const access = FieldAccess(scope, field, @field(fields, field));
                entries[i] = .{
                    .name = field.ptr,
                    .get = &access.get,
                    .set = if (access.writable) &access.set else null,
                    .doc = null,
                    .closure = null,
                };
            }
            for (property_names, field_names.len..) |prop, i| {
                const access = PropertyAccess(scope, prop, @field(properties, prop));
                entries[i] = .{
                    .name = prop.ptr,
                    .get = &access.get,
                    .set = if (access.writable) &access.set else null,
                    .doc = if (access.text) |text| text.ptr else null,
                    .closure = null,
                };
            }
            if (dict) {
                entries[names.len] = .{
                    .name = "__dict__",
                    .get = &c.PyObject_GenericGetDict,
                    .set = &c.PyObject_GenericSetDict,
                    .doc = null,
                    .closure = null,
                };
            }
            entries[names.len + extra] = std.mem.zeroes(c.PyGetSetDef);
            break :blk entries;
        };
    };
}

fn FieldAccess(comptime scope: function.Scope, comptime field: [:0]const u8, comptime mode: anytype) type {
    const T = scope.Class.?;
    const context = "'" ++ scope.class_name ++ "'";
    const Field = @FieldType(T, field);
    if (@TypeOf(mode) != @EnumLiteral() or (mode != .read_only and mode != .read_write)) {
        @compileError(context ++ ": field '" ++ field ++ "' must be .read_only or .read_write");
    }
    const is_writable = mode == .read_write;
    if (is_writable and ownership.holdsByteSlice(Field)) {
        @compileError(context ++ ": field '" ++ field ++ "' can't be .read_write: a []const u8 would point " ++
            "into the assigned object (use py.Bytes)");
    }

    const runs_without_gil = scope.Module.runs_without_gil;

    return struct {
        const writable = is_writable;

        fn get(self: [*c]c.PyObject, _: ?*anyopaque) callconv(.c) [*c]c.PyObject {
            var section: lock.Section = .{};
            defer section.end();
            if (runs_without_gil) section.begin(self.?, null);

            const obj = conversion.toPythonHeld(@field(class.valueOf(T, self.?), field)) catch return null;
            return obj.ptr;
        }

        fn set(self: [*c]c.PyObject, new: [*c]c.PyObject, _: ?*anyopaque) callconv(.c) c_int {
            const frame = borrowed.enter(runs_without_gil);
            defer frame.leave();

            const value: *c.PyObject = new orelse {
                c.PyErr_SetString(c.PyExc_AttributeError, "can't delete attribute '" ++ field ++ "'");
                return -1;
            };
            const converted = conversion.fromPython(Field, .borrow(value)) catch return -1;

            var old = replace(self.?, ownership.retain(converted));
            ownership.release(&old);
            return 0;
        }

        fn replace(self: *c.PyObject, value: Field) Field {
            var section: lock.Section = .{};
            defer section.end();
            if (runs_without_gil) section.begin(self, null);

            const slot = &@field(class.valueOf(T, self), field);
            const old = slot.*;
            slot.* = value;
            return old;
        }
    };
}

/// Property options with defaults applied. Accept a getter or `py.property(...)`.
pub fn PropertyDefinition(comptime class_name: []const u8, comptime prop: []const u8, comptime entry: anytype) type {
    const context = "'" ++ class_name ++ "'";
    const Entry = @TypeOf(entry);
    const is_property = @typeInfo(Entry) == .@"struct" and @hasField(Entry, "get") and @hasField(Entry, "options") and
        Entry == Property(@FieldType(Entry, "get"), @FieldType(Entry, "options"));
    if (!is_property and @typeInfo(Entry) != .@"fn") {
        @compileError(context ++ ": property '" ++ prop ++ "' must be a function or py.property(...)");
    }
    const options = if (is_property) entry.options else .{};

    return struct {
        pub const get = if (is_property) entry.get else entry;
        pub const set = if (@hasField(@TypeOf(options), "set")) options.set else null;
        pub const doc: ?[:0]const u8 = if (@hasField(@TypeOf(options), "doc"))
            function.text(context ++ ": the .doc of property '" ++ prop ++ "'", options.doc)
        else
            null;
    };
}

fn PropertyAccess(comptime scope: function.Scope, comptime prop: [:0]const u8, comptime entry: anytype) type {
    const name = scope.class_name;
    const context = "'" ++ name ++ "'";
    const definition = PropertyDefinition(name, prop, entry);
    const Getter = function.SlotCall(name ++ "." ++ prop, definition.get, scope, 0);

    return struct {
        const writable = @TypeOf(definition.set) != @TypeOf(null);
        const text = definition.doc;

        fn get(self: [*c]c.PyObject, _: ?*anyopaque) callconv(.c) [*c]c.PyObject {
            const convert = struct {
                fn convert(value: Getter.Payload) errors.Error!Object {
                    return conversion.intoPython(value);
                }
            }.convert;
            const result = Getter.invoke(self.?, .{}, .raise, convert) catch return null;
            return result.?.ptr;
        }

        fn set(self: [*c]c.PyObject, new: [*c]c.PyObject, _: ?*anyopaque) callconv(.c) c_int {
            const value: *c.PyObject = new orelse {
                c.PyErr_SetString(c.PyExc_AttributeError, "can't delete attribute '" ++ prop ++ "'");
                return -1;
            };
            const Setter = function.SlotCall(name ++ "." ++ prop, definition.set, scope, 1);
            if (Setter.Payload != void) {
                @compileError(context ++ ": the setter of property '" ++ prop ++ "' must return void or an error " ++
                    "union of it");
            }
            const convert = struct {
                fn convert(_: void) errors.Error!void {}
            }.convert;
            _ = Setter.invoke(self.?, .{value}, .raise, convert) catch return -1;
            return 0;
        }
    };
}
