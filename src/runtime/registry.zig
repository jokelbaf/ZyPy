const std = @import("std");
const c = @import("python");

const errors = @import("../errors.zig");
const Object = @import("../types/Object.zig");
const Str = @import("../types/Str.zig");
const api = @import("api.zig");
const memory = @import("memory.zig");
const Mutex = @import("Mutex.zig");

/// A registry of imported classes or exceptions in each interpreter.
/// The module keeps each entry alive and must remove it before cleanup.
pub fn Registry(comptime Item: type) type {
    return struct {
        const Self = @This();

        mutex: Mutex = .{},
        entries: std.ArrayList(Entry) = .empty,

        const Entry = struct {
            interpreter: i64,
            item: Item,
            module: *c.PyObject,
            def: *c.PyModuleDef,
            module_name: [:0]u8,
        };

        /// Get an owned reference from the latest import in this interpreter, or `null` if none exists.
        pub fn find(self: *Self) ?Object {
            const take = struct {
                fn take(_: void, object: *c.PyObject) ?Object {
                    return Object.borrow(object).newRef();
                }
            }.take;
            return self.search(Object, {}, take);
        }

        /// Return the first result of `match` that isn't null, trying the items of this interpreter newest first.
        /// `match` runs with the registry locked, so it must not call Python.
        pub fn search(
            self: *Self,
            comptime Result: type,
            context: anytype,
            comptime match: fn (@TypeOf(context), Item) ?Result,
        ) ?Result {
            const interpreter = api.interpreter();
            self.mutex.lock();
            defer self.mutex.unlock();

            var i = self.entries.items.len;
            while (i > 0) {
                i -= 1;
                const entry = self.entries.items[i];
                if (entry.interpreter != interpreter) continue;
                if (match(context, entry.item)) |result| return result;
            }
            return null;
        }

        /// Register `item` for `module` in this interpreter.
        /// Raise `ImportError` if another module definition already registered it. `name` identifies it in errors.
        pub fn add(self: *Self, item: Item, module: *c.PyObject, def: *c.PyModuleDef, name: [:0]const u8) errors.Error!void {
            const module_name = try copyName(module);
            const entry: Entry = .{
                .interpreter = api.interpreter(),
                .item = item,
                .module = module,
                .def = def,
                .module_name = module_name,
            };
            const conflict = self.insert(entry) catch |err| {
                memory.raw_allocator.free(module_name);
                return errors.raiseZigError(err, .{});
            };
            const other_name = conflict orelse return;
            defer memory.raw_allocator.free(other_name);
            memory.raw_allocator.free(module_name);

            const format = "%s is already defined by module '%s' (list it in one module only)";
            _ = c.PyErr_Format(c.PyExc_ImportError, format, name.ptr, other_name.ptr);
            return error.PythonError;
        }

        fn insert(self: *Self, entry: Entry) error{OutOfMemory}!?[:0]u8 {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.entries.items) |existing| {
                // Copy the name while locked: another thread may free the other module once the lock is released.
                if (existing.interpreter == entry.interpreter and existing.def != entry.def) {
                    return try memory.raw_allocator.dupeSentinel(u8, existing.module_name, 0);
                }
            }
            try self.entries.append(memory.raw_allocator, entry);
            return null;
        }

        /// Remove the entry of `module`, if any.
        pub fn remove(self: *Self, module: *c.PyObject) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.entries.items, 0..) |entry, i| {
                if (entry.module == module) {
                    memory.raw_allocator.free(self.entries.orderedRemove(i).module_name);
                    return;
                }
            }
        }
    };
}

fn copyName(module: *c.PyObject) errors.Error![:0]u8 {
    const name = try Str.own(c.PyModule_GetNameObject(module));
    defer name.deinit();

    return memory.raw_allocator.dupeSentinel(u8, try name.utf8(), 0) catch errors.raiseZigError(error.OutOfMemory, .{});
}
