const std = @import("std");
const c = @import("python");

const errors = @import("errors.zig");
const function = @import("function.zig");
const api = @import("runtime/api.zig");
const Registry = @import("runtime/registry.zig").Registry;
const syntax = @import("syntax.zig");
const Object = @import("types/Object.zig");
const Str = @import("types/Str.zig");
const Tuple = @import("types/Tuple.zig");

const Option = enum { doc };

/// Enum class options made by `py.enumClass`.
pub fn EnumClassOptions(comptime Options: type) type {
    return struct {
        options: Options,
    };
}

/// Expose a Zig enum as a Python `enum.Enum` class. Declare `pub const class = py.enumClass(.{ ... })`
/// in the enum and list it in the module's `.enums`. Members keep their integer values.
/// The optional `.doc` sets the docstring.
pub fn enumClass(comptime options: anytype) EnumClassOptions(@TypeOf(options)) {
    if (@typeInfo(@TypeOf(options)) != .@"struct") {
        @compileError("py.enumClass: the options must be a struct literal, such as .{ .doc = \"A color.\" }");
    }
    inline for (@typeInfo(@TypeOf(options)).@"struct".field_names) |field| {
        if (std.meta.stringToEnum(Option, field) == null) {
            @compileError("py.enumClass: unknown option ." ++ field ++ " (expected .doc)");
        }
    }
    return .{ .options = options };
}

/// Check whether `T` is an enum with a `pub const class = py.enumClass(...)` declaration.
pub fn isEnumClass(comptime T: type) bool {
    if (@typeInfo(T) != .@"enum" or !@hasDecl(T, "class")) return false;
    const Declared = @TypeOf(T.class);
    if (@typeInfo(Declared) != .@"struct" or !@hasField(Declared, "options")) return false;
    return Declared == EnumClassOptions(@FieldType(Declared, "options"));
}

/// The options of enum class `T`, each set to its default when not given.
pub fn Definition(comptime T: type) type {
    const options = T.class.options;
    return struct {
        pub const doc: ?[:0]const u8 = if (@hasField(@TypeOf(options), "doc"))
            function.text("py.enumClass(" ++ @typeName(T) ++ "): .doc", options.doc)
        else
            null;
    };
}

/// Check an enum listed in `.enums` as `name`: an exhaustive enum with tags that are valid member names.
pub fn check(comptime T: type, comptime name: []const u8) void {
    const context = "py.module: .enums: '" ++ name ++ "'";
    if (!isEnumClass(T)) {
        @compileError(context ++ " needs to be an enum with a pub const class = py.enumClass(...) declaration");
    }
    const info = @typeInfo(T).@"enum";
    if (info.mode != .exhaustive) @compileError(context ++ " must be an exhaustive enum");
    if (info.field_names.len == 0) @compileError(context ++ " has no tags");
    // Each tag is compared with every Python keyword.
    @setEvalBranchQuota(1_000 + 200 * info.field_names.len);
    for (info.field_names) |tag| {
        syntax.checkName(context, "member name", tag);
        if (isReserved(tag)) {
            @compileError(context ++ ": enum.Enum reserves the name '" ++ tag ++ "' (mro, _sunder_ names and " ++
                "names starting with __), so it can't be a member");
        }
    }
}

fn isReserved(comptime name: []const u8) bool {
    const sunder = name.len > 1 and name[0] == '_' and name[name.len - 1] == '_';
    return std.mem.eql(u8, name, "mro") or std.mem.startsWith(u8, name, "__") or sunder;
}

/// The members of one imported enum class, with their tag lookup table.
pub fn Members(comptime T: type) type {
    @setEvalBranchQuota(quota(T));
    const tags = std.enums.values(T);
    const capacity = std.math.ceilPowerOfTwoAssert(usize, 2 * tags.len);

    return struct {
        const Self = @This();

        /// Owned members, or null before initialization and after cleanup.
        tuple: ?*c.PyObject,
        /// Member pointers borrowed from `tuple`.
        keys: [capacity]?*c.PyObject,
        positions: [capacity]std.math.IntFittingRange(0, tags.len - 1),

        /// Create an owned enum class named `name` in `module_name` and store its members in `self`.
        pub fn create(self: *Self, module_name: Str, comptime name: [:0]const u8) errors.Error!Object {
            const enum_module = try Object.own(c.PyImport_ImportModule("enum"));
            defer enum_module.deinit();

            // A [:0]const u8 would convert to bytes.
            const class_name = try Str.init(name);
            defer class_name.deinit();

            const pairs = try Tuple.init(tags.len);
            defer pairs.deinit();
            for (tags, 0..) |tag, i| {
                const tag_name = try Str.init(@tagName(tag));
                defer tag_name.deinit();

                try pairs.set(i, .{ tag_name, @backingInt(tag) });
            }

            const class = try enum_module.callMethodKw(Object, "Enum", .{ class_name, pairs }, .{
                .module = module_name,
                .qualname = class_name,
            });
            errdefer class.deinit();
            if (Definition(T).doc) |doc| {
                const text = try Str.init(doc);
                defer text.deinit();

                try class.setAttr("__doc__", text);
            }

            const members = try Tuple.init(tags.len);
            errdefer members.deinit();
            for (tags, 0..) |tag, i| {
                const member = try class.getAttr(Object, @tagName(tag));
                defer member.deinit();

                try members.set(i, member);
            }

            self.* = .{ .tuple = members.obj.ptr, .keys = @splat(null), .positions = undefined };
            for (0..tags.len) |i| {
                const member = c.PyTuple_GetItem(members.obj.ptr, @intCast(i)).?;
                var slot = slotOf(member);
                while (self.keys[slot] != null) slot = (slot + 1) % capacity;
                self.keys[slot] = member;
                self.positions[slot] = @intCast(i);
            }
            return class;
        }

        fn find(self: *const Self, member: *c.PyObject) ?T {
            var slot = slotOf(member);
            while (self.keys[slot]) |key| : (slot = (slot + 1) % capacity) {
                if (key == member) return tags[self.positions[slot]];
            }
            return null;
        }

        fn get(self: *const Self, tag: T) Object {
            return Object.borrow(c.PyTuple_GetItem(self.tuple.?, @intCast(position(tag))).?).newRef();
        }

        /// Release the members. Releasing them again does nothing.
        pub fn release(self: *Self) void {
            const tuple = self.tuple orelse return;
            self.tuple = null;
            self.keys = @splat(null);
            c.Py_DecRef(tuple);
        }

        fn slotOf(member: *c.PyObject) usize {
            return std.hash.int(@intFromPtr(member)) % capacity;
        }

        fn position(tag: T) usize {
            @setEvalBranchQuota(comptime quota(T));
            const positions: Positions(T) = .{};
            return switch (tag) {
                inline else => |known| @field(positions, @tagName(known)),
            };
        }
    };
}

fn Positions(comptime T: type) type {
    @setEvalBranchQuota(quota(T));
    const names = @typeInfo(T).@"enum".field_names;
    var attributes: [names.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (&attributes, 0..) |*attribute, i| attribute.* = .{ .@"comptime" = true, .default_value_ptr = &@as(usize, i) };
    return @Struct(.auto, null, names, &@splat(usize), &attributes);
}

fn quota(comptime T: type) u32 {
    return 1_000 + 10 * @typeInfo(T).@"enum".field_names.len;
}

/// The members of enum class `T` in each interpreter, one entry per import of its module.
pub fn registry(comptime T: type) *Registry(*const Members(T)) {
    return &struct {
        var members: Registry(*const Members(T)) = .{};
    }.members;
}

/// Get a new reference to the member of `tag` in the newest import of the module in this interpreter.
/// Raise `RuntimeError` if the module isn't loaded.
pub fn memberOf(comptime T: type, tag: T) errors.Error!Object {
    const get = struct {
        fn get(wanted: T, members: *const Members(T)) ?Object {
            return members.get(wanted);
        }
    }.get;
    return registry(T).search(Object, tag, get) orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "enum " ++ @typeName(T) ++ " isn't loaded in this interpreter " ++
            "(import the module that lists it in .enums)");
        return error.PythonError;
    };
}

/// Get the tag of `obj`, a member of the class of `T` from any import of its module in this interpreter.
/// Raise `TypeError` for other objects.
pub fn tagOf(comptime T: type, obj: Object) errors.Error!T {
    const find = struct {
        fn find(wanted: *c.PyObject, members: *const Members(T)) ?T {
            return members.find(wanted);
        }
    }.find;
    if (registry(T).search(T, obj.ptr, find)) |tag| return tag;

    const expected = try memberOf(T, @field(T, @typeInfo(T).@"enum".field_names[0]));
    defer expected.deinit();

    _ = c.PyErr_Format(c.PyExc_TypeError, "expected %N, got %T", api.typeOf(expected.ptr), obj.ptr);
    return error.PythonError;
}
