const class = @import("../class.zig");
const errors = @import("../errors.zig");
const Instance = @import("instance.zig").Instance;
const Object = @import("Object.zig");
const reference = @import("reference.zig");

/// A reference to the Python class for `T` or a subclass.
/// As a method receiver, it makes a class method.
pub fn Class(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Value = T;

        /// The class as a `py.Object`, for attribute access and calls.
        obj: Object,

        const methods = reference.Methods(Self);
        pub const own = methods.own;
        pub const deinit = methods.deinit;
        pub const newRef = methods.newRef;
        pub const toPython = methods.toPython;

        /// Create an owned instance with `contents`, skipping the constructor. Consume `contents` even on failure.
        /// Raise `TypeError` for Zig subclasses of `T`.
        pub fn new(self: Self, contents: T) errors.Error!Instance(T) {
            comptime class.requireClass("py.Class", T);
            return .{ .obj = try class.constructIn(T, @ptrCast(self.obj.ptr), contents) };
        }

        /// Borrow `obj` as `T`'s class or a subclass. Raise `TypeError` for other objects.
        pub fn fromPython(obj: Object) errors.Error!Self {
            comptime class.requireClass("py.Class", T);
            try class.checkSubclass(T, obj.ptr);
            return .{ .obj = .borrow(obj.ptr) };
        }
    };
}

/// Check whether `T` is a type made by `py.Class`.
pub fn isClassObject(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Value") and @TypeOf(T.Value) == type and T == Class(T.Value);
}
