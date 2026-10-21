const py = @import("zypy");

/// A value converted to Python by calling `function`.
pub const Callback = struct {
    function: py.Object,

    pub fn toPython(self: Callback) !py.Object {
        return self.function.call(py.Object, .{});
    }
};

/// A callback-based label followed by an item to convert.
pub const Parcel = struct {
    label: Callback,
    item: py.Object,
};

pub const Courier = struct {
    parcel: py.Owned(Parcel),

    pub const class = py.class(.{
        .doc = "Hold a parcel, whose conversion runs Python code.",
        .fields = .{ .parcel = .read_write },
        .methods = .{ .parcel_copy = parcelCopy },
        .weak_references = true,
    });

    fn parcelCopy(self: *const Courier) Parcel {
        return self.parcel.get();
    }
};

/// Store a parcel in `py.Owned`, then release it.
pub fn holdParcel(parcel: Parcel) void {
    var held: py.Owned(Parcel) = .init(parcel);
    held.deinit();
}

/// Return a label computed by a callback, the first item of `items`, and a view of `data`.
pub fn labelledItem(function: py.Object, items: py.List, data: py.Buffer(u8)) !struct { Callback, py.Object, py.Buffer(u8) } {
    return .{ .{ .function = function }, try items.get(py.Object, 0), data };
}
