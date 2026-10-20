const std = @import("std");
const c = @import("python");

const class = @import("../class.zig");
const errors = @import("../errors.zig");
const function = @import("../function.zig");
const api = @import("../runtime/api.zig");
const borrowed = @import("../runtime/borrowed.zig");
const gil = @import("../runtime/gil.zig");
const lock = @import("../runtime/lock.zig");
const ownership = @import("../runtime/ownership.zig");
const Signature = @import("Signature.zig");

/// The state of one call of `Callable`, whose Python parameters `signature` describes.
pub fn Invocation(
    comptime context: []const u8,
    comptime Callable: type,
    comptime signature: Signature,
    comptime scope: function.Scope,
    comptime mode: function.Mode,
) type {
    const locks = comptime Locks.of(context, signature, scope);
    comptime checkLendable(context, signature);

    return struct {
        const Self = @This();

        pub const Payload = switch (@typeInfo(Callable.Result)) {
            .error_union => |info| info.payload,
            else => Callable.Result,
        };

        values: Callable.Params = undefined,
        converted: usize = 0,
        filled: usize = 0,
        section: lock.Section = .{},
        frame: borrowed.Frame,

        /// Start a call. On free-threaded Python, items it reads from containers stay alive until `end`.
        pub fn begin() Self {
            return .{ .frame = borrowed.enter(scope.Module.runs_without_gil) };
        }

        /// Release locks and converted arguments after converting the result.
        /// The result may borrow from those arguments.
        pub fn end(self: *Self) void {
            self.section.end();
            inline for (signature.hidden, 0..) |hidden, i| {
                if (i < self.filled) ownership.deinit(self.values[hidden.index]);
            }
            inline for (signature.params, 0..) |param, i| {
                if (i < self.converted) ownership.deinit(self.values[param.index]);
            }
            self.frame.leave();
        }

        /// Store converted argument `i`, retaining any references in copied instances.
        pub fn set(self: *Self, comptime i: usize, value: signature.params[i].type) void {
            self.values[signature.params[i].index] = ownership.ownCopies(value);
            self.converted = i + 1;
        }

        /// Lock objects and fill the receiver and module state for this call.
        /// `receiver` is the called object or module; `subtype` is the type being constructed.
        pub fn prepare(self: *Self, receiver: ?*c.PyObject, subtype: ?*c.PyTypeObject) errors.Error!void {
            if (scope.Module.runs_without_gil) try self.lockUsed(receiver, subtype);
            inline for (signature.hidden, 0..) |hidden, i| {
                self.values[hidden.index] = switch (hidden.role) {
                    .receiver => ownership.ownCopies(class.receiver(hidden.type, scope.Class.?, receiver.?)),
                    .class => .{ .obj = .borrow(receiver.?) },
                    .state => try scope.Module.stateOf(try moduleOf(receiver, subtype)),
                };
                self.filled = i + 1;
            }
        }

        /// Call the function with borrowed arguments.
        /// Map errors using `table` first, then the module's error mappings.
        pub fn call(self: *Self, comptime table: anytype, comptime release_gil: bool) errors.Error!Payload {
            const passed = if (Callable.moves_arguments) self.values else ownership.lend(self.values);
            const result = if (release_gil) gil.callWithoutGil(Callable.call, .{passed}) else Callable.call(passed);
            // The arguments belong to the result now.
            if (Callable.moves_arguments) self.converted = 0;

            if (@typeInfo(Callable.Result) != .error_union) return result;
            return result catch |err| errors.raiseZigError(err, .{ table, scope.Module.error_table });
        }

        fn lockUsed(self: *Self, receiver: ?*c.PyObject, subtype: ?*c.PyTypeObject) errors.Error!void {
            var objects: [2]?*c.PyObject = .{ null, null };
            var count: usize = 0;
            if (locks.receiver) {
                objects[count] = receiver.?;
                count += 1;
            }
            if (locks.module) {
                objects[count] = try moduleOf(receiver, subtype);
                count += 1;
            }
            inline for (locks.params) |i| {
                const param = signature.params[i];
                if (instanceOf(param.type, self.values[param.index])) |instance| {
                    objects[count] = instance;
                    count += 1;
                }
            }
            self.section.begin(objects[0], objects[1]);
        }

        /// Borrow the defining module from the receiver or constructed type.
        /// Return `null` for static methods that receive neither.
        pub fn findModule(receiver: ?*c.PyObject, subtype: ?*c.PyTypeObject) ?*c.PyObject {
            return switch (mode) {
                .function => receiver.?,
                .method => scope.Module.findModuleOfType(api.typeOf(receiver.?)),
                .static, .class_method => scope.Module.findModuleOfType(@ptrCast(receiver orelse return null)),
                .constructor => scope.Module.findModuleOfType(subtype.?),
            };
        }

        fn moduleOf(receiver: ?*c.PyObject, subtype: ?*c.PyTypeObject) errors.Error!*c.PyObject {
            return findModule(receiver, subtype) orelse errors.raise(.SystemError, "can't find the module of " ++ context);
        }
    };
}

/// Check the `.errors` table of a function that returns `Result`.
pub fn checkErrors(comptime context: []const u8, comptime Result: type, comptime table: anytype) void {
    const info = @typeInfo(@TypeOf(table));
    if (info == .@"struct" and info.@"struct".field_names.len == 0) return;
    if (@typeInfo(Result) != .error_union) {
        @compileError(context ++ ": .errors needs a function that returns an error union, such as !i64");
    }
    errors.checkMapping(context, table, @typeInfo(@typeInfo(Result).error_union.error_set).error_set.error_names);
}

fn checkLendable(comptime context: []const u8, comptime signature: Signature) void {
    for (signature.params, 1..) |param, position| {
        const Type = ownership.unlendable(param.type) orelse continue;
        const param_label = if (param.name) |name| "'" ++ name ++ "'" else std.fmt.comptimePrint("{d}", .{position});
        @compileError(context ++ ": parameter " ++ param_label ++ " holds a " ++ @typeName(Type) ++ ", which has a " ++
            "deinit but no owned field, so the function could release it before ZyPy does (add owned: bool = true, " ++
            "which ZyPy clears in the copy it passes, and make deinit do nothing when it's false)");
    }
}

const Locks = struct {
    receiver: bool,
    module: bool,
    params: []const usize,

    fn of(comptime context: []const u8, comptime signature: Signature, comptime scope: function.Scope) Locks {
        if (!scope.Module.free_threaded) return .{ .receiver = false, .module = false, .params = &.{} };

        var params: []const usize = &.{};
        for (signature.params, 0..) |param, i| {
            if (pointedClass(param.type) != null) params = params ++ .{i};
        }
        var receiver = false;
        var module = false;
        for (signature.hidden) |hidden| switch (hidden.role) {
            .receiver => receiver = true,
            .class => {},
            .state => module = true,
        };

        const count = @as(usize, @intFromBool(receiver)) + @intFromBool(module) + params.len;
        if (count > 2) {
            @compileError(std.fmt.comptimePrint("{s}: a call in a .free_threaded module locks at most two objects " ++
                "(the instance it's called on, the module for its state, and instances passed by pointer), but " ++
                "this one needs {d} (pass the other instances by value)", .{ context, count }));
        }
        return .{ .receiver = receiver, .module = module, .params = params };
    }
};

fn pointedClass(comptime T: type) ?type {
    const Pointer = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    const info = switch (@typeInfo(Pointer)) {
        .pointer => |pointer| pointer,
        else => return null,
    };
    return if (info.size == .one and class.isClass(info.child)) info.child else null;
}

fn instanceOf(comptime T: type, value: T) ?*c.PyObject {
    const Class = pointedClass(T).?;
    const pointer = if (@typeInfo(T) == .optional) value orelse return null else value;
    return class.instanceOf(Class, pointer);
}
