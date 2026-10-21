const c = @import("python");

const Offsets = @This();

shape: []const usize,
strides: []const isize,
remaining: usize,
index: [c.PyBUF_MAX_NDIM]usize = @splat(0),
offset: isize = 0,

/// Walk the byte offsets of `count` items with `shape` and `strides`, in row-major (C) order.
pub fn of(shape: []const usize, strides: []const isize, count: usize) Offsets {
    return .{ .shape = shape, .strides = strides, .remaining = count };
}

/// Get the next item's offset from the buffer's start, or `null` after the last item.
pub fn next(self: *Offsets) ?isize {
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
