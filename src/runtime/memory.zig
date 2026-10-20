const std = @import("std");
const c = @import("python");

const Alignment = std.mem.Alignment;

/// A Python allocator traced by `tracemalloc`. Requires the GIL.
pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &Allocator(.{ .malloc = &c.PyMem_Malloc, .realloc = &c.PyMem_Realloc, .free = &c.PyMem_Free }).vtable,
};

/// A Python allocator traced by `tracemalloc`, usable without the GIL.
pub const raw_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &Allocator(.{ .malloc = &c.PyMem_RawMalloc, .realloc = &c.PyMem_RawRealloc, .free = &c.PyMem_RawFree }).vtable,
};

/// The alignment Python guarantees for allocated memory: 16 bytes on 64-bit targets, 8 on 32-bit targets.
pub const native: Alignment = .fromByteUnits(2 * @sizeOf(usize));

const Functions = struct {
    malloc: *const fn (usize) callconv(.c) ?*anyopaque,
    realloc: *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque,
    free: *const fn (?*anyopaque) callconv(.c) void,
};

fn Allocator(comptime functions: Functions) type {
    return struct {
        const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

        fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
            if (alignment.compare(.lte, native)) return @ptrCast(functions.malloc(minimumSize(len, alignment)));

            const size = std.math.add(usize, len, alignment.toByteUnits()) catch return null;
            const block: [*]u8 = @ptrCast(functions.malloc(size) orelse return null);
            const aligned: [*]u8 = @ptrFromInt(alignment.forward(@intFromPtr(block) + @sizeOf(usize)));
            header(aligned).* = block;
            return aligned;
        }

        fn resize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
            return new_len <= memory.len;
        }

        fn remap(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
            if (alignment.compare(.lte, native)) {
                return @ptrCast(functions.realloc(memory.ptr, minimumSize(new_len, alignment)));
            }
            return if (new_len <= memory.len) memory.ptr else null;
        }

        fn free(_: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
            functions.free(if (alignment.compare(.lte, native)) memory.ptr else header(memory.ptr).*);
        }
    };
}

// Some allocators align blocks only when the requested size is at least the alignment.
fn minimumSize(len: usize, alignment: Alignment) usize {
    return @max(len, alignment.toByteUnits());
}

fn header(aligned: [*]u8) *[*]u8 {
    return @ptrCast(@alignCast(aligned - @sizeOf(usize)));
}
