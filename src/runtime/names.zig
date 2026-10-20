const std = @import("std");
const c = @import("python");

const errors = @import("../errors.zig");
const Object = @import("../types/Object.zig");
const api = @import("api.zig");
const memory = @import("memory.zig");
const Mutex = @import("Mutex.zig");

/// A per-module cache of interned call names and keyword tuples.
pub const Cache = struct {
    objects: std.StringHashMapUnmanaged(*c.PyObject) = .empty,

    /// Release the objects. Call `unregister` first.
    pub fn deinit(self: *Cache) void {
        var objects = self.objects.valueIterator();
        while (objects.next()) |obj| c.Py_DecRef(obj.*);
        self.objects.deinit(memory.raw_allocator);
        self.* = .{};
    }
};

const Entry = struct { interpreter: i64, cache: *Cache };

var mutex: Mutex = .{};
var caches: std.ArrayList(Entry) = .empty;

/// Register a cache for calls in the current interpreter. Allocation failures only affect performance.
pub fn register(cache: *Cache) void {
    mutex.lock();
    defer mutex.unlock();

    caches.append(memory.raw_allocator, .{ .interpreter = api.interpreter(), .cache = cache }) catch {};
}

/// Stop using `cache`, before the module state that holds it goes away. Does nothing if it isn't registered.
pub fn unregister(cache: *Cache) void {
    mutex.lock();
    defer mutex.unlock();

    for (caches.items, 0..) |entry, i| {
        if (entry.cache == cache) {
            _ = caches.orderedRemove(i);
            return;
        }
    }
}

/// Get an owned reference to the interned method name `name`.
pub fn method(comptime name: [:0]const u8) errors.Error!Object {
    if (find(name)) |found| return found;

    const created = try Object.own(c.PyUnicode_InternFromString(name));
    remember(name, created.ptr);
    return created;
}

/// Get the tuple of interned keyword names for a call, or `null` for no keywords. The reference is owned.
pub fn keywordTuple(comptime names: []const [:0]const u8) errors.Error!?Object {
    if (names.len == 0) return null;
    const key = comptime tupleKey(names);
    if (find(key)) |found| return found;

    const tuple = try Object.own(c.PyTuple_New(names.len));
    errdefer tuple.deinit();
    inline for (names, 0..) |name, i| {
        const item = try method(name);
        try errors.check(c.PyTuple_SetItem(tuple.ptr, i, item.ptr));
    }
    remember(key, tuple.ptr);
    return tuple;
}

fn tupleKey(comptime names: []const [:0]const u8) []const u8 {
    var key: []const u8 = "";
    for (names) |name| key = key ++ "\x00" ++ name;
    return key;
}

fn find(key: []const u8) ?Object {
    const interpreter = api.interpreter();
    mutex.lock();
    defer mutex.unlock();

    const cache = newest(interpreter) orelse return null;
    const obj = cache.objects.get(key) orelse return null;
    return Object.borrow(obj).newRef();
}

fn remember(comptime key: []const u8, obj: *c.PyObject) void {
    const interpreter = api.interpreter();
    mutex.lock();
    defer mutex.unlock();

    const cache = newest(interpreter) orelse return;
    const entry = cache.objects.getOrPut(memory.raw_allocator, key) catch return;
    if (entry.found_existing) return;
    entry.value_ptr.* = obj;
    c.Py_IncRef(obj);
}

fn newest(interpreter: i64) ?*Cache {
    var i = caches.items.len;
    while (i > 0) {
        i -= 1;
        if (caches.items[i].interpreter == interpreter) return caches.items[i].cache;
    }
    return null;
}
