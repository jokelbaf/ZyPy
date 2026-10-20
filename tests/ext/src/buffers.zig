const std = @import("std");
const py = @import("zypy");

pub fn bufSum(buf: py.Buffer(f64)) f64 {
    var total: f64 = 0;
    for (buf.items()) |x| total += x;
    return total;
}

pub fn bufSumAndRelease(buf: py.Buffer(f64)) f64 {
    defer buf.deinit();
    return bufSum(buf);
}

pub fn scale(buf: py.BufferMut(f64), k: f64) py.BufferMut(f64) {
    for (buf.items()) |*x| x.* *= k;
    return buf;
}

pub fn fill(buf: py.BufferMut(u8), value: u8) void {
    @memset(buf.bytes(), value);
}

pub fn dot(a: py.Buffer(f64), b: py.Buffer(f64)) !f64 {
    if (a.len() != b.len()) return py.raise(.ValueError, "length mismatch");

    var total: f64 = 0;
    for (a.items(), b.items()) |x, y| total += x * y;
    return total;
}

pub fn shape(buf: py.Buffer(u8)) struct { usize, usize } {
    const dims = buf.shape();
    return .{ dims.len, if (dims.len > 0) dims[0] else 0 };
}

pub fn firstByte(obj: py.Object) !?u8 {
    const buf = try py.Buffer(u8).init(obj);
    defer buf.deinit();

    const bytes = buf.bytes();
    return if (bytes.len > 0) bytes[0] else null;
}

pub fn trueCount(buf: py.Buffer(bool)) usize {
    var count: usize = 0;
    for (buf.items()) |item| count += @intFromBool(item);
    return count;
}

pub fn stridedTrueCount(buf: py.StridedBuffer(bool)) usize {
    var count: usize = 0;
    var items = buf.iterator();
    while (items.next()) |item| count += @intFromBool(item.*);
    return count;
}

pub fn stridedSum(buf: py.StridedBuffer(f64)) f64 {
    var total: f64 = 0;
    var items = buf.iterator();
    while (items.next()) |x| total += x.*;
    return total;
}

pub fn stridedOrder(buf: py.StridedBuffer(f64)) !py.List {
    const values = try py.List.init();
    errdefer values.deinit();

    var items = buf.iterator();
    while (items.next()) |x| try values.append(x.*);
    return values;
}

pub fn stridedLayout(buf: py.StridedBuffer(u8)) !struct { usize, py.List, py.List } {
    // Copy shape and strides before returning because their slices point into this local view.
    const dimensions = try py.List.fromSlice(buf.shape());
    errdefer dimensions.deinit();

    return .{ buf.len(), dimensions, try py.List.fromSlice(buf.strides()) };
}

pub fn stridedAt(buf: py.StridedBuffer(f64), row: usize, column: usize) !f64 {
    return (try buf.at(&.{ row, column })).*;
}

pub fn stridedScale(buf: py.StridedBufferMut(f64), factor: f64) void {
    var items = buf.iterator();
    while (items.next()) |x| x.* *= factor;
}

pub fn scalarValue(buf: py.StridedBuffer(f64)) !f64 {
    return (try buf.at(&.{})).*;
}

/// A buffer exporter that stores dimensions and strides in its view and records them on release.
const RawExporter = struct {
    var data = [_]u8{ 1, 2, 3, 4 };
    var released: struct { isize, isize } = .{ 0, 0 };

    fn getBuffer(self: [*c]py.c.PyObject, view: [*c]py.c.Py_buffer, flags: c_int) callconv(.c) c_int {
        _ = flags;
        view.* = .{
            .buf = &data,
            .obj = py.Object.borrow(self.?).newRef().ptr,
            .len = data.len,
            .itemsize = 1,
            .readonly = 1,
            .ndim = 1,
            .format = null,
            .shape = null,
            .strides = null,
            .suboffsets = null,
            .internal = null,
        };
        view.*.shape = &view.*.len;
        view.*.strides = &view.*.itemsize;
        return 0;
    }

    fn releaseBuffer(_: [*c]py.c.PyObject, view: [*c]py.c.Py_buffer) callconv(.c) void {
        released = .{ view.*.shape[0], view.*.strides[0] };
    }

    var slots = [_]py.c.PyType_Slot{
        .{ .slot = py.c.Py_bf_getbuffer, .pfunc = @ptrCast(@constCast(&getBuffer)) },
        .{ .slot = py.c.Py_bf_releasebuffer, .pfunc = @ptrCast(@constCast(&releaseBuffer)) },
        .{ .slot = 0, .pfunc = null },
    };
};

pub fn rawExporter() !py.Object {
    var spec: py.c.PyType_Spec = .{
        .name = "zypy_tests.RawExporter",
        .basicsize = @sizeOf(py.c.PyObject),
        .itemsize = 0,
        .flags = py.c.Py_TPFLAGS_DEFAULT,
        .slots = &RawExporter.slots,
    };
    const exporter_type = try py.Object.own(py.c.PyType_FromSpec(&spec));
    defer exporter_type.deinit();

    return exporter_type.call(py.Object, .{});
}

pub fn rawReleased() struct { isize, isize } {
    return RawExporter.released;
}

/// The ways `Malformed` breaks the buffer protocol.
pub const Flaw = enum {
    negative_dimensions,
    too_many_dimensions,
    zero_item_size,
    no_shape,
    negative_size,
    huge_shape,
    wrong_length,
    no_memory,
    not_contiguous,
    overflowing_strides,
    negative_strides,
    suboffsets,
    read_only,
};

/// A buffer exporter with one deliberate protocol error. Count unreleased views.
const Malformed = struct {
    header: py.c.PyObject,
    flaw: Flaw,
    shape: [2]isize,
    strides: [2]isize,
    suboffsets: [2]isize,

    var data = [_]f64{ 1, 2, 3, 4 };
    var outstanding: isize = 0;

    fn getBuffer(self: [*c]py.c.PyObject, view: [*c]py.c.Py_buffer, _: c_int) callconv(.c) c_int {
        const exporter: *Malformed = @ptrCast(@alignCast(self.?));
        exporter.shape = .{ data.len, 1 };
        exporter.strides = .{ @sizeOf(f64), @sizeOf(f64) };
        exporter.suboffsets = .{ -1, -1 };
        view.* = .{
            .buf = &data,
            .obj = py.Object.borrow(self.?).newRef().ptr,
            .len = data.len * @sizeOf(f64),
            .itemsize = @sizeOf(f64),
            .readonly = 0,
            .ndim = 1,
            .format = @constCast("d"),
            .shape = &exporter.shape,
            .strides = &exporter.strides,
            .suboffsets = null,
            .internal = null,
        };
        switch (exporter.flaw) {
            .negative_dimensions => view.*.ndim = -1,
            .too_many_dimensions => view.*.ndim = py.c.PyBUF_MAX_NDIM + 1,
            .zero_item_size => view.*.itemsize = 0,
            .no_shape => view.*.shape = null,
            .negative_size => exporter.shape[0] = -4,
            .huge_shape => {
                view.*.ndim = 2;
                exporter.shape = .{ std.math.maxInt(isize), 4 };
            },
            .wrong_length => view.*.len = 3 * @sizeOf(f64),
            .no_memory => view.*.buf = null,
            .not_contiguous => {
                exporter.shape[0] = 2;
                exporter.strides[0] = 2 * @sizeOf(f64);
                view.*.len = 2 * @sizeOf(f64);
            },
            .overflowing_strides => {
                view.*.ndim = 2;
                exporter.shape = .{ 2, 2 };
                exporter.strides = .{ std.math.maxInt(isize), std.math.maxInt(isize) };
            },
            .negative_strides => {
                exporter.shape = .{ 2, 2 };
                view.*.len = 2 * @sizeOf(f64);
                exporter.strides[0] = std.math.minInt(isize) / 2;
            },
            .suboffsets => view.*.suboffsets = &exporter.suboffsets,
            .read_only => view.*.readonly = 1,
        }
        outstanding += 1;
        return 0;
    }

    fn releaseBuffer(_: [*c]py.c.PyObject, _: [*c]py.c.Py_buffer) callconv(.c) void {
        outstanding -= 1;
    }

    var slots = [_]py.c.PyType_Slot{
        .{ .slot = py.c.Py_bf_getbuffer, .pfunc = @ptrCast(@constCast(&getBuffer)) },
        .{ .slot = py.c.Py_bf_releasebuffer, .pfunc = @ptrCast(@constCast(&releaseBuffer)) },
        .{ .slot = 0, .pfunc = null },
    };
};

pub fn malformedExporter(flaw: Flaw) !py.Object {
    var spec: py.c.PyType_Spec = .{
        .name = "zypy_tests.Malformed",
        .basicsize = @sizeOf(Malformed),
        .itemsize = 0,
        .flags = py.c.Py_TPFLAGS_DEFAULT,
        .slots = &Malformed.slots,
    };
    const exporter_type = try py.Object.own(py.c.PyType_FromSpec(&spec));
    defer exporter_type.deinit();

    const exporter = try exporter_type.call(py.Object, .{});
    const value: *Malformed = @ptrCast(@alignCast(exporter.ptr));
    value.flaw = flaw;
    return exporter;
}

/// The number of views of `Malformed` exporters that weren't released.
pub fn malformedOutstanding() isize {
    return Malformed.outstanding;
}

pub fn byteSum(buf: py.Buffer(u8)) u64 {
    var total: u64 = 0;
    for (buf.items()) |byte| total += byte;
    return total;
}
