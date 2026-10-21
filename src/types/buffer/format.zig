const std = @import("std");
const builtin = @import("builtin");

/// Get the `struct` module format code for items of type `T`, such as "d" for `f64`.
pub fn code(comptime T: type) [:0]const u8 {
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

/// Require `T` to have a `struct` format code.
pub fn checkItemType(comptime T: type) void {
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

/// Check whether items with `format` and `itemsize` can be read as `T`.
pub fn matches(comptime T: type, format: []const u8, itemsize: isize) bool {
    if (itemsize != @sizeOf(T)) return false;

    const found = nativeCode(format) orelse return false;
    const codes = switch (@typeInfo(T)) {
        .int => |info| if (info.signedness == .signed) "bhilqn" else "BHILQN",
        .float => "efd",
        .bool => "?",
        else => unreachable,
    };
    return std.mem.indexOfScalar(u8, codes, found) != null;
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
