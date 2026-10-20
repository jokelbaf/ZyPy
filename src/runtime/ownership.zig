const std = @import("std");

const class = @import("../class.zig");
const Object = @import("../types/Object.zig");
const owned = @import("../types/owned.zig");
const reflection = @import("reflection.zig");

/// Release the references and views a value owns, including inside tuples, structs, optionals and arrays.
pub fn deinit(value: anytype) void {
    const T = @TypeOf(value);
    if (comptime owned.isOwned(T)) return deinit(value.value);
    if (comptime std.meta.hasFn(T, "deinit")) {
        if (comptime @typeInfo(@TypeOf(T.deinit)).@"fn".param_types[0] != *T) return value.deinit();
        var copy = value;
        return copy.deinit();
    }

    switch (@typeInfo(T)) {
        .optional => if (value) |inner| deinit(inner),
        .array => for (value) |item| deinit(item),
        .@"struct" => |info| inline for (info.field_names) |name| deinit(@field(value, name)),
        else => {},
    }
}

/// Release a class value or module state through `ptr`, calling `deinit` and releasing `py.Owned` fields.
/// Custom `deinit` must release other resources and, for subclasses, the base value.
pub fn release(ptr: anytype) void {
    runDeinit(ptr);
    releaseOwned(ptr);
}

fn runDeinit(ptr: anytype) void {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    if (comptime owned.isOwned(T)) return;
    if (comptime std.meta.hasFn(T, "deinit")) return ptr.deinit();
    if (comptime class.isClass(T) and class.Definition(T).Base != null) runDeinit(&@field(ptr, class.baseField(T)));
}

fn releaseOwned(ptr: anytype) void {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    if (comptime owned.isOwned(T)) return ptr.deinit();
    if (comptime isReference(T) or std.meta.hasFn(T, "fromPython")) return;

    switch (@typeInfo(T)) {
        .optional => if (ptr.*) |*inner| releaseOwned(inner),
        .array => for (ptr) |*item| releaseOwned(item),
        .@"struct" => |info| inline for (info.field_names, info.field_attrs) |name, attrs| {
            if (!attrs.@"comptime") releaseOwned(&@field(ptr, name));
        },
        else => {},
    }
}

/// Create a borrowed copy of `value` for use as a function argument, so that releasing it does nothing.
pub fn lend(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    if (comptime hasOwnedFlag(T)) {
        var copy = value;
        copy.owned = false;
        return copy;
    }

    switch (@typeInfo(T)) {
        .optional => return if (value) |inner| lend(inner) else null,
        .array => {
            var copy = value;
            for (&copy) |*item| item.* = lend(item.*);
            return copy;
        },
        .@"struct" => |info| {
            var copy = value;
            inline for (info.field_names, info.field_attrs) |name, attrs| {
                if (!attrs.@"comptime") @field(copy, name) = lend(@field(value, name));
            }
            return copy;
        },
        else => return value,
    }
}

/// Give borrowed object references their own references and transfer existing owned references.
/// Leave views, byte slices, pointers, and other conversion types unchanged.
pub fn retain(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    if (T == Object) return if (value.owned) value else value.newRef();
    if (comptime isReference(T)) return .{ .obj = retain(value.obj) };
    if (comptime owned.isOwned(T)) return .{ .value = retain(value.value) };

    switch (@typeInfo(T)) {
        .optional => return if (value) |inner| retain(inner) else null,
        .array => {
            var copy = value;
            for (&copy) |*item| item.* = retain(item.*);
            return copy;
        },
        .@"struct" => |info| {
            if (comptime std.meta.hasFn(T, "fromPython")) {
                if (comptime hasOwnedFlag(T)) checkOwns(value);
                return value;
            }

            var copy = value;
            inline for (info.field_names, info.field_attrs) |name, attrs| {
                if (!attrs.@"comptime") @field(copy, name) = retain(@field(value, name));
            }
            return copy;
        },
        else => return value,
    }
}

fn checkOwns(value: anytype) void {
    if (std.debug.runtime_safety and !value.owned) {
        @panic(@typeName(@TypeOf(value)) ++ ".fromPython returned a value with owned = false, but a value with an " ++
            "owned field must own what it holds, since ZyPy keeps it after releasing the object");
    }
}

/// Give copied class values their own object references. Release copies with `deinit`.
/// Structs read from mappings already own their fields.
pub fn ownCopies(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    if (comptime class.isClass(T)) return retain(value);

    switch (@typeInfo(T)) {
        .optional => return if (value) |inner| ownCopies(inner) else null,
        .@"struct" => |info| {
            if (!info.is_tuple) return value;

            var copy = value;
            inline for (0..info.field_types.len) |i| copy[i] = ownCopies(value[i]);
            return copy;
        },
        else => return value,
    }
}

/// Mark an existing reference as owned without increasing its reference count.
pub fn owning(value: anytype) @TypeOf(value) {
    if (@TypeOf(value) == Object) return .{ .ptr = value.ptr, .owned = true };
    return .{ .obj = owning(value.obj) };
}

/// Check whether a Python conversion type uses an `owned: bool` flag.
pub fn hasOwnedFlag(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and std.meta.hasFn(T, "fromPython") and @hasField(T, "owned") and
        @FieldType(T, "owned") == bool;
}

/// Check whether `T` is `py.Object` or a typed object reference.
pub fn isReference(comptime T: type) bool {
    if (T == Object) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.field_names.len == 1 and @hasField(T, "obj") and @FieldType(T, "obj") == Object and
            std.meta.hasFn(T, "fromPython"),
        else => false,
    };
}

/// Check whether copying `T` would share resources other than Python references.
/// Includes types with a `deinit` method, such as views, and structs containing them.
pub fn ownsResources(comptime T: type) bool {
    if (isReference(T)) return false;
    if (owned.isOwned(T)) return ownsResources(@FieldType(T, "value"));
    if (reflection.elementOf(T)) |Element| return ownsResources(Element);

    const fields = reflection.fieldTypes(T) orelse return false;
    return std.meta.hasFn(T, "deinit") or reflection.any(fields, ownsResources);
}

/// Check whether `T` has cleanup that `lend` cannot disable with an `owned` field.
/// Do not release borrowed copies of such values.
pub fn hasManualDeinit(comptime T: type) bool {
    if (isReference(T)) return false;
    if (owned.isOwned(T)) return hasManualDeinit(@FieldType(T, "value"));
    if (reflection.elementOf(T)) |Element| return hasManualDeinit(Element);

    const fields = reflection.fieldTypes(T) orelse return false;
    if (std.meta.hasFn(T, "deinit") and !hasOwnedFlag(T)) return true;
    return reflection.any(fields, hasManualDeinit);
}

/// Find a conversion type whose cleanup `lend` cannot disable, or return `null`.
pub fn unlendable(comptime T: type) ?type {
    if (isReference(T) or owned.isOwned(T) or class.isClass(T)) return null;
    if (reflection.elementOf(T)) |Element| return unlendable(Element);

    const fields = reflection.fieldTypes(T) orelse return null;
    if (!std.meta.hasFn(T, "fromPython")) return reflection.first(fields, unlendable);
    if (std.meta.hasFn(T, "deinit") and !hasOwnedFlag(T)) return T;
    return null;
}

/// Check whether a converted value of `T` can borrow data from its source object.
pub fn dependsOnSource(comptime T: type) bool {
    if (isReference(T) or borrows(T) or class.isClass(T)) return true;
    if (owned.isOwned(T) or std.meta.hasFn(T, "fromPython")) return false;
    if (reflection.elementOf(T)) |Element| return dependsOnSource(Element);

    if (!reflection.isTuple(T)) return false;
    return reflection.any(reflection.fieldTypes(T).?, dependsOnSource);
}

/// Check whether `T` can borrow Python data without keeping its owner alive.
/// Includes byte slices, instance pointers, and conversion types that `retain` cannot manage.
pub fn borrows(comptime T: type) bool {
    return holdsByteSlice(T) or pointedClass(T) != null or holdsOpaque(T);
}

/// Check whether `T` contains a byte slice that borrows memory from a Python object.
pub fn holdsByteSlice(comptime T: type) bool {
    if (T == []const u8) return true;
    if (reflection.elementOf(T)) |Element| return holdsByteSlice(Element);

    const fields = reflection.fieldTypes(T) orelse return false;
    if (std.meta.hasFn(T, "fromPython")) return false;
    return reflection.any(fields, holdsByteSlice);
}

/// Get the class that a pointer in `T` points into, or `null` if `T` holds no such pointer.
pub fn pointedClass(comptime T: type) ?type {
    if (reflection.pointee(T)) |Child| return if (class.isClass(Child)) Child else null;
    if (owned.isOwned(T)) return pointedClass(@FieldType(T, "value"));
    if (reflection.elementOf(T)) |Element| return pointedClass(Element);

    const fields = reflection.fieldTypes(T) orelse return null;
    if (std.meta.hasFn(T, "fromPython")) return null;
    return reflection.first(fields, pointedClass);
}

/// Check whether `T` contains a conversion type whose references ZyPy cannot inspect or retain.
/// Excludes object references, views, and `py.Owned`.
pub fn holdsOpaque(comptime T: type) bool {
    if (isReference(T) or owned.isOwned(T)) return false;
    if (reflection.elementOf(T)) |Element| return holdsOpaque(Element);

    const fields = reflection.fieldTypes(T) orelse return false;
    if (std.meta.hasFn(T, "fromPython")) return !hasOwnedFlag(T);
    return reflection.any(fields, holdsOpaque);
}
