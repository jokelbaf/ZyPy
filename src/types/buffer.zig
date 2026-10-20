const std = @import("std");
const builtin = @import("builtin");
const c = @import("python");

const errors = @import("../errors.zig");
const Object = @import("Object.zig");

/// A read-only view of a C-contiguous Python buffer, with items of type `T`.
/// Supported objects include `bytes`, `bytearray`, `memoryview`, and NumPy arrays.
/// `py.Buffer(u8)` reads the raw bytes of any buffer.
pub fn Buffer(comptime T: type) type {
    return View(T, .read_only);
}

/// A writable view of a C-contiguous Python buffer, with items of type `T`.
pub fn BufferMut(comptime T: type) type {
    return View(T, .writable);
}

/// A read-only view of a strided Python buffer, with items of type `T`.
/// Supports non-contiguous data, such as the NumPy slice `a[::2]`.
pub fn StridedBuffer(comptime T: type) type {
    return Strided(T, .read_only);
}

/// A writable view of a strided Python buffer, with items of type `T`.
pub fn StridedBufferMut(comptime T: type) type {
    return Strided(T, .writable);
}

const Access = enum { read_only, writable };

const BufferMarker = struct {};

/// Check whether `T` is one of the buffer views, such as `py.Buffer(f64)`.
pub fn isBuffer(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zypy_buffer") and @TypeOf(T.zypy_buffer) == BufferMarker;
}

const Kind = enum {
    /// C-contiguous memory. A view of `u8` reads the raw bytes of any buffer.
    contiguous,
    /// Any strides. A view of `u8` accepts only one-byte items, since strides step over whole items.
    strided,
};

fn View(comptime T: type, comptime access: Access) type {
    comptime checkItemType(T);

    return struct {
        const Self = @This();
        const writable = access == .writable;

        view: c.Py_buffer,
        layout: Layout,
        /// Whether `deinit` releases the view.
        owned: bool = true,

        /// The memory stays valid while the GIL is released (`.release_gil`, `py.allowThreads`).
        pub const usable_without_gil = true;
        pub const zypy_buffer: BufferMarker = .{};

        /// View the memory of `obj`, which must be contiguous in row-major order.
        pub fn init(obj: Object) errors.Error!Self {
            var self: Self = .{ .view = undefined, .layout = undefined };
            try acquire(T, .contiguous, access, obj, &self.view, &self.layout);
            return self;
        }

        /// Release an owned view. Borrowed views are unchanged.
        pub fn deinit(self: *const Self) void {
            if (self.owned) release(&self.view, &self.layout);
        }

        /// Get items in row-major order. The slice is valid until the view is released.
        pub fn items(self: *const Self) if (writable) []T else []const T {
            if (self.view.len == 0) return &.{};

            const ptr: [*]T = @ptrCast(@alignCast(self.view.buf));
            return ptr[0..self.len()];
        }

        /// Get raw bytes. The slice is valid until the view is released.
        pub fn bytes(self: *const Self) if (writable) []u8 else []const u8 {
            if (self.view.len == 0) return &.{};

            const ptr: [*]u8 = @ptrCast(self.view.buf);
            return ptr[0..@intCast(self.view.len)];
        }

        /// Get the number of items.
        pub fn len(self: *const Self) usize {
            return @as(usize, @intCast(self.view.len)) / @sizeOf(T);
        }

        /// Get dimension sizes in the exporter's item units, such as `{ rows, columns }`.
        pub fn shape(self: *const Self) []const usize {
            return self.layout.shape[0..@intCast(self.view.ndim)];
        }

        /// Borrow a reference to the Python object that owns the memory.
        pub fn object(self: *const Self) Object {
            return .borrow(self.view.obj);
        }

        /// Create an owned view of `obj`.
        pub fn fromPython(obj: Object) errors.Error!Self {
            return init(obj);
        }

        /// Return an owned reference to the object that owns the memory.
        pub fn toPython(self: *const Self) errors.Error!Object {
            return self.object().newRef();
        }
    };
}

fn Strided(comptime T: type, comptime access: Access) type {
    comptime checkItemType(T);

    return struct {
        const Self = @This();
        const writable = access == .writable;
        const Pointer = if (writable) *T else *const T;

        view: c.Py_buffer,
        layout: Layout,
        /// Whether `deinit` releases the view.
        owned: bool = true,

        /// The memory stays valid while the GIL is released (`.release_gil`, `py.allowThreads`).
        pub const usable_without_gil = true;
        pub const zypy_buffer: BufferMarker = .{};

        /// View the memory of `obj`, including non-contiguous data.
        /// Buffers that require pointer indirection (suboffsets) raise `BufferError`.
        pub fn init(obj: Object) errors.Error!Self {
            var self: Self = .{ .view = undefined, .layout = undefined };
            try acquire(T, .strided, access, obj, &self.view, &self.layout);
            return self;
        }

        /// Release an owned view. Borrowed views are unchanged.
        pub fn deinit(self: *const Self) void {
            if (self.owned) release(&self.view, &self.layout);
        }

        /// Get the number of items.
        pub fn len(self: *const Self) usize {
            return @as(usize, @intCast(self.view.len)) / @sizeOf(T);
        }

        /// Get the size of each dimension, such as `{ rows, columns }`.
        pub fn shape(self: *const Self) []const usize {
            return self.layout.shape[0..@intCast(self.view.ndim)];
        }

        /// Get the distance in bytes between items in each dimension. Strides can be negative.
        pub fn strides(self: *const Self) []const isize {
            return self.layout.strides[0..@intCast(self.view.ndim)];
        }

        /// Get an item pointer using one index per dimension, valid until the view is released.
        /// Raise `IndexError` for an out-of-range index or `ValueError` for the wrong number of indices.
        pub fn at(self: *const Self, indices: []const usize) errors.Error!Pointer {
            if (indices.len != self.shape().len) {
                return errors.raiseFmt(.ValueError, "expected an index per dimension of the buffer ({d}), got {d}", .{
                    self.shape().len, indices.len,
                });
            }

            // Can't overflow: acquire checked the offsets of all items, and partial sums lie between them.
            var offset: isize = 0;
            for (indices, self.shape(), self.strides()) |index, size, stride| {
                if (index >= size) return errors.raise(.IndexError, "buffer index out of range");
                offset += @as(isize, @intCast(index)) * stride;
            }
            return self.pointer(offset);
        }

        /// Iterate over pointers to the items in row-major (C) order, valid until the view is released.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .buffer = self, .offsets = .of(self.shape(), self.strides(), self.len()) };
        }

        /// An iterator over item pointers, made by `iterator`.
        pub const Iterator = struct {
            buffer: *const Self,
            offsets: Offsets,

            /// Get the next item pointer, or `null` after the last item.
            pub fn next(self: *Iterator) ?Pointer {
                return self.buffer.pointer(self.offsets.next() orelse return null);
            }
        };

        /// Borrow a reference to the Python object that owns the memory.
        pub fn object(self: *const Self) Object {
            return .borrow(self.view.obj);
        }

        /// Create an owned view of `obj`.
        pub fn fromPython(obj: Object) errors.Error!Self {
            return init(obj);
        }

        /// Return an owned reference to the object that owns the memory.
        pub fn toPython(self: *const Self) errors.Error!Object {
            return self.object().newRef();
        }

        fn pointer(self: *const Self, offset: isize) Pointer {
            // Wrapping addition also subtracts negative offsets; acquire checked that the result is a valid address.
            return @ptrFromInt(@intFromPtr(self.view.buf) +% @as(usize, @bitCast(offset)));
        }
    };
}

const Offsets = struct {
    shape: []const usize,
    strides: []const isize,
    remaining: usize,
    index: [c.PyBUF_MAX_NDIM]usize = @splat(0),
    offset: isize = 0,

    fn of(shape: []const usize, strides: []const isize, count: usize) Offsets {
        return .{ .shape = shape, .strides = strides, .remaining = count };
    }

    fn next(self: *Offsets) ?isize {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const item = self.offset;

        // Stay within the bounds checked by acquire, even when strides are negative.
        var dimension = self.shape.len;
        while (dimension > 0) {
            dimension -= 1;
            if (self.index[dimension] + 1 < self.shape[dimension]) {
                self.index[dimension] += 1;
                self.offset += self.strides[dimension];
                break;
            }
            self.offset -= self.strides[dimension] * @as(isize, @intCast(self.index[dimension]));
            self.index[dimension] = 0;
        }
        return item;
    }
};

// Copy dimensions and strides because exporters may point them into a movable Py_buffer.
const Layout = struct {
    shape: [c.PyBUF_MAX_NDIM]usize,
    strides: [c.PyBUF_MAX_NDIM]isize,
};

fn acquire(
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

fn tooLarge() errors.Error {
    return errors.raise(.BufferError, "buffer is too large");
}

fn offsetsOverflow() errors.Error {
    return errors.raise(.BufferError, "buffer offsets overflow");
}

fn release(view: *const c.Py_buffer, layout: *const Layout) void {
    var copy = view.*;
    if (copy.shape != null) copy.shape = @ptrCast(@constCast(&layout.shape));
    if (copy.strides != null) copy.strides = @constCast(&layout.strides);
    c.PyBuffer_Release(&copy);
}

/// Get the `struct` module format code for items of type `T`, such as "d" for `f64`.
pub fn formatCode(comptime T: type) [:0]const u8 {
    comptime checkItemType(T);
    return switch (@typeInfo(T)) {
        .bool => "?",
        .float => switch (@bitSizeOf(T)) {
            16 => "e",
            32 => "f",
            else => "d",
        },
        .int => |info| switch (info.signedness) {
            .signed => switch (@bitSizeOf(T)) {
                8 => "b",
                16 => "h",
                32 => "i",
                else => "q",
            },
            .unsigned => switch (@bitSizeOf(T)) {
                8 => "B",
                16 => "H",
                32 => "I",
                else => "Q",
            },
        },
        else => unreachable,
    };
}

fn checkItemType(comptime T: type) void {
    const supported = switch (@typeInfo(T)) {
        .bool => true,
        .float => |info| switch (info.bits) {
            16, 32, 64 => true,
            else => false,
        },
        .int => |info| switch (info.bits) {
            8, 16, 32, 64 => true,
            else => false,
        },
        else => false,
    };
    if (!supported) {
        @compileError("ZyPy can't view buffers of " ++ @typeName(T) ++
            " (use bool, f16, f32, f64, or an integer of 8, 16, 32 or 64 bits)");
    }
}

fn checkItems(comptime T: type, comptime kind: Kind, view: *const c.Py_buffer) errors.Error!void {
    const format: []const u8 = if (view.format) |f| std.mem.span(f) else "B";
    if (!accepts(T, kind, format, view.itemsize)) {
        return errors.raiseFmt(.TypeError, "expected a buffer of {s}, got format '{s}' (item size {d})", .{
            @typeName(T), format, view.itemsize,
        });
    }
    if (view.len > 0 and !std.mem.isAligned(@intFromPtr(view.buf), @alignOf(T))) {
        return errors.raise(.BufferError, "buffer is not aligned for " ++ @typeName(T));
    }
}

fn accepts(comptime T: type, comptime kind: Kind, format: []const u8, itemsize: c.Py_ssize_t) bool {
    if (T != u8) return formatMatches(T, format, itemsize);
    return switch (kind) {
        .contiguous => true,
        .strided => itemsize == 1,
    };
}

fn formatMatches(comptime T: type, format: []const u8, itemsize: c.Py_ssize_t) bool {
    if (itemsize != @sizeOf(T)) return false;

    const code = nativeCode(format) orelse return false;
    const codes = switch (@typeInfo(T)) {
        .int => |info| if (info.signedness == .signed) "bhilqn" else "BHILQN",
        .float => "efd",
        .bool => "?",
        else => unreachable,
    };
    return std.mem.indexOfScalar(u8, codes, code) != null;
}

fn nativeCode(format: []const u8) ?u8 {
    return switch (format.len) {
        1 => format[0],
        2 => if (isNativeByteOrder(format[0])) format[1] else null,
        else => null,
    };
}

fn isNativeByteOrder(prefix: u8) bool {
    return switch (prefix) {
        '@', '=' => true,
        '<' => builtin.cpu.arch.endian() == .little,
        '>', '!' => builtin.cpu.arch.endian() == .big,
        else => false,
    };
}
