const std = @import("std");
const c = @import("python");

const errors = @import("../../errors.zig");
const Object = @import("../Object.zig");
const format = @import("format.zig");
const Offsets = @import("Offsets.zig");

/// Whether a view may write to the memory.
pub const Access = enum { read_only, writable };

pub const Kind = enum {
    /// C-contiguous memory. A view of `u8` reads the raw bytes of any buffer.
    contiguous,
    /// Any strides. A view of `u8` accepts only one-byte items, since strides step over whole items.
    strided,
};

/// A copy of a buffer's shape and strides, independent of the view's address.
pub const Layout = struct {
    shape: [c.PyBUF_MAX_NDIM]usize,
    strides: [c.PyBUF_MAX_NDIM]isize,
};

/// Acquire a buffer of `T` items into `view` and `layout`.
/// Raise `BufferError`, `TypeError`, or `ValueError` for an incompatible or invalid buffer.
pub fn acquire(
    comptime T: type,
    comptime kind: Kind,
    comptime access: Access,
    obj: Object,
    view: *c.Py_buffer,
    layout: *Layout,
) errors.Error!void {
    const strides = if (kind == .contiguous) c.PyBUF_C_CONTIGUOUS else c.PyBUF_STRIDES;
    const flags = strides | c.PyBUF_FORMAT | if (access == .writable) c.PyBUF_WRITABLE else 0;
    try errors.check(c.PyObject_GetBuffer(obj.ptr, view, flags));
    errdefer c.PyBuffer_Release(view);

    try copyLayout(view, layout);
    if (kind == .contiguous) try checkContiguous(view, layout);
    try checkOffsets(view, layout);
    if (access == .writable and view.readonly != 0) return errors.raise(.BufferError, "buffer is read-only");

    try checkItems(T, kind, view);
    if (kind == .strided and view.len > 0) {
        for (layout.strides[0..@intCast(view.ndim)]) |stride| {
            if (@mod(stride, @alignOf(T)) != 0) {
                return errors.raise(.BufferError, "buffer strides are not aligned for " ++ @typeName(T));
            }
        }
    }
    if (T == bool) try checkBools(kind, view, layout);
}

/// Release a buffer from `acquire`.
pub fn release(view: *const c.Py_buffer, layout: *const Layout) void {
    // Restore shape and stride pointers because moving the view can invalidate them.
    var copy = view.*;
    if (copy.shape != null) copy.shape = @ptrCast(@constCast(&layout.shape));
    if (copy.strides != null) copy.strides = @constCast(&layout.strides);
    c.PyBuffer_Release(&copy);
}

fn copyLayout(view: *const c.Py_buffer, layout: *Layout) errors.Error!void {
    if (view.ndim < 0 or view.ndim > c.PyBUF_MAX_NDIM) {
        return errors.raiseFmt(.BufferError, "buffer has {d} dimensions (expected 0 to {d})", .{ view.ndim, c.PyBUF_MAX_NDIM });
    }
    if (view.itemsize <= 0) return errors.raiseFmt(.BufferError, "buffer item size must be positive, not {d}", .{view.itemsize});
    // Views of exporters that need suboffsets would read the wrong memory.
    if (view.suboffsets != null) return errors.raise(.BufferError, "buffer has suboffsets, which weren't requested");

    const ndim: usize = @intCast(view.ndim);
    if (ndim > 0 and view.shape == null) return errors.raise(.BufferError, "buffer has no shape");

    var count: usize = 1;
    for (0..ndim) |i| {
        const size = view.shape[i];
        if (size < 0) return errors.raiseFmt(.BufferError, "buffer dimension {d} has negative size {d}", .{ i, size });
        layout.shape[i] = @intCast(size);
        count = std.math.mul(usize, count, layout.shape[i]) catch return tooLarge();
    }
    const length = std.math.mul(usize, count, @intCast(view.itemsize)) catch return tooLarge();
    if (view.len < 0 or length != @as(usize, @intCast(view.len))) {
        return errors.raiseFmt(.BufferError, "buffer length {d} doesn't match its shape and item size ({d} bytes)", .{
            view.len, length,
        });
    }
    if (view.len > 0 and view.buf == null) return errors.raise(.BufferError, "buffer has no memory");

    if (view.strides) |given| {
        @memcpy(layout.strides[0..ndim], given[0..ndim]);
        return;
    }
    var stride: isize = view.itemsize;
    var i = ndim;
    while (i > 0) {
        i -= 1;
        layout.strides[i] = stride;
        stride = std.math.mul(isize, stride, @intCast(layout.shape[i])) catch return tooLarge();
    }
}

fn checkContiguous(view: *const c.Py_buffer, layout: *const Layout) errors.Error!void {
    if (view.len == 0) return;

    var expected: isize = view.itemsize;
    var i: usize = @intCast(view.ndim);
    while (i > 0) {
        i -= 1;
        if (layout.shape[i] > 1 and layout.strides[i] != expected) {
            return errors.raise(.BufferError, "buffer is not C-contiguous");
        }
        expected *= @intCast(layout.shape[i]);
    }
}

fn checkOffsets(view: *const c.Py_buffer, layout: *const Layout) errors.Error!void {
    if (view.len == 0) return;

    var lowest: isize = 0;
    var highest: isize = 0;
    for (layout.shape[0..@intCast(view.ndim)], layout.strides[0..@intCast(view.ndim)]) |size, stride| {
        const span = std.math.mul(isize, @intCast(size - 1), stride) catch return offsetsOverflow();
        if (span < 0) {
            lowest = std.math.add(isize, lowest, span) catch return offsetsOverflow();
        } else {
            highest = std.math.add(isize, highest, span) catch return offsetsOverflow();
        }
    }

    const start = @intFromPtr(view.buf);
    if (start < @abs(lowest)) return offsetsOverflow();
    const end = std.math.add(usize, start, @intCast(highest)) catch return offsetsOverflow();
    _ = std.math.add(usize, end, @intCast(view.itemsize)) catch return offsetsOverflow();
}

fn checkItems(comptime T: type, comptime kind: Kind, view: *const c.Py_buffer) errors.Error!void {
    const given: []const u8 = if (view.format) |text| std.mem.span(text) else "B";
    const accepted = if (T != u8) format.matches(T, given, view.itemsize) else switch (kind) {
        .contiguous => true,
        .strided => view.itemsize == 1,
    };
    if (!accepted) {
        return errors.raiseFmt(.TypeError, "expected a buffer of {s}, got format '{s}' (item size {d})", .{
            @typeName(T), given, view.itemsize,
        });
    }
    if (view.len > 0 and !std.mem.isAligned(@intFromPtr(view.buf), @alignOf(T))) {
        return errors.raise(.BufferError, "buffer is not aligned for " ++ @typeName(T));
    }
}

fn checkBools(comptime kind: Kind, view: *const c.Py_buffer, layout: *const Layout) errors.Error!void {
    if (view.len == 0) return;

    if (kind == .contiguous) {
        const bytes = @as([*]const u8, @ptrCast(view.buf))[0..@intCast(view.len)];
        // Only 0 and 1 are valid Zig bool representations.
        var bits: u8 = 0;
        for (bytes) |byte| bits |= byte;
        if (bits > 1) return notBool(bytes[std.mem.indexOfNone(u8, bytes, &.{ 0, 1 }).?]);
        return;
    }

    const ndim: usize = @intCast(view.ndim);
    var offsets: Offsets = .of(layout.shape[0..ndim], layout.strides[0..ndim], @intCast(view.len));
    while (offsets.next()) |offset| {
        const byte: *const u8 = @ptrFromInt(@intFromPtr(view.buf) +% @as(usize, @bitCast(offset)));
        if (byte.* > 1) return notBool(byte.*);
    }
}

fn notBool(byte: u8) errors.Error {
    return errors.raiseFmt(.ValueError, "expected a buffer of bools, got the byte {d}", .{byte});
}

fn tooLarge() errors.Error {
    return errors.raise(.BufferError, "buffer is too large");
}

fn offsetsOverflow() errors.Error {
    return errors.raise(.BufferError, "buffer offsets overflow");
}
