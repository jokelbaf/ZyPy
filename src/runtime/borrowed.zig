const std = @import("std");
const c = @import("python");

const errors = @import("../errors.zig");
const Object = @import("../types/Object.zig");
const api = @import("api.zig");
const gc = @import("gc.zig");
const memory = @import("memory.zig");

/// Whether container reads need extra references to protect items from concurrent removal.
pub const enabled = api.free_threaded;

threadlocal var kept: Kept = .{};

const Kept = struct {
    first: [16]*c.PyObject = undefined,
    rest: std.ArrayList(*c.PyObject) = .empty,
    len: usize = 0,
    depth: usize = 0,
    keeping: bool = false,
};

/// The references that a call keeps, released by `leave`.
pub const Frame = struct {
    state: if (enabled) State else void,

    const State = struct {
        start: usize,
        keeps: bool,
        outer: bool,
    };

    /// Release the references kept since `enter`.
    pub fn leave(self: Frame) void {
        if (!enabled) return;
        const state = self.state;

        // Releasing can run Python code, which must not replace an exception being raised.
        const exception = if (kept.len > state.start) c.PyErr_GetRaisedException() else null;
        defer if (exception) |raised| c.PyErr_SetRaisedException(raised);
        // Release one reference at a time because Python cleanup may create nested frames.
        while (kept.len > state.start) {
            kept.len -= 1;
            const obj = if (kept.len < kept.first.len) kept.first[kept.len] else kept.rest.pop().?;
            c.Py_DecRef(obj);
        }

        kept.keeping = state.outer;
        if (!state.keeps) return;
        kept.depth -= 1;
        if (kept.depth == 0) kept.rest.clearAndFree(memory.raw_allocator);
    }
};

/// Open a frame on free-threaded Python. Call `leave` when finished.
/// With `keeps`, retain container reads until `leave`; otherwise release them immediately.
pub fn enter(comptime keeps: bool) Frame {
    if (!enabled) return .{ .state = {} };

    const outer = kept.keeping;
    kept.keeping = keeps;
    if (keeps) kept.depth += 1;
    return .{ .state = .{ .start = kept.len, .keeps = keeps, .outer = outer } };
}

/// Check whether a call on this thread keeps references.
pub fn active() bool {
    return enabled and kept.keeping;
}

/// Keep `obj` alive until the current call returns, consuming an owned reference or creating a new one.
/// Release that reference immediately if retention is disabled.
pub fn keep(obj: Object) errors.Error!void {
    const ptr = if (obj.owned) obj.ptr else obj.newRef().ptr;
    if (!active()) return c.Py_DecRef(ptr);

    if (kept.len < kept.first.len) {
        kept.first[kept.len] = ptr;
    } else {
        kept.rest.append(memory.raw_allocator, ptr) catch {
            c.Py_DecRef(ptr);
            return errors.raiseZigError(error.OutOfMemory, .{});
        };
    }
    kept.len += 1;
}

/// Keep every Python object that `value.*` references until the current call returns.
pub fn keepReferences(value: anytype) errors.Error!void {
    if (!active()) return;
    if (gc.visit(value, &keepVisited, null) != 0) return error.PythonError;
}

fn keepVisited(obj: [*c]c.PyObject, _: ?*anyopaque) callconv(.c) c_int {
    keep(.borrow(obj.?)) catch return -1;
    return 0;
}

/// Release container reads before the current free-threaded call returns, for example in a loop.
/// Items read in the scope are invalid after `end`. Scopes nest and do nothing on Python with the GIL.
pub const BorrowScope = struct {
    frame: Frame,

    /// Start a scope.
    pub fn begin() BorrowScope {
        return .{ .frame = enter(true) };
    }

    /// Release the items read from containers since `begin`.
    pub fn end(self: BorrowScope) void {
        self.frame.leave();
    }
};
