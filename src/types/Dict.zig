const c = @import("python");

const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const lock = @import("../runtime/lock.zig");
const ownership = @import("../runtime/ownership.zig");
const Object = @import("Object.zig");
const reference = @import("reference.zig");

const Dict = @This();

/// The Python object, for attribute access and calls.
obj: Object,

const methods = reference.Methods(Dict);
pub const own = methods.own;
pub const deinit = methods.deinit;
pub const newRef = methods.newRef;
pub const toPython = methods.toPython;
pub const fromPython = reference.fromPython(Dict, "dict", api.isDict);

/// Create an empty dict.
pub fn init() errors.Error!Dict {
    return own(c.PyDict_New());
}

/// Get the number of entries.
pub fn len(self: Dict) usize {
    return @intCast(c.PyDict_Size(self.obj.ptr));
}

/// Get the value for `key` as `T`, or `null` if the key is missing.
/// Object references borrow from the dict; views are owned and need `deinit`.
pub fn get(self: Dict, comptime T: type, key: anytype) errors.Error!?T {
    const k = try conversion.toPython(key);
    defer k.deinit();

    var value: [*c]c.PyObject = null;
    const found = c.PyDict_GetItemRef(self.obj.ptr, k.ptr, &value);
    try errors.check(found);
    if (found == 0) return null;

    return try conversion.fromItem(T, try Object.own(value));
}

/// Insert or replace the value for `key`.
pub fn set(self: Dict, key: anytype, value: anytype) errors.Error!void {
    const k = try conversion.toPython(key);
    defer k.deinit();

    const v = try conversion.toPython(value);
    defer v.deinit();

    try errors.check(c.PyDict_SetItem(self.obj.ptr, k.ptr, v.ptr));
}

/// Remove `key`. Return whether it was in the dict.
pub fn remove(self: Dict, key: anytype) errors.Error!bool {
    const k = try conversion.toPython(key);
    defer k.deinit();

    const found = api.dictPop(self.obj.ptr, k.ptr, null);
    try errors.check(found);
    return found == 1;
}

/// Remove `key` and return its value as `T`, or `null` if the key is missing.
/// References and views in the result are owned.
pub fn pop(self: Dict, comptime T: type, key: anytype) errors.Error!?T {
    const k = try conversion.toPython(key);
    defer k.deinit();

    var value: [*c]c.PyObject = null;
    const found = api.dictPop(self.obj.ptr, k.ptr, &value);
    try errors.check(found);
    if (found == 0) return null;

    return try conversion.take(T, try .own(value));
}

/// Remove all entries.
pub fn clear(self: Dict) void {
    c.PyDict_Clear(self.obj.ptr);
}

/// Check whether `key` is in the dict.
pub fn contains(self: Dict, key: anytype) errors.Error!bool {
    const k = try conversion.toPython(key);
    defer k.deinit();

    const found = c.PyDict_Contains(self.obj.ptr, k.ptr);
    try errors.check(found);
    return found == 1;
}

/// Iterate over the entries, converting keys to `K` and values to `V`.
/// Do not add or remove keys while iterating. Values may be changed.
/// Object references borrow from the dict; views are owned and need `deinit`.
pub fn iterator(self: Dict, comptime K: type, comptime V: type) Iterator(K, V) {
    return .{ .dict = self.obj.ptr };
}

/// An iterator over the entries of a dict, made by `iterator`.
pub fn Iterator(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        /// `null` represents an empty iterator.
        dict: ?*c.PyObject,
        position: c.Py_ssize_t = 0,
        size: ?c.Py_ssize_t = null,

        /// A dict key and its value.
        pub const Entry = struct {
            /// The key, converted to `K`.
            key: K,
            /// The value, converted to `V`.
            value: V,
        };

        /// Get the next entry, or `null` when iteration ends.
        /// Raise `RuntimeError` if the dict size has changed since iteration started.
        pub fn next(self: *Self) errors.Error!?Entry {
            const dict = self.dict orelse return null;
            const key, const value = try self.read(dict) orelse return null;

            // Keep both objects alive because either conversion may run Python code that changes the dict.
            const entry_key = conversion.fromPython(K, key) catch |err| {
                key.deinit();
                value.deinit();
                return err;
            };
            const entry_value = conversion.fromPython(V, value) catch |err| {
                ownership.deinit(entry_key);
                key.deinit();
                value.deinit();
                return err;
            };
            if (self.changed(dict)) {
                ownership.deinit(entry_value);
                ownership.deinit(entry_key);
                key.deinit();
                value.deinit();
                return changedError();
            }

            conversion.settle(V, entry_value, value) catch |err| {
                ownership.deinit(entry_key);
                key.deinit();
                return err;
            };
            conversion.settle(K, entry_key, key) catch |err| {
                ownership.deinit(entry_value);
                return err;
            };
            return .{ .key = entry_key, .value = entry_value };
        }

        fn read(self: *Self, dict: *c.PyObject) errors.Error!?struct { Object, Object } {
            var section: lock.Section = .{};
            section.begin(dict, null);
            defer section.end();

            if (self.size == null) self.size = c.PyDict_Size(dict);
            if (self.changed(dict)) return changedError();

            var key: [*c]c.PyObject = null;
            var value: [*c]c.PyObject = null;
            if (c.PyDict_Next(dict, &self.position, &key, &value) == 0) return null;
            return .{ Object.borrow(key).newRef(), Object.borrow(value).newRef() };
        }

        fn changed(self: *const Self, dict: *c.PyObject) bool {
            return c.PyDict_Size(dict) != self.size.?;
        }

        fn changedError() errors.Error {
            return errors.raise(.RuntimeError, "dictionary changed size during iteration");
        }
    };
}
