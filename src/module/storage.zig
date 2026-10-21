const c = @import("python");

const class = @import("../class.zig");
const enum_class = @import("../enum_class.zig");
const gc = @import("../runtime/gc.zig");
const names = @import("../runtime/names.zig");
const ownership = @import("../runtime/ownership.zig");

/// Per-module storage for Python objects and user state.
pub fn Storage(
    comptime exceptions: anytype,
    comptime classes: anytype,
    comptime enums: anytype,
    comptime State: type,
    comptime keyword_count: usize,
) type {
    const exception_names = @typeInfo(@TypeOf(exceptions)).@"struct".field_names;
    const class_names = @typeInfo(@TypeOf(classes)).@"struct".field_names;
    const enum_names = @typeInfo(@TypeOf(enums)).@"struct".field_names;
    const EnumMembers = blk: {
        var types: [enum_names.len]type = undefined;
        for (enum_names, &types) |name, *Members| Members.* = enum_class.Members(@field(enums, name));
        break :blk @Tuple(&types);
    };

    return struct {
        const Self = @This();

        /// The exception types, then the classes, as strong references.
        objects: [exception_names.len + class_names.len]?*c.PyObject,
        enum_members: EnumMembers,
        state: State,
        /// Whether `state` is initialized and needs releasing.
        live: bool,
        /// Whether `state` is initialized and available to functions.
        ready: bool,
        keywords: [keyword_count]?*c.PyObject,
        call_names: names.Cache,

        /// Get the storage of `module`, or `null` if it has none.
        pub fn of(module: *c.PyObject) ?*Self {
            return @ptrCast(@alignCast(c.PyModule_GetState(module) orelse return null));
        }

        /// Visit stored Python references for garbage collection.
        pub fn traverse(self: *Self, visitor: c.visitproc, arg: ?*anyopaque) c_int {
            for (self.objects) |object| {
                if (object) |ptr| {
                    const result = visitor.?(ptr, arg);
                    if (result != 0) return result;
                }
            }
            inline for (0..enum_names.len) |i| {
                if (self.enum_members[i].tuple) |tuple| {
                    const result = visitor.?(tuple, arg);
                    if (result != 0) return result;
                }
            }
            if (self.live) return gc.visit(&self.state, visitor, arg);
            return 0;
        }

        /// Clear stored Python references to break reference cycles.
        pub fn clear(self: *Self, module: *c.PyObject) void {
            self.releaseObjects(module);
            self.ready = false;
            if (self.live) gc.clear(&self.state);
        }

        /// Release stored references and Zig resources.
        pub fn free(self: *Self, module: *c.PyObject) void {
            self.releaseObjects(module);
            self.ready = false;
            if (self.live) {
                self.live = false;
                ownership.release(&self.state);
            }
        }

        // Unregister each object before releasing it, so no registry points at a freed object.
        fn releaseObjects(self: *Self, module: *c.PyObject) void {
            names.unregister(&self.call_names);
            self.call_names.deinit();
            for (&self.keywords) |*keyword| {
                const obj = keyword.* orelse continue;
                keyword.* = null;
                c.Py_DecRef(obj);
            }
            inline for (exception_names, 0..) |name, i| {
                if (self.objects[i]) |object| {
                    @field(exceptions, name).registry.remove(module);
                    self.objects[i] = null;
                    c.Py_DecRef(object);
                }
            }
            inline for (class_names, exception_names.len..) |name, i| {
                if (self.objects[i]) |object| {
                    class.registry(@field(classes, name)).remove(module);
                    self.objects[i] = null;
                    c.Py_DecRef(object);
                }
            }
            inline for (enum_names, 0..) |name, i| {
                enum_class.registry(@field(enums, name)).remove(module);
                self.enum_members[i].release();
            }
        }
    };
}
