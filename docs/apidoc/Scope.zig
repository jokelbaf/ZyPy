const std = @import("std");
const Ast = std.zig.Ast;

const Source = @import("Source.zig");

const Scope = @This();

source: *Source,
/// A container node (`.root` for the file), or `null` for the parameters of a type function.
container: ?Ast.Node.Index,
parent: ?*Scope,
/// The parameters of a type function, bound by the call that instantiated it.
bindings: []const Binding = &.{},
/// The public container name, such as "py.List", or null until discovered.
display: ?[]const u8 = null,

/// A comptime parameter and the value it was called with.
pub const Binding = struct { name: []const u8, value: Value };

/// An expression value used to resolve API declarations.
pub const Value = union(enum) {
    /// A declaration in a container.
    decl: Ref,
    container: *Scope,
    enum_literal: []const u8,
    boolean: bool,
    /// A comptime parameter that stays generic, such as `T`.
    unbound: []const u8,
    /// An expression that signatures show as written.
    expr: Expr,
    /// A package import such as `@import("std")`.
    module: []const u8,
    unknown,
};

/// A declaration and the scope it is in.
pub const Ref = struct { scope: *Scope, decl: Source.Decl };

/// An expression and the scope its names resolve in.
pub const Expr = struct { scope: *Scope, node: Ast.Node.Index };

/// Resolve `name` in this scope, or return `null`.
pub fn lookup(self: *Scope, name: []const u8) ?Value {
    var scope: ?*Scope = self;
    while (scope) |current| : (scope = current.parent) {
        for (current.bindings) |binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding.value;
        }
        if (current.container) |container| {
            if (current.source.find(container, name)) |decl| return .{ .decl = .{ .scope = current, .decl = decl } };
        }
    }
    return null;
}

/// Get the innermost container scope, which `@This()` refers to.
pub fn innermost(self: *Scope) *Scope {
    var scope = self;
    while (scope.container == null) scope = scope.parent.?;
    return scope;
}
