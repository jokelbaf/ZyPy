const c = @import("python");

const class = @import("../class.zig");
const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const names = @import("../runtime/names.zig");
const ownership = @import("../runtime/ownership.zig");
const reflection = @import("../runtime/reflection.zig");
const Object = @import("../types/Object.zig");

/// Convert a tuple of exactly the length of the Zig tuple `T`.
pub fn tupleFromPython(comptime T: type, obj: Object) errors.Error!T {
    const fields = @typeInfo(T).@"struct".field_types;
    if (!api.isTuple(obj.ptr)) return errors.raiseWrongType("tuple", obj);

    const size = api.tupleSize(obj.ptr);
    if (size != fields.len) {
        return errors.raiseFmt(.TypeError, "expected tuple of length {d}, got {d}", .{ fields.len, size });
    }

    var result: T = undefined;
    var converted: usize = 0;
    errdefer inline for (0..fields.len) |i| {
        if (i < converted) ownership.deinit(result[i]);
    };

    inline for (fields, 0..) |Field, i| {
        result[i] = try conversion.fromPython(Field, .borrow(c.PyTuple_GetItem(obj.ptr, i)));
        converted += 1;
    }
    try copyAgain(T, obj.ptr, &result);
    return result;
}

/// Refresh copied class values from `item` after conversions that may change the original instances.
pub fn copyAgain(comptime T: type, item: *c.PyObject, value: *T) errors.Error!void {
    if (comptime !holdsCopies(T)) return;
    if (comptime class.isClass(T)) {
        value.* = try class.copyFrom(T, item);
        return;
    }
    switch (@typeInfo(T)) {
        .optional => |info| if (value.*) |*inner| try copyAgain(info.child, item, inner),
        else => inline for (0..@typeInfo(T).@"struct".field_types.len) |i| {
            try copyAgain(@TypeOf(value[i]), c.PyTuple_GetItem(item, i).?, &value[i]);
        },
    }
}

fn holdsCopies(comptime T: type) bool {
    if (class.isClass(T)) return true;
    return switch (@typeInfo(T)) {
        .optional => |info| holdsCopies(info.child),
        .@"struct" => |info| info.is_tuple and reflection.any(info.field_types, holdsCopies),
        else => false,
    };
}

pub fn tupleToPython(value: anytype) errors.Error!Object {
    const fields = @typeInfo(@TypeOf(value)).@"struct".field_types;
    const tuple = try Object.own(c.PyTuple_New(fields.len));
    errdefer tuple.deinit();

    inline for (0..fields.len) |i| {
        const item = try conversion.toPython(value[i]);
        try errors.check(c.PyTuple_SetItem(tuple.ptr, i, item.ptr));
    }
    return tuple;
}

/// Convert a mapping to a struct, reading one key per field. Fields own their references.
pub fn structFromPython(comptime T: type, obj: Object) errors.Error!T {
    const info = @typeInfo(T).@"struct";
    comptime for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
        if (!attrs.@"comptime") checkField(T, name, Field);
    };

    const is_dict = api.isDict(obj.ptr);
    if (!is_dict) {
        // Accept keys(), as Python does for **kwargs. Intern the name to avoid growing the type cache.
        const keys = try names.method("keys");
        defer keys.deinit();
        const mapping = c.PyObject_HasAttrWithError(obj.ptr, keys.ptr);
        try errors.check(mapping);
        if (mapping == 0) return errors.raiseWrongType("a mapping", obj);
    }

    var result: T = undefined;
    var converted: usize = 0;
    errdefer inline for (info.field_names, info.field_attrs, 0..) |name, attrs, i| {
        if (!attrs.@"comptime" and i < converted) ownership.deinit(@field(result, name));
    };

    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, Field, attrs, i| {
        if (!attrs.@"comptime") @field(result, name) = try fieldFromPython(Field, name, attrs.defaultValue(Field), obj, is_dict);
        converted = i + 1;
    }
    return result;
}

fn checkField(comptime T: type, comptime name: []const u8, comptime Field: type) void {
    const context = "ZyPy can't convert a mapping to " ++ @typeName(T) ++ ": field '" ++ name ++ "'";
    if (ownership.holdsByteSlice(Field)) {
        @compileError(context ++ " would point into a value that the struct can't keep alive (use py.Bytes)");
    }
    if (ownership.pointedClass(Field)) |Class| {
        @compileError(context ++ " would point into an instance that the struct can't keep alive (use py.Instance(" ++
            @typeName(Class) ++ "))");
    }
    if (ownership.holdsOpaque(Field)) {
        @compileError(context ++ ": ZyPy can't tell which references it holds (use py.Object, then as())");
    }
}

fn fieldFromPython(comptime Field: type, comptime name: [:0]const u8, comptime default: ?Field, obj: Object, is_dict: bool) errors.Error!Field {
    var item: [*c]c.PyObject = null;
    // Skip __missing__ to avoid adding entries when reading a defaultdict.
    const found = if (is_dict)
        c.PyDict_GetItemStringRef(obj.ptr, name, &item)
    else
        c.PyMapping_GetOptionalItemString(obj.ptr, name, &item);
    try errors.check(found);

    if (found == 0) {
        if (default) |value| return value;
        if (@typeInfo(Field) == .optional) return null;
        return errors.raise(.KeyError, name);
    }

    const value = try Object.own(item);
    defer value.deinit();

    return ownership.retain(try conversion.fromPython(Field, value));
}

/// Convert a struct to a new dict with one key per field, comptime fields included.
pub fn structToPython(value: anytype) errors.Error!Object {
    const dict = try Object.own(c.PyDict_New());
    errdefer dict.deinit();

    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
        const item = try conversion.toPython(@field(value, name));
        defer item.deinit();

        try errors.check(c.PyDict_SetItemString(dict.ptr, name, item.ptr));
    }
    return dict;
}
