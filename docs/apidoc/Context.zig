const std = @import("std");
const Ast = std.zig.Ast;

const Scope = @import("Scope.zig");
const Source = @import("Source.zig");

const Context = @This();
const Value = Scope.Value;

arena: std.mem.Allocator,
io: std.Io,
/// The repository root.
root: std.Io.Dir,
/// The scope of each file read so far, by path.
files: std.StringHashMapUnmanaged(*Scope) = .empty,

/// Get the scope of the file at `path`, reading it the first time.
pub fn file(self: *Context, path: []const u8) !*Scope {
    if (self.files.get(path)) |scope| return scope;

    const source = try Source.load(self.arena, self.io, self.root, path);
    const scope = try self.arena.create(Scope);
    scope.* = .{ .source = source, .container = .root, .parent = null };
    try self.files.put(self.arena, path, scope);
    return scope;
}

/// Resolve declarations, imports, and type-function calls in an expression.
pub fn eval(self: *Context, scope: *Scope, node: Ast.Node.Index) anyerror!Value {
    const tree = &scope.source.tree;
    const unevaluated: Value = .{ .expr = .{ .scope = scope, .node = node } };
    switch (tree.nodeTag(node)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            if (std.mem.eql(u8, name, "true")) return .{ .boolean = true };
            if (std.mem.eql(u8, name, "false")) return .{ .boolean = false };
            return scope.lookup(name) orelse unevaluated;
        },
        .field_access => {
            const lhs, const name = tree.nodeData(node).node_and_token;
            return try self.member(try self.eval(scope, lhs), tree.tokenSlice(name)) orelse unevaluated;
        },
        .grouped_expression => return self.eval(scope, tree.nodeData(node).node_and_token[0]),
        .enum_literal => return .{ .enum_literal = tree.tokenSlice(tree.nodeMainToken(node)) },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const builtin = tree.tokenSlice(tree.nodeMainToken(node));
            if (std.mem.eql(u8, builtin, "@This")) return .{ .container = scope.innermost() };
            if (!std.mem.eql(u8, builtin, "@import")) return unevaluated;

            var buffer: [2]Ast.Node.Index = undefined;
            const literal = tree.tokenSlice(tree.nodeMainToken(tree.builtinCallParams(&buffer, node).?[0]));
            const path = literal[1 .. literal.len - 1];
            if (!std.mem.endsWith(u8, path, ".zig")) return .{ .module = path };

            const directory = std.fs.path.dirname(scope.source.path) orelse ".";
            return .{ .container = try self.file(try std.fs.path.resolveAllocPosix(self.arena, &.{ directory, path })) };
        },
        .call_one, .call_one_comma, .call, .call_comma => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node).?;
            const callee = try self.eval(scope, call.ast.fn_expr);
            if (callee != .decl or !self.isTypeFunction(callee.decl)) return unevaluated;

            const args = try self.arena.alloc(Value, call.ast.params.len);
            for (call.ast.params, args) |param, *arg| arg.* = try self.eval(scope, param);
            return self.instantiate(callee.decl, args);
        },
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        => {
            const container = try self.arena.create(Scope);
            container.* = .{ .source = scope.source, .container = node, .parent = scope };
            return .{ .container = container };
        },
        .equal_equal, .bang_equal, .bool_not, .bool_and, .bool_or => {
            return if (try self.evalBool(scope, node)) |known| .{ .boolean = known } else unevaluated;
        },
        else => return unevaluated,
    }
}

/// Find member `name` in the container referenced by `value`.
pub fn member(self: *Context, value: Value, name: []const u8) anyerror!?Value {
    switch (value) {
        .container => |scope| {
            const decl = scope.source.find(scope.container orelse return null, name) orelse return null;
            return .{ .decl = .{ .scope = scope, .decl = decl } };
        },
        .decl => |ref| {
            const target = try self.deref(ref);
            if (target == .decl and target.decl.decl.node == ref.decl.node) return null;
            return self.member(target, name);
        },
        else => return null,
    }
}

/// Evaluate the value of a constant. Functions and fields stay declarations.
pub fn deref(self: *Context, ref: Scope.Ref) anyerror!Value {
    if (ref.decl.kind != .variable) return .{ .decl = ref };

    const init = ref.scope.source.tree.fullVarDecl(ref.decl.node).?.ast.init_node.unwrap() orelse return .unknown;
    return self.eval(ref.scope, init);
}

/// Check whether a declaration is a function that returns `type`.
pub fn isTypeFunction(_: *Context, ref: Scope.Ref) bool {
    if (ref.decl.kind != .function) return false;

    const tree = &ref.scope.source.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const returned = tree.fullFnProto(&buffer, ref.decl.node).?.ast.return_type.unwrap() orelse return false;
    return tree.nodeTag(returned) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(returned)), "type");
}

/// Get the names of a function's parameters.
pub fn parameterNames(self: *Context, ref: Scope.Ref) ![]const []const u8 {
    const tree = &ref.scope.source.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, ref.decl.node).?;

    var names: std.ArrayList([]const u8) = .empty;
    var params = proto.iterate(tree);
    while (params.next()) |param| try names.append(self.arena, tree.tokenSlice(param.name_token.?));
    return names.items;
}

/// Call a type function with `args` and evaluate the type it returns.
pub fn instantiate(self: *Context, ref: Scope.Ref, args: []const Value) !Value {
    const names = try self.parameterNames(ref);
    const bindings = try self.arena.alloc(Scope.Binding, names.len);
    for (bindings, names, 0..) |*binding, name, i| {
        binding.* = .{ .name = name, .value = if (i < args.len) args[i] else .unknown };
    }

    const scope = try self.arena.create(Scope);
    scope.* = .{ .source = ref.scope.source, .container = null, .parent = ref.scope, .bindings = bindings };

    const tree = &ref.scope.source.tree;
    const body = tree.nodeData(ref.decl.node).node_and_node[1];
    var buffer: [2]Ast.Node.Index = undefined;
    for (tree.blockStatements(&buffer, body) orelse return .unknown) |statement| {
        if (tree.nodeTag(statement) != .@"return") continue;
        return self.eval(scope, tree.nodeData(statement).opt_node.unwrap() orelse return .unknown);
    }
    return .unknown;
}

/// Evaluate a boolean condition or enum comparison. Return `null` for unsupported expressions.
pub fn evalBool(self: *Context, scope: *Scope, node: Ast.Node.Index) anyerror!?bool {
    const tree = &scope.source.tree;
    switch (tree.nodeTag(node)) {
        .equal_equal, .bang_equal => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = try self.eval(scope, lhs);
            const right = try self.eval(scope, rhs);
            if (left != .enum_literal or right != .enum_literal) return null;

            const same = std.mem.eql(u8, left.enum_literal, right.enum_literal);
            return if (tree.nodeTag(node) == .equal_equal) same else !same;
        },
        .bool_not => return if (try self.evalBool(scope, tree.nodeData(node).node)) |known| !known else null,
        .bool_and, .bool_or => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = try self.evalBool(scope, lhs) orelse return null;
            const right = try self.evalBool(scope, rhs) orelse return null;
            return if (tree.nodeTag(node) == .bool_and) left and right else left or right;
        },
        else => {
            var value = try self.eval(scope, node);
            if (value == .decl) value = try self.deref(value.decl);
            return if (value == .boolean) value.boolean else null;
        },
    }
}
