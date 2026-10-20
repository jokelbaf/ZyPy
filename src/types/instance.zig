const c = @import("python");

const class = @import("../class.zig");
const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const Object = @import("Object.zig");
const reference = @import("reference.zig");

/// A reference to an instance of class `T` or a subclass.
pub fn Instance(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Value = T;

        /// The instance as a `py.Object`, for attribute access and calls.
        obj: Object,

        const methods = reference.Methods(Self);
        pub const own = methods.own;
        pub const deinit = methods.deinit;
        pub const newRef = methods.newRef;
        pub const toPython = methods.toPython;

        /// Create an owned instance of `T`, skipping its constructor.
        /// Consume `contents` even if creation fails.
        pub fn init(contents: T) errors.Error!Self {
            comptime class.requireClass("py.Instance", T);
            return .{ .obj = try conversion.intoPython(contents) };
        }

        /// Get a pointer to the Zig value inside the instance, valid while the instance lives.
        pub fn value(self: Self) *T {
            comptime class.requireClass("py.Instance", T);
            return class.valueOf(T, self.obj.ptr);
        }

        /// Borrow `obj` as an instance of `T`. Raise `TypeError` for other objects.
        pub fn fromPython(obj: Object) errors.Error!Self {
            comptime class.requireClass("py.Instance", T);
            _ = try class.checkInstance(T, obj.ptr);
            return .{ .obj = .borrow(obj.ptr) };
        }
    };
}

/// Check whether `T` is a type made by `py.Instance`.
pub fn isInstanceType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Value") and @TypeOf(T.Value) == type and T == Instance(T.Value);
}
