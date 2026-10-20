const errors = @import("../errors.zig");
const Dict = @import("Dict.zig");
const Object = @import("Object.zig");
const Str = @import("Str.zig");

const Kwargs = @This();

/// Extra keyword arguments, borrowed until the call returns. `null` means no extra arguments.
dict: ?Dict,

/// Get the number of extra keyword arguments.
pub fn len(self: Kwargs) usize {
    return if (self.dict) |dict| dict.len() else 0;
}

/// Get keyword argument `name` as `T`, or `null` if it wasn't given.
/// Object references borrow from the call; views are owned and need `deinit`.
pub fn get(self: Kwargs, comptime T: type, name: []const u8) errors.Error!?T {
    const dict = self.dict orelse return null;
    const key = try Str.init(name);
    defer key.deinit();

    return dict.get(T, key);
}

/// Check whether keyword argument `name` was given.
pub fn contains(self: Kwargs, name: []const u8) errors.Error!bool {
    const dict = self.dict orelse return false;
    const key = try Str.init(name);
    defer key.deinit();

    return dict.contains(key);
}

/// Iterate over the keyword arguments, converting names to `K` and values to `V`.
/// Object references borrow from the call; views are owned and need `deinit`.
pub fn iterator(self: Kwargs, comptime K: type, comptime V: type) Dict.Iterator(K, V) {
    return .{ .dict = if (self.dict) |dict| dict.obj.ptr else null };
}

/// Return an owned reference to the keyword dict, or a new empty dict.
pub fn toPython(self: Kwargs) errors.Error!Object {
    if (self.dict) |dict| return dict.obj.newRef();
    return (try Dict.init()).obj;
}

/// A compile error: `py.Kwargs` can only be a parameter of an exported function.
pub fn fromPython(_: Object) errors.Error!Kwargs {
    @compileError("py.Kwargs can only be a parameter of an exported function (use py.Dict instead)");
}
