const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const gc = @import("../runtime/gc.zig");
const ownership = @import("../runtime/ownership.zig");
const Object = @import("Object.zig");

/// A class or module-state field that owns its Python references, such as `py.Owned(py.Str)`.
/// The instance or module releases them during cleanup.
pub fn Owned(comptime T: type) type {
    comptime check(T);

    return struct {
        const Self = @This();

        value: T,

        pub const zypy_owned: Marker = .{};

        /// Store `value` with new references to its Python objects. Leave the caller's references unchanged.
        pub fn init(value: T) Self {
            comptime checkPointers(T);
            return .{ .value = ownership.retain(ownership.lend(value)) };
        }

        /// Get the value. Object references in it are borrowed from the field.
        pub fn get(self: Self) T {
            return ownership.lend(self.value);
        }

        /// Replace the value with new references to its Python objects and release the old references.
        /// Leave the caller's references unchanged.
        pub fn set(self: *Self, value: T) void {
            comptime checkPointers(T);
            const old = self.value;
            self.value = ownership.retain(ownership.lend(value));
            ownership.deinit(old);
        }

        /// Release references and replace them with `None`, or `null` for optional references.
        /// Repeated cleanup is safe.
        pub fn deinit(self: *Self) void {
            gc.clear(&self.value);
        }

        /// Convert `obj` to a field value with owned references.
        pub fn fromPython(obj: Object) errors.Error!Self {
            comptime checkPointers(T);
            return .{ .value = ownership.retain(try conversion.fromPython(T, obj)) };
        }

        /// Convert the field value to an owned Python object.
        pub fn toPython(self: Self) errors.Error!Object {
            return conversion.toPython(self.value);
        }
    };
}

const Marker = struct {};

/// Check whether `T` is `py.Owned(V)` for some type `V`.
pub fn isOwned(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zypy_owned") and @TypeOf(T.zypy_owned) == Marker;
}

fn check(comptime T: type) void {
    const context = "py.Owned(" ++ @typeName(T) ++ ")";
    if (ownership.holdsByteSlice(T)) {
        @compileError(context ++ " can't hold a []const u8, which would point into an object the field doesn't keep " ++
            "(use py.Bytes)");
    }
    if (ownership.ownsResources(T)) {
        @compileError(context ++ " can only hold Python objects and plain values, not views such as py.Buffer(T) " ++
            "(hold the object, and create the view when you need it)");
    }
    if (ownership.holdsOpaque(T)) {
        @compileError(context ++ " can only hold Python objects and plain values: ZyPy can't tell which references " ++
            "a conversion type holds (use py.Object)");
    }
}

// Delay pointer checks until the class definition is complete to avoid recursive type checks.
fn checkPointers(comptime T: type) void {
    if (ownership.pointedClass(T)) |Class| {
        @compileError("py.Owned(" ++ @typeName(T) ++ ") can't keep the instance alive through a pointer " ++
            "(use py.Owned(py.Instance(" ++ @typeName(Class) ++ ")))");
    }
}
