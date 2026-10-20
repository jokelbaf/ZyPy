const std = @import("std");
const c = @import("python");

const conversion = @import("../conversion.zig");
const enum_class = @import("../enum_class.zig");
const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const Object = @import("../types/Object.zig");
const Str = @import("../types/Str.zig");

/// Convert a Python string, or an `enum.Enum` member by its name, to a tag of `T`.
pub fn fromPython(comptime T: type, obj: Object) errors.Error!T {
    comptime check(T);
    if (comptime enum_class.isEnumClass(T)) return enum_class.tagOf(T, obj);

    const name = try nameOf(obj);
    defer name.deinit();

    return std.meta.stringToEnum(T, try name.utf8()) orelse {
        _ = c.PyErr_Format(c.PyExc_ValueError, comptime expectedTags(T) ++ ", got %R", name.obj.ptr);
        return error.PythonError;
    };
}

/// Convert a tag to the `str` of its name, or to the member of its enum class.
pub fn toPython(value: anytype) errors.Error!Object {
    const T = @TypeOf(value);
    comptime check(T);
    if (comptime enum_class.isEnumClass(T)) return enum_class.memberOf(T, value);
    return (try Str.init(@tagName(value))).obj;
}

fn nameOf(obj: Object) errors.Error!Str {
    if (api.isStr(obj.ptr)) return .{ .obj = .borrow(obj.ptr) };

    const module = try Object.own(c.PyImport_ImportModule("enum"));
    defer module.deinit();
    const base = try module.getAttr(Object, "Enum");
    defer base.deinit();

    const member = c.PyObject_IsInstance(obj.ptr, base.ptr);
    try errors.check(member);
    if (member == 0) return errors.raiseWrongType("str", obj);
    return obj.getAttr(Str, "name");
}

fn check(comptime T: type) void {
    const info = @typeInfo(T).@"enum";
    if (info.mode != .exhaustive) conversion.unsupported(T, "values without names can't become str");
    if (info.field_names.len == 0) conversion.unsupported(T, "the enum has no tags");
}

fn expectedTags(comptime T: type) []const u8 {
    @setEvalBranchQuota(100_000);
    const names = @typeInfo(T).@"enum".field_names;
    var text: []const u8 = if (names.len == 1) "expected " else "expected one of ";
    for (names, 0..) |name, i| {
        if (i > 0) text = text ++ ", ";
        text = text ++ "'" ++ errors.escapeFormat(name) ++ "'";
    }
    return text;
}
