const std = @import("std");
const c = @import("python");

const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const function = @import("../function.zig");
const callable = @import("callable.zig");
const Invocation = @import("invocation.zig").Invocation;
const checkErrors = @import("invocation.zig").checkErrors;
const Signature = @import("Signature.zig");

/// A call to a special method or property accessor with `arity` arguments after the instance.
pub fn SlotCall(comptime label: [:0]const u8, comptime entry: anytype, comptime scope: function.Scope, comptime arity: usize) type {
    const definition = function.Definition(label, entry);
    const context = "'" ++ label ++ "'";
    for (definition.given) |option| {
        if (!std.mem.eql(u8, option, "errors")) @compileError(context ++ ": only .errors applies here, not ." ++ option);
    }
    const Callable = callable.Callable(context, definition.func);
    const roles = callable.hiddenRoles(Callable.types, scope, .method);
    const signature: Signature = comptime .init(label, Callable.types, null, .{}, &roles);
    const Call = Invocation(context, Callable, signature, scope, .method);

    if (signature.hidden.len == 0 or signature.hidden[0].role != .receiver or signature.hidden[0].index != 0) {
        @compileError(context ++ " must take the instance first, such as self: *const " ++ @typeName(scope.Class.?));
    }
    if (signature.params.len != arity) {
        @compileError(std.fmt.comptimePrint("{s} must take {d} parameter{s} after the instance, not {d}", .{
            context, arity, if (arity == 1) "" else "s", signature.params.len,
        }));
    }

    return struct {
        pub const Payload = Call.Payload;

        /// Get the type of the parameter at `index`, not counting the instance and the state.
        pub fn ParamType(comptime index: usize) type {
            return signature.params[index].type;
        }

        /// What to do when an argument has the wrong type.
        pub const OnTypeError = enum {
            raise,
            /// Return `null`, so that the slot can return `NotImplemented`.
            not_implemented,
        };

        /// Call with borrowed Python arguments or converted values.
        /// Apply `convert` before releasing arguments, since the result may borrow from them.
        pub fn invoke(
            self: *c.PyObject,
            args: anytype,
            comptime on_type_error: OnTypeError,
            comptime convert: anytype,
        ) errors.Error!?Converted(convert) {
            // Resolving .errors emits the function, which stub generation must avoid.
            comptime checkErrors(context, Callable.Result, definition.errors);

            var invocation: Call = .begin();
            defer invocation.end();
            inline for (signature.params, 0..) |param, i| {
                invocation.set(i, if (@TypeOf(args[i]) == *c.PyObject)
                    conversion.fromPython(param.type, .borrow(args[i])) catch |err| {
                        if (on_type_error == .not_implemented and c.PyErr_ExceptionMatches(c.PyExc_TypeError) != 0) {
                            c.PyErr_Clear();
                            return null;
                        }
                        return err;
                    }
                else
                    args[i]);
            }

            try invocation.prepare(self, null);
            return try convert(try invocation.call(definition.errors, false));
        }
    };
}

/// Count the parameters that a special method takes after the instance, not counting the module's state.
pub fn parameterCount(comptime label: [:0]const u8, comptime entry: anytype, comptime scope: function.Scope) usize {
    const definition = function.Definition(label, entry);
    const Callable = callable.Callable("'" ++ label ++ "'", definition.func);
    var count: usize = 0;
    for (callable.hiddenRoles(Callable.types, scope, .method)) |role| count += @intFromBool(role == null);
    return count;
}

fn Converted(comptime convert: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(convert)).@"fn".return_type.?).error_union.payload;
}
