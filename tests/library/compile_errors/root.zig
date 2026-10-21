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

fn pair(a: i64, b: i64) i64 {
    return a + b;
}

fn small(a: u8) u8 {
    return a;
}

fn fallible(a: i64) !i64 {
    return if (a < 0) error.Negative else a;
}

fn isNone(x: py.Object) bool {
    return x.isNone();
}

fn takesArgs(a: i64, rest: py.Args) i64 {
    return a + @as(i64, @intCast(rest.len()));
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

fn oddItems(buf: py.Buffer(u24)) usize {
    return buf.len();
}

const Lease = struct {
    id: u32,

    pub fn fromPython(obj: py.Object) py.Error!Lease {
        return .{ .id = try obj.as(u32) };
    }

    pub fn deinit(_: Lease) void {}
};

fn useLease(lease: Lease) u32 {
    return lease.id;
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
}

const Plain = struct { x: i64 };

const BadOption = struct {
    x: i64,
    pub const class = py.class(.{ .docs = "x" });
};

const Getter = struct {
    pub const class = py.class(.{ .methods = .{ .__getattribute__ = get } });
    fn get(_: *const Getter, _: py.Str) i64 {
        return 1;
    }
};

const Awaitable = struct {
    pub const class = py.class(.{ .methods = .{ .__await__ = wait } });
    fn wait(_: *const Awaitable) void {}
};

const Modular = struct {
    x: i64,
    pub const class = py.class(.{ .methods = .{ .__pow__ = power } });
    fn power(self: *const Modular, exponent: i64, modulo: i64) i64 {
        return @mod(self.x * exponent, modulo);
    }
};

const Setter = struct {
    pub const class = py.class(.{ .methods = .{ .__setattr__ = set } });
    fn set(_: *Setter, _: py.Str, _: py.Object) i64 {
        return 0;
    }
};

const ShadowedDict = struct {
    __dict__: i64,
    pub const class = py.class(.{ .fields = .{ .__dict__ = .read_only }, .dict = true });
};

const Holder = struct {
    obj: py.Object,
    pub const class = py.class(.{});
};

const NoField = struct {
    x: i64,
    pub const class = py.class(.{ .fields = .{ .z = .read_only } });
};

const Endless = struct {
    pub const class = py.class(.{ .methods = .{ .__next__ = next } });
    fn next(_: *Endless) i64 {
        return 1;
    }
};

const BadDeinit = struct {
    pub const class = py.class(.{});
    pub fn deinit(_: *BadDeinit, _: i64) void {}
};

const ViewHolder = struct {
    data: py.Owned(py.Buffer(f64)),
    pub const class = py.class(.{});
};

const SliceHolder = struct {
    data: py.Owned([]const u8),
    pub const class = py.class(.{});
};

const SliceArrayHolder = struct {
    data: py.Owned([1][]const u8),
    pub const class = py.class(.{});
};

const Target = struct {
    x: i64,
    pub const class = py.class(.{});
};

fn threeTargets(a: *const Target, b: *const Target, c: *Target) void {
    c.x = a.x + b.x;
}

const RawHolder = struct {
    target: *Target,
    pub const class = py.class(.{});
};

const OwnedPointer = struct {
    target: py.Owned(?*const Target),
    pub const class = py.class(.{});
};

const SetterResult = struct {
    pub const class = py.class(.{ .methods = .{ .__setitem__ = set } });
    fn set(_: *SetterResult, _: i64, _: i64) i64 {
        return 1;
    }
};

const PropertyResult = struct {
    x: i64,
    pub const class = py.class(.{ .properties = .{ .value = py.property(get, .{ .set = set }) } });
    fn get(self: *const PropertyResult) i64 {
        return self.x;
    }
    fn set(self: *PropertyResult, x: i64) i64 {
        self.x = x;
        return x;
    }
};

const SameError = py.exceptionType(.{});
const BaseError = py.exceptionType(.{ .doc = "base" });
const ChildError = py.exceptionType(.{ .base = BaseError });

const NeedsInit = struct { n: i64 };

const Counted = struct { n: u64 = 0 };

fn bump(state: *Counted) void {
    state.n += 1;
}

const Releaser = struct {
    pub const class = py.class(.{ .methods = .{ .__release_buffer__ = release } });
    fn release(_: *Releaser) void {}
};

const ClassRepr = struct {
    pub const class = py.class(.{ .methods = .{ .__repr__ = repr } });
    fn repr(_: py.Class(ClassRepr)) []const u8 {
        return "";
    }
};

const Final = struct {
    x: i64,
    pub const class = py.class(.{});
};

const FromFinal = struct {
    base: Final align(py.base_alignment),
    pub const class = py.class(.{ .base = Final });
};

const Open = struct {
    x: i64,
    pub const class = py.class(.{ .subclassable = true });
};

const Misplaced = struct {
    y: i64,
    base: Open align(py.base_alignment),
    pub const class = py.class(.{ .base = Open });
};

const Unaligned = struct {
    base: Open,
    y: f64,
    pub const class = py.class(.{ .base = Open });
};

const ValueBase = struct {
    pub const class = py.class(.{ .base = 5 });
};

const Orphan = struct {
    base: Open align(py.base_alignment),
    pub const class = py.class(.{ .base = Open });
};

const ObjectState = struct { obj: py.Object = undefined };

const PlainEnum = enum { a, b };

const Reserved = enum {
    mro,
    pub const class = py.enumClass(.{});
};

const Keyword = enum {
    lambda,
    pub const class = py.enumClass(.{});
};

const Shade = enum {
    light,
    pub const class = py.enumClass(.{});
};

const BadEnumOption = enum {
    a,
    pub const class = py.enumClass(.{ .docs = "x" });
};

const SpecialField = struct {
    __len__: i64,
    pub const class = py.class(.{ .fields = .{ .__len__ = .read_write }, .methods = .{ .__len__ = length } });
    fn length(_: *const SpecialField) i64 {
        return 10;
    }
};

const DictMethod = struct {
    pub const class = py.class(.{ .dict = true, .methods = .{ .__dict__ = contents } });
    fn contents(_: *const DictMethod) i64 {
        return 0;
    }
};

const Twice = struct {
    size: i64,
    pub const class = py.class(.{ .fields = .{ .size = .read_only }, .methods = .{ .size = getSize } });
    fn getSize(self: *const Twice) i64 {
        return self.size;
    }
};

const Keyworded = struct {
    pub const class = py.class(.{ .methods = .{ .class = answer } });
    fn answer(_: *const Keyworded) i64 {
        return 42;
    }
};

const Spaced = struct {
    x: i64,
    pub const class = py.class(.{ .properties = .{ .@"some thing" = thing } });
    fn thing(self: *const Spaced) i64 {
        return self.x;
    }
};
