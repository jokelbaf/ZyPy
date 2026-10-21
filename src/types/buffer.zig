const c = @import("python");

const errors = @import("../errors.zig");
const exporter = @import("buffer/exporter.zig");
const format = @import("buffer/format.zig");
const Offsets = @import("buffer/Offsets.zig");
const Object = @import("Object.zig");

pub const formatCode = format.code;

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

const Access = exporter.Access;
const Layout = exporter.Layout;

const BufferMarker = struct {};

/// Check whether `T` is one of the buffer views, such as `py.Buffer(f64)`.
pub fn isBuffer(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zypy_buffer") and @TypeOf(T.zypy_buffer) == BufferMarker;
}

fn View(comptime T: type, comptime access: Access) type {
    comptime format.checkItemType(T);

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
            try exporter.acquire(T, .contiguous, access, obj, &self.view, &self.layout);
            return self;
        }

        /// Release an owned view. Borrowed views are unchanged.
        pub fn deinit(self: *const Self) void {
            if (self.owned) exporter.release(&self.view, &self.layout);
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
    comptime format.checkItemType(T);

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
            try exporter.acquire(T, .strided, access, obj, &self.view, &self.layout);
            return self;
        }

        /// Release an owned view. Borrowed views are unchanged.
        pub fn deinit(self: *const Self) void {
            if (self.owned) exporter.release(&self.view, &self.layout);
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
