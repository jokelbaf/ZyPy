const std = @import("std");
const c = @import("python");

const class = @import("../../class.zig");
const conversion = @import("../../conversion.zig");
const errors = @import("../../errors.zig");
const Object = @import("../../types/Object.zig");
const Methods = @import("../slots.zig").Methods;
const slot = @import("../slots.zig").slot;

/// The container slots for `Special`, a `slots.Methods` type.
pub fn Containers(comptime Special: type) type {
    const name = Special.name;
    const context = Special.context;
    const Class = Special.scope.Class.?;

    return struct {
        pub const slots: []const c.PyType_Slot = blk: {
            var list: []const c.PyType_Slot = &.{};
            if (Special.has("__iter__")) {
                list = list ++ .{slot(c.Py_tp_iter, &iterate)};
            } else if (Special.has("__next__")) {
                // An object with only __next__ is its own iterator.
                list = list ++ .{slot(c.Py_tp_iter, &c.PyObject_SelfIter)};
            }
            if (Special.has("__next__")) list = list ++ .{slot(c.Py_tp_iternext, &next)};
            if (Special.has("__len__")) list = list ++ .{ slot(c.Py_mp_length, &length), slot(c.Py_sq_length, &length) };
            if (Special.has("__getitem__")) {
                const bases = baseKeys(.get);
                if (isIndex(Special.KeyOf("__getitem__", 1))) {
                    list = list ++ .{slot(c.Py_sq_item, &getIndex)};
                    if (bases.object) list = list ++ .{slot(c.Py_mp_subscript, &getIndexByObject)};
                } else {
                    list = list ++ .{slot(c.Py_mp_subscript, &getItem)};
                    if (bases.index) list = list ++ .{slot(c.Py_sq_item, &getItemByIndex)};
                }
            }
            if (assign_key) |Key| {
                const bases = baseKeys(.assign);
                if (isIndex(Key)) {
                    list = list ++ .{slot(c.Py_sq_ass_item, &setIndex)};
                    if (bases.object) list = list ++ .{slot(c.Py_mp_ass_subscript, &setIndexByObject)};
                } else {
                    list = list ++ .{slot(c.Py_mp_ass_subscript, &setItem)};
                    if (bases.index) list = list ++ .{slot(c.Py_sq_ass_item, &setItemByIndex)};
                }
            }
            if (Special.has("__contains__")) list = list ++ .{slot(c.Py_sq_contains, &contains)};
            break :blk list;
        };

        const assign_key = assignKey(Special);

        fn baseKeys(comptime methods: enum { get, assign }) Keys {
            var keys: Keys = .{};
            for (class.bases(Class)) |Base| {
                const Own = @TypeOf(class.Definition(Base).methods);
                const BaseSpecial = Methods(Special.scope.of(Base), class.Definition(Base).special);
                const Key: ?type = switch (methods) {
                    .get => if (@hasField(Own, "__getitem__")) BaseSpecial.KeyOf("__getitem__", 1) else null,
                    .assign => if (@hasField(Own, "__setitem__") or @hasField(Own, "__delitem__")) assignKey(BaseSpecial) else null,
                };
                const Found = Key orelse continue;
                if (isIndex(Found)) keys.index = true else keys.object = true;
            }
            return keys;
        }

        fn iterate(self: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            const result = Special.callObject("__iter__", 0, self.?, .{}, .raise) catch return null;
            return result.?.ptr;
        }

        fn next(self: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            const Method = Special.Call("__next__", 0);
            if (@typeInfo(Method.Payload) != .optional) {
                @compileError(context ++ ": __next__ must return an optional, such as ?i64 (null ends the iteration)");
            }
            const convert = struct {
                fn convert(value: Method.Payload) errors.Error!?Object {
                    return if (value) |item| try conversion.intoPython(item) else null;
                }
            }.convert;
            const result = Method.invoke(self.?, .{}, .raise, convert) catch return null;
            // Returning null without an exception ends the iteration.
            return if (result.?) |obj| obj.ptr else null;
        }

        fn length(self: [*c]c.PyObject) callconv(.c) c.Py_ssize_t {
            const value = Special.callValue("__len__", 0, self.?, .{}) catch return -1;
            if (@typeInfo(@TypeOf(value)) != .int) @compileError(context ++ ": __len__ must return an integer");
            if (value < 0) {
                c.PyErr_SetString(c.PyExc_ValueError, "__len__() should return >= 0");
                return -1;
            }
            return std.math.cast(c.Py_ssize_t, value) orelse {
                c.PyErr_SetString(c.PyExc_OverflowError, "__len__() result is too large");
                return -1;
            };
        }

        fn getIndex(self: [*c]c.PyObject, index: c.Py_ssize_t) callconv(.c) [*c]c.PyObject {
            const key = indexAs(Special.KeyOf("__getitem__", 1), index) catch return null;
            const result = Special.callObject("__getitem__", 1, self.?, .{key}, .raise) catch return null;
            return result.?.ptr;
        }

        fn getItem(self: [*c]c.PyObject, key: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            const result = Special.callObject("__getitem__", 1, self.?, .{@as(*c.PyObject, key.?)}, .raise) catch return null;
            return result.?.ptr;
        }

        fn setIndex(self: [*c]c.PyObject, index: c.Py_ssize_t, value: [*c]c.PyObject) callconv(.c) c_int {
            const key = indexAs(assign_key.?, index) catch return -1;
            assign(self.?, key, value) catch return -1;
            return 0;
        }

        fn setItem(self: [*c]c.PyObject, key: [*c]c.PyObject, value: [*c]c.PyObject) callconv(.c) c_int {
            assign(self.?, @as(*c.PyObject, key.?), value) catch return -1;
            return 0;
        }

        fn getIndexByObject(self: [*c]c.PyObject, key: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            return getIndex(self, sequenceIndex(self.?, key.?) catch return null);
        }

        fn setIndexByObject(self: [*c]c.PyObject, key: [*c]c.PyObject, value: [*c]c.PyObject) callconv(.c) c_int {
            return setIndex(self, sequenceIndex(self.?, key.?) catch return -1, value);
        }

        fn getItemByIndex(self: [*c]c.PyObject, index: c.Py_ssize_t) callconv(.c) [*c]c.PyObject {
            const key = Object.own(c.PyLong_FromSsize_t(index)) catch return null;
            defer key.deinit();

            return getItem(self, key.ptr);
        }

        fn setItemByIndex(self: [*c]c.PyObject, index: c.Py_ssize_t, value: [*c]c.PyObject) callconv(.c) c_int {
            const key = Object.own(c.PyLong_FromSsize_t(index)) catch return -1;
            defer key.deinit();

            return setItem(self, key.ptr, value);
        }

        fn assign(self: *c.PyObject, key: anytype, value: ?*c.PyObject) errors.Error!void {
            if (value) |new| {
                if (comptime !Special.has("__setitem__")) {
                    return errors.raise(.TypeError, "'" ++ name ++ "' object does not support item assignment");
                }
                try Special.callVoid("__setitem__", 2, self, .{ key, new });
            } else {
                if (comptime !Special.has("__delitem__")) {
                    return errors.raise(.TypeError, "'" ++ name ++ "' object doesn't support item deletion");
                }
                try Special.callVoid("__delitem__", 1, self, .{key});
            }
        }

        fn indexAs(comptime Key: type, index: c.Py_ssize_t) errors.Error!Key {
            // CPython adds the length to negative indexes before calling the slot.
            return std.math.cast(Key, index) orelse errors.raise(.IndexError, name ++ " index out of range");
        }

        fn contains(self: [*c]c.PyObject, item: [*c]c.PyObject) callconv(.c) c_int {
            const Method = Special.Call("__contains__", 1);
            if (Method.Payload != bool) @compileError(context ++ ": __contains__ must return bool");
            const convert = struct {
                fn convert(value: bool) errors.Error!bool {
                    return value;
                }
            }.convert;
            // Failed argument conversion means the item is absent, matching Python membership tests.
            const found = Method.invoke(self.?, .{@as(*c.PyObject, item.?)}, .not_implemented, convert) catch return -1;
            return @intFromBool(found orelse false);
        }
    };
}

const Keys = struct { index: bool = false, object: bool = false };

fn assignKey(comptime Special: type) ?type {
    if (Special.has("__setitem__") and Special.has("__delitem__") and
        Special.KeyOf("__setitem__", 2) != Special.KeyOf("__delitem__", 1))
    {
        @compileError(Special.context ++ ": __setitem__ and __delitem__ must take the same key type");
    }
    if (Special.has("__setitem__")) return Special.KeyOf("__setitem__", 2);
    if (Special.has("__delitem__")) return Special.KeyOf("__delitem__", 1);
    return null;
}

fn isIndex(comptime T: type) bool {
    return @typeInfo(T) == .int;
}

fn sequenceIndex(obj: *c.PyObject, key: *c.PyObject) errors.Error!c.Py_ssize_t {
    if (c.PyIndex_Check(key) == 0) {
        _ = c.PyErr_Format(c.PyExc_TypeError, "sequence index must be integer, not '%T'", key);
        return error.PythonError;
    }
    const index = c.PyNumber_AsSsize_t(key, c.PyExc_IndexError);
    if (index == -1 and c.PyErr_Occurred() != null) return error.PythonError;
    if (index >= 0) return index;

    const length = c.PyObject_Size(obj);
    if (length >= 0) return index + length;
    // Without a length, the slot gets the negative index, as from CPython's own wrapper.
    if (c.PyErr_ExceptionMatches(c.PyExc_TypeError) == 0) return error.PythonError;
    c.PyErr_Clear();
    return index;
}
