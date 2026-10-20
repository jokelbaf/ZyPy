const c = @import("python");

const conversion = @import("../conversion.zig");
const errors = @import("../errors.zig");
const names = @import("../runtime/names.zig");
const Object = @import("Object.zig");
const Str = @import("Str.zig");

/// Call `callable(*args, **kwargs)` and convert the result to `T`.
pub fn call(comptime T: type, callable: Object, args: anytype, kwargs: anytype) errors.Error!T {
    return invoke(T, .{ .function = callable.ptr }, args, kwargs);
}

/// Call `self.name(*args, **kwargs)` and convert the result to `T`.
/// Accept a string literal or `py.Str` as `name`.
pub inline fn callMethod(comptime T: type, self: Object, name: anytype, args: anytype, kwargs: anytype) errors.Error!T {
    if (@TypeOf(name) == Str) return invoke(T, .{ .method = .{ .self = self.ptr, .name = name.obj.ptr } }, args, kwargs);

    comptime checkLiteral(@TypeOf(name));

    const method = try names.method(name);
    defer method.deinit();

    return invoke(T, .{ .method = .{ .self = self.ptr, .name = method.ptr } }, args, kwargs);
}

fn checkLiteral(comptime Name: type) void {
    if (conversion.isStringLiteral(Name)) return;
    @compileError("expected a method name as a string literal or a py.Str, got " ++ @typeName(Name) ++
        " (use py.Str.init for names from data)");
}

const Target = union(enum) {
    function: *c.PyObject,
    method: struct { self: *c.PyObject, name: *c.PyObject },
};

fn invoke(comptime T: type, target: Target, args: anytype, kwargs: anytype) errors.Error!T {
    const positional = comptime positionalCount(@TypeOf(args));
    const keywords = comptime keywordNames(@TypeOf(kwargs));

    // Reserve slot 0 for the method receiver or for use by the called function.
    var stack: [1 + positional + keywords.len][*c]c.PyObject = undefined;
    var converted: usize = 0;
    defer for (stack[1..][0..converted]) |item| c.Py_DecRef(item);

    inline for (0..positional) |i| {
        stack[1 + i] = (try conversion.toPython(args[i])).ptr;
        converted += 1;
    }
    inline for (keywords, 0..) |name, i| {
        stack[1 + positional + i] = (try conversion.toPython(@field(kwargs, name))).ptr;
        converted += 1;
    }

    const keyword_tuple = try names.keywordTuple(keywords);
    defer if (keyword_tuple) |tuple| tuple.deinit();
    const kwnames = if (keyword_tuple) |tuple| tuple.ptr else null;

    const result = switch (target) {
        .function => |callable| c.PyObject_Vectorcall(callable, stack[1..].ptr, positional | offset, kwnames),
        .method => |method| method: {
            stack[0] = method.self;
            break :method c.PyObject_VectorcallMethod(method.name, &stack, (1 + positional) | offset, kwnames);
        },
    };
    return conversion.take(T, try .own(result));
}

const offset: usize = c.PY_VECTORCALL_ARGUMENTS_OFFSET;

fn positionalCount(comptime Args: type) usize {
    const info = @typeInfo(Args);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("expected a tuple of arguments, such as .{ 1, \"x\" }, got " ++ @typeName(Args));
    }
    return info.@"struct".field_types.len;
}

fn keywordNames(comptime Kwargs: type) []const [:0]const u8 {
    const info = @typeInfo(Kwargs);
    if (info != .@"struct" or (info.@"struct".is_tuple and info.@"struct".field_types.len > 0)) {
        @compileError("expected a struct of keyword arguments, such as .{ .indent = 2 }, got " ++ @typeName(Kwargs));
    }
    return info.@"struct".field_names;
}
