const py = @import("zypy");

fn byteSlice(f: py.Object) ![]const u8 {
    return f.call([]const u8, .{});
}

fn nestedByteSlice(f: py.Object) !void {
    _ = try f.getAttr(?struct { i64, []const u8 }, "x");
}

fn notATuple(f: py.Object) !void {
    try f.call(void, 5);
}

fn notAStruct(f: py.Object) !void {
    try f.callKw(void, .{}, .{ 1, 2 });
}

fn unknownException() bool {
    return py.exception.matches(.NoSuchError);
}

fn argsItem(list: py.List) !void {
    _ = try list.get(py.Args, 0);
}

fn ignore(_: py.Object) void {}

fn allowObject(x: py.Object) void {
    py.allowThreads(ignore, .{x});
}

fn addToFrozenSet(set: py.FrozenSet) !void {
    try set.add(1);
}

const Level = enum(u8) { low, high, _ };

fn openEnum(level: Level) Level {
    return level;
}

fn structWithBytes(f: py.Object) !void {
    _ = try f.call(struct { name: []const u8 }, .{});
}

const Resource = struct {
    memory: []u8,
    pub const class = py.class(.{});
    pub fn deinit(self: *Resource) void {
        py.allocator.free(self.memory);
    }
};

fn resourceCopy(resource: Resource) usize {
    return resource.memory.len;
}

const Pt = struct {
    x: f64,
    pub const class = py.class(.{});
};

fn pointerResult(p: *Pt) *Pt {
    return p;
}

fn raiseNumber() !void {
    return py.raise(i64, "x");
}

fn instanceOfNumber(x: py.Instance(i64)) void {
    _ = x;
}

fn classOfNumber(x: py.Class(i64)) void {
    _ = x;
}

fn takePointer(f: py.Object) !void {
    _ = try f.call(*const Pt, .{});
}

const Flagged = struct {
    obj: py.Object,
    owned: bool = true,

    pub fn fromPython(obj: py.Object) py.Error!Flagged {
        return .{ .obj = obj.newRef() };
    }
};

fn useFlagged(flagged: Flagged) bool {
    return flagged.owned;
}

fn methodFromData(obj: py.Object, name: py.Str) !void {
    try obj.callMethod(void, try name.utf8(), .{});
}

fn nameLength(record: struct { name: []const u8 }) usize {
    return record.name.len;
}

fn lockNumber() void {
    var section: py.CriticalSection = .{};
    section.begin(.{5});
    defer section.end();
}

const module = py.module(.{
    .functions = .{
        .byte_slice = byteSlice,
        .nested_byte_slice = nestedByteSlice,
        .not_a_tuple = notATuple,
        .not_a_struct = notAStruct,
        .unknown_exception = unknownException,
        .args_item = argsItem,
        .allow_object = allowObject,
        .add_to_frozenset = addToFrozenSet,
        .open_enum = openEnum,
        .struct_with_bytes = structWithBytes,
        .resource_copy = resourceCopy,
        .pointer_result = pointerResult,
        .raise_number = raiseNumber,
        .instance_of_number = instanceOfNumber,
        .class_of_number = classOfNumber,
        .take_pointer = takePointer,
        .name_length = nameLength,
        .use_flagged = useFlagged,
        .method_from_data = methodFromData,
        .lock_number = lockNumber,
    },
});

comptime {
    py.exportModule(module);
    // test_compile_errors.py adds the bad modules to definitions.zig.
    _ = @import("definitions.zig");
}
