const std = @import("std");
const py = @import("zypy");

/// A class with a field and dynamic attributes stored in a dict.
pub const Record = struct {
    id: u32,
    extra: py.Owned(py.Dict),

    pub const class = py.class(.{
        .fields = .{ .id = .read_write },
        .methods = .{ .__getattr__ = lookup, .__setattr__ = assign, .__delattr__ = remove },
        .subclassable = true,
    });

    pub fn init(id: u32) !Record {
        const extra = try py.Dict.init();
        defer extra.deinit();

        return .{ .id = id, .extra = .init(extra) };
    }

    fn lookup(self: *const Record, name: py.Str) !?py.Object {
        return self.extra.get().get(py.Object, name);
    }

    fn assign(self: *Record, name: py.Str, value: py.Object) !bool {
        if (std.mem.eql(u8, try name.utf8(), "id")) return false;
        try self.extra.get().set(name, value);
        return true;
    }

    fn remove(self: *Record, name: py.Str) !void {
        if (try self.extra.get().remove(name)) return;
        return py.raiseFmt(.AttributeError, "Record has no attribute '{s}' to delete", .{try name.utf8()});
    }
};

/// A data descriptor with one value shared by all instances of its owning class.
pub const Slot = struct {
    value: py.Owned(?py.Object) = .init(null),
    reads: u32 = 0,

    pub const class = py.class(.{
        .fields = .{ .reads = .read_only },
        .methods = .{ .__get__ = get, .__set__ = set, .__delete__ = remove },
    });

    fn get(self: *Slot, instance: ?py.Object, owner: ?py.Object) !py.Object {
        self.reads += 1;
        if (instance == null) return owner.?;
        return self.value.get() orelse py.raise(.AttributeError, "the slot is empty");
    }

    fn set(self: *Slot, _: py.Object, value: py.Object) void {
        self.value.set(value);
    }

    fn remove(self: *Slot, _: py.Object) void {
        self.value.set(null);
    }
};

/// A data descriptor that does not support deletion.
pub const Fixed = struct {
    value: i64,

    pub const class = py.class(.{ .methods = .{ .__get__ = get, .__set__ = set } });

    fn get(self: *const Fixed, _: ?py.Object, _: ?py.Object) i64 {
        return self.value;
    }

    fn set(self: *Fixed, _: py.Object, value: i64) void {
        self.value = value;
    }
};
