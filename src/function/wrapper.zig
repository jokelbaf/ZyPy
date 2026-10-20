const std = @import("std");
const c = @import("python");

const class = @import("../class.zig");
const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const function = @import("../function.zig");
const api = @import("../runtime/api.zig");
const gil = @import("../runtime/gil.zig");
const Object = @import("../types/Object.zig");
const arguments = @import("arguments.zig");
const Binding = @import("binding.zig").Binding;
const callable = @import("callable.zig");
const Invocation = @import("invocation.zig").Invocation;
const checkErrors = @import("invocation.zig").checkErrors;
const Signature = @import("Signature.zig");

/// A Python-callable wrapper for the function described by `definition`.
pub fn Wrapper(comptime name: [:0]const u8, comptime definition: type, comptime scope: function.Scope, comptime mode: function.Mode) type {
    const label = function.labelOf(name, scope, mode);
    const context = "'" ++ label ++ "'";
    const Callable = callable.Callable(context, definition.func);
    const roles = callable.hiddenRoles(Callable.types, scope, mode);
    const signature: Signature = comptime .init(label, Callable.types, definition.params, definition.defaults, &roles);
    const Call = Invocation(context, Callable, signature, scope, mode);
    const Bind = Binding(label, signature, scope.Module.keyword_names);

    comptime checkErrors(context, Callable.Result, definition.errors);
    if (definition.release_gil) comptime checkWithoutGil(context, signature, Call.Payload);
    if (mode == .constructor and Call.Payload != scope.Class.?) {
        @compileError(context ++ ": the constructor must return " ++ @typeName(scope.Class.?) ++
            " or an error union of it, not " ++ @typeName(Callable.Result));
    }

    // Static methods using module state need the class, which METH_STATIC does not receive.
    const binds_class = mode == .class_method or (mode == .static and signature.hidden.len > 0);
    const keywords = signature.keywords();
    const receiver_flag = blk: {
        if (binds_class) break :blk c.METH_CLASS;
        if (mode == .static) break :blk c.METH_STATIC;
        break :blk 0;
    };

    return struct {
        pub const flags = c.METH_FASTCALL | (if (keywords) c.METH_KEYWORDS else 0) | receiver_flag;
        pub const call = if (keywords) callWithKeywords else callPositional;

        pub const header: ?[]const u8 = signature.header(name, definition.defaults, switch (mode) {
            .method => .instance,
            .static, .class_method => if (binds_class) .class else .none,
            .function, .constructor => .none,
        });

        pub const doc: ?[*:0]const u8 = if (header == null and definition.doc == null)
            null
        else
            std.fmt.comptimePrint("{s}{s}", .{ header orelse "", definition.doc orelse "" });

        fn callPositional(self: [*c]c.PyObject, args: [*c]const [*c]c.PyObject, nargs: c.Py_ssize_t) callconv(.c) [*c]c.PyObject {
            // CPython passes a null array when there are no arguments.
            const given: []const [*c]c.PyObject = if (nargs == 0) &.{} else args[0..@intCast(nargs)];
            return finish(invoke(self, given, &.{}, null, null));
        }

        fn callWithKeywords(
            self: [*c]c.PyObject,
            args: [*c]const [*c]c.PyObject,
            nargs: c.Py_ssize_t,
            kwnames: [*c]c.PyObject,
        ) callconv(.c) [*c]c.PyObject {
            const names: ?*c.PyObject = kwnames;
            const positional: usize = @intCast(nargs);
            const keyword: usize = if (names) |tuple| api.tupleSize(tuple) else 0;
            const all: []const [*c]c.PyObject = if (positional + keyword == 0) &.{} else args[0 .. positional + keyword];
            return finish(invoke(self, all[0..positional], all[positional..], names, null));
        }

        /// Create an instance of `subtype`, for the `tp_new` slot.
        pub fn new(subtype: ?*c.PyTypeObject, args: [*c]c.PyObject, kwargs: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            return finish(fromTuple(null, subtype, args.?, kwargs));
        }

        /// Call the instance `self`, for the `tp_call` slot.
        pub fn callTuple(self: [*c]c.PyObject, args: [*c]c.PyObject, kwargs: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            return finish(fromTuple(self, null, args.?, kwargs));
        }

        fn fromTuple(self: ?*c.PyObject, subtype: ?*c.PyTypeObject, args: *c.PyObject, kwargs: ?*c.PyObject) errors.Error!Object {
            var items: arguments.TupleItems = try .init(args);
            defer items.deinit();
            const given = items.slice();

            const dict = kwargs orelse return invoke(self, given, &.{}, null, subtype);
            if (c.PyDict_Size(dict) == 0) return invoke(self, given, &.{}, null, subtype);
            if (!keywords) return errors.raise(.TypeError, label ++ "() takes no keyword arguments");

            const keyword_arguments: arguments.KeywordArguments = try .init(dict);
            defer keyword_arguments.deinit();

            return invoke(self, given, keyword_arguments.values, keyword_arguments.names, subtype);
        }

        fn finish(result: errors.Error!Object) [*c]c.PyObject {
            const obj = result catch {
                std.debug.assert(c.PyErr_Occurred() != null);
                return null;
            };
            return obj.ptr;
        }

        fn invoke(
            self: ?*c.PyObject,
            given: []const [*c]c.PyObject,
            keyword_values: []const [*c]c.PyObject,
            kwnames: ?*c.PyObject,
            subtype: ?*c.PyTypeObject,
        ) errors.Error!Object {
            const module_obj = if (kwnames == null) null else Call.findModule(self, subtype);
            const interned = if (module_obj) |found| scope.Module.internedKeywords(found) else null;
            const bound = try Bind.bind(given, keyword_values, kwnames, interned);
            defer bound.deinit();

            // Keep the Python objects made from defaults alive until the call returns.
            var holders: [signature.params.len]?Object = @splat(null);
            defer for (holders) |holder| if (holder) |obj| obj.deinit();

            var invocation: Call = .begin();
            defer invocation.end();
            inline for (signature.params, 0..) |param, i| invocation.set(i, try argument(param, &bound, i, &holders[i]));

            try invocation.prepare(self, subtype);
            const value = try invocation.call(definition.errors, definition.release_gil);
            if (mode == .constructor) return class.construct(scope.Class.?, subtype.?, value);
            return conversion.intoPython(value);
        }

        fn argument(comptime param: Signature.Param, bound: *const Bind.Bound, comptime i: usize, holder: *?Object) errors.Error!param.type {
            switch (param.kind) {
                .var_positional => return .{ .items = bound.extra },
                .var_keyword => return .{ .dict = if (bound.kwargs) |dict| .{ .obj = .borrow(dict.obj.ptr) } else null },
                else => {},
            }
            const arg = bound.slots[i] orelse return defaultValue(param, holder);
            return conversion.fromPython(param.type, .borrow(arg));
        }

        fn defaultValue(comptime param: Signature.Param, holder: *?Object) errors.Error!param.type {
            switch (param.default) {
                // Binding checked that the argument was passed.
                .none => unreachable,
                .null => return null,
                .value => {},
            }

            const value = @field(definition.defaults, param.name.?);
            if (comptime Signature.isPlain(param.type)) {
                return comptime Signature.coerce(param.type, value, signature.defaultContext(param));
            }
            if (@typeInfo(param.type) == .optional and isNull(value)) return null;

            const obj = try conversion.toPython(value);
            holder.* = obj;
            return conversion.fromPython(param.type, obj);
        }
    };
}

fn checkWithoutGil(comptime context: []const u8, comptime signature: Signature, comptime Payload: type) void {
    for (signature.hidden) |hidden| {
        if (hidden.role == .state) {
            @compileError(context ++ ": .release_gil can't be used with a " ++ @typeName(hidden.type) ++
                " parameter: other threads can use the module's state while the GIL is released");
        }
        if (gil.needsGil(hidden.type)) {
            @compileError(context ++ ": .release_gil can't be used with a " ++ @typeName(hidden.type) ++
                " parameter: Python objects need the GIL");
        }
    }
    for (signature.params, 1..) |param, position| {
        if (gil.needsGil(param.type)) {
            const param_label = if (param.name) |n| "'" ++ n ++ "'" else std.fmt.comptimePrint("{d}", .{position});
            @compileError(context ++ ": .release_gil can't be used with parameter " ++ param_label ++ ", a " ++
                @typeName(param.type) ++ ": Python objects need the GIL (use plain values, slices or buffers)");
        }
    }
    if (gil.needsGil(Payload)) {
        @compileError(context ++ ": .release_gil can't be used with a " ++ @typeName(Payload) ++
            " result: Python objects need the GIL (return a plain value)");
    }
}

fn isNull(comptime value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .null => true,
        .optional => value == null,
        else => false,
    };
}
