const std = @import("std");

const class = @import("../class.zig");
const function = @import("../function.zig");
const Signature = @import("Signature.zig");

/// Parameter types, result type, and calling function for `func`.
/// Accept types that provide these declarations themselves.
pub fn Callable(comptime context: []const u8, comptime func: anytype) type {
    if (@TypeOf(func) == type) return func;

    const Fn = @TypeOf(func);
    const info = @typeInfo(Fn).@"fn";
    if (info.is_generic) @compileError(context ++ " can't have anytype or comptime parameters");

    return struct {
        pub const types: []const type = blk: {
            var list: [info.param_types.len]type = undefined;
            for (info.param_types, 0..) |Type, i| list[i] = Type.?;
            const final = list;
            break :blk &final;
        };
        pub const Params = std.meta.ArgsTuple(Fn);
        pub const Result = info.return_type.?;
        /// Whether the arguments move into the result, so the call neither lends nor releases them.
        pub const moves_arguments = false;

        pub fn call(values: Params) Result {
            return @call(.auto, func, values);
        }
    };
}

/// Identify parameters filled by ZyPy. Return `null` for parameters supplied by Python.
pub fn hiddenRoles(
    comptime types: []const type,
    comptime scope: function.Scope,
    comptime mode: function.Mode,
) [types.len]?Signature.Hidden.Role {
    var roles: [types.len]?Signature.Hidden.Role = undefined;
    for (types, 0..) |Type, i| roles[i] = roleOf(Type, i == 0, scope, mode);
    return roles;
}

fn roleOf(comptime Type: type, comptime first: bool, comptime scope: function.Scope, comptime mode: function.Mode) ?Signature.Hidden.Role {
    if (first and mode == .method and class.receiverKind(Type, scope.Class.?) != null) return .receiver;
    if (first and mode == .class_method) return .class;
    const State = scope.Module.State;
    if (State != void and (Type == *State or Type == *const State)) return .state;
    return null;
}

/// Check whether the first parameter of `Fn` is an instance of `Class`, which makes it a method.
pub fn takesReceiver(comptime Fn: type, comptime Class: type) bool {
    const First = firstParameter(Fn) orelse return false;
    return class.receiverKind(First, Class) != null;
}

/// Check whether the first parameter of `Fn` is `py.Class(Class)`, which makes it a class method.
pub fn takesClass(comptime Fn: type, comptime Class: type) bool {
    const First = firstParameter(Fn) orelse return false;
    return class.receivesClass(First, Class);
}

fn firstParameter(comptime Fn: type) ?type {
    if (Fn == type) return null;
    const types = @typeInfo(Fn).@"fn".param_types;
    return if (types.len > 0) types[0] else null;
}
