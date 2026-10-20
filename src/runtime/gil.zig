const std = @import("std");
const c = @import("python");

const class = @import("../class.zig");
const borrowed = @import("borrowed.zig");
const reflection = @import("reflection.zig");

/// Attach a Zig thread to Python: `const gil = py.Gil.acquire(); defer gil.release();`.
/// Acquire the GIL on Python builds that use it.
pub const Gil = struct {
    state: c.PyGILState_STATE,
    frame: borrowed.Frame,

    /// Attach the thread to Python and acquire the GIL if needed. Calls may nest.
    pub fn acquire() Gil {
        const state = c.PyGILState_Ensure();
        return .{ .state = state, .frame = borrowed.enter(true) };
    }

    /// Undo `acquire`, releasing container references retained since that call.
    pub fn release(self: Gil) void {
        self.frame.leave();
        c.PyGILState_Release(self.state);
    }
};

/// Call `func` with `args` while releasing the GIL so other Python threads can run.
/// `func` must not use Python. Parameter and result types that require the GIL are compile errors.
pub fn allowThreads(comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) Result(func) {
    const info = @typeInfo(@TypeOf(func)).@"fn";
    inline for (info.param_types, 1..) |Param, position| {
        if (comptime needsGil(Param.?)) {
            @compileError(std.fmt.comptimePrint("py.allowThreads: parameter {d} is a {s}, which needs the GIL", .{
                position, @typeName(Param.?),
            }));
        }
    }
    if (comptime needsGil(Result(func))) {
        @compileError("py.allowThreads: the result is a " ++ @typeName(Result(func)) ++ ", which needs the GIL");
    }

    return callWithoutGil(func, args);
}

/// Call `func` without the GIL. The caller must check that its types are safe without the GIL.
pub fn callWithoutGil(comptime func: anytype, args: anytype) Result(func) {
    const state = c.PyEval_SaveThread();
    defer c.PyEval_RestoreThread(state);

    return @call(.auto, func, args);
}

/// Check whether using `T` requires the GIL.
/// Python conversion types require it unless they declare `usable_without_gil = true`.
pub fn needsGil(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (reflection.isConversionType(T)) return !usableWithoutGil(T);
            return reflection.any(info.field_types, needsGil);
        },
        .@"union" => |info| return reflection.any(info.field_types, needsGil),
        .optional => |info| return needsGil(info.child),
        .error_union => |info| return needsGil(info.payload),
        .array => |info| return needsGil(info.child),
        // Look through one pointer only, since linked types would recurse forever. Instances change without the GIL.
        .pointer => |info| return class.isClass(info.child) or (reflection.isConversionType(info.child) and !usableWithoutGil(info.child)),
        else => return false,
    }
}

fn usableWithoutGil(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "usable_without_gil") and T.usable_without_gil,
        else => false,
    };
}

fn Result(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}
