const c = @import("python");

const errors = @import("../../errors.zig");
const memory = @import("../../runtime/memory.zig");
const buffer = @import("../../types/buffer.zig");
const Object = @import("../../types/Object.zig");
const slot = @import("../slots.zig").slot;

/// The buffer slots for `Special`, a `slots.Methods` type.
pub fn Buffers(comptime Special: type) type {
    const name = Special.name;
    const context = Special.context;
    if (Special.has("__release_buffer__") and !Special.has("__buffer__")) {
        @compileError(context ++ ": __release_buffer__ needs __buffer__");
    }

    return struct {
        pub const slots: []const c.PyType_Slot = if (Special.has("__buffer__"))
            &.{ slot(c.Py_bf_getbuffer, &getBuffer), slot(c.Py_bf_releasebuffer, &releaseBuffer) }
        else
            &.{};

        // Even an empty buffer needs a non-null memory address.
        var empty: u8 = 0;

        fn getBuffer(self: [*c]c.PyObject, view: [*c]c.Py_buffer, flags: c_int) callconv(.c) c_int {
            exportBuffer(self.?, view.?, flags) catch {
                view.*.obj = null;
                return -1;
            };
            return 0;
        }

        fn exportBuffer(self: *c.PyObject, view: *c.Py_buffer, flags: c_int) errors.Error!void {
            const info = @typeInfo(Special.Call("__buffer__", 0).Payload);
            if (info != .pointer or info.pointer.size != .slice) {
                @compileError(context ++ ": __buffer__ must return a slice, such as []f64 or []const u8");
            }
            const Item = info.pointer.child;
            const read_only = info.pointer.attrs.@"const";
            if (read_only and flags & c.PyBUF_WRITABLE != 0) {
                return errors.raise(.BufferError, name ++ " buffers are read-only");
            }

            // Shape and strides must stay valid until the buffer is released.
            const dims = memory.allocator.alloc(c.Py_ssize_t, 2) catch return errors.raiseZigError(error.OutOfMemory, .{});
            errdefer memory.allocator.free(dims);
            // Allocate before __buffer__ so a successful export always gets __release_buffer__.
            const items = try Special.callValue("__buffer__", 0, self, .{});
            dims[0] = @intCast(items.len);
            dims[1] = @sizeOf(Item);
            view.* = .{
                .buf = if (items.len == 0) &empty else @ptrCast(@constCast(items.ptr)),
                .obj = Object.borrow(self).newRef().ptr,
                .len = @intCast(items.len * @sizeOf(Item)),
                .itemsize = @sizeOf(Item),
                .readonly = @intFromBool(read_only),
                .ndim = 1,
                .format = if (flags & c.PyBUF_FORMAT != 0) @constCast(buffer.formatCode(Item).ptr) else null,
                .shape = if (flags & c.PyBUF_ND == c.PyBUF_ND) &dims[0] else null,
                .strides = if (flags & c.PyBUF_STRIDES == c.PyBUF_STRIDES) &dims[1] else null,
                .suboffsets = null,
                .internal = dims.ptr,
            };
        }

        fn releaseBuffer(self: [*c]c.PyObject, view: [*c]c.Py_buffer) callconv(.c) void {
            const dims: [*]c.Py_ssize_t = @ptrCast(@alignCast(view.*.internal));
            memory.allocator.free(dims[0..2]);
            if (comptime Special.has("__release_buffer__")) Special.callUnraisable("__release_buffer__", self.?);
        }
    };
}
