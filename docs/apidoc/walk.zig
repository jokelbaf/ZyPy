const std = @import("std");
const Ast = std.zig.Ast;

const config = @import("config.zig");
const Context = @import("Context.zig");
const Scope = @import("Scope.zig");

/// A documented declaration.
pub const Item = struct {
    /// The public API name used in headings and signatures, such as "py.List.get".
    heading: []const u8,
    /// The name in the declaration's signature, such as "get" or "addExtension".
    name: []const u8,
    kind: Kind,
    doc: []const u8,
    /// The declaration that defines it, or `null` for external items.
    ref: ?Scope.Ref,
    /// The file that defines it, from the repository root.
    path: []const u8,
    /// The line of the definition, or 0 for a whole file.
    line: usize,
    members: []const Item = &.{},
    /// Where external items are documented.
    url: ?[]const u8 = null,

    pub const Kind = enum { namespace, type, type_function, function, constant, field, external };
};

/// Public API declarations and their names for use in signatures.
pub const Walker = struct {
    context: *Context,
    /// The public name of each declaration found, by its scope and node.
    names: std.AutoHashMapUnmanaged(Key, []const u8) = .empty,
    /// Declarations without doc comments, as messages with their location.
    problems: std.ArrayList([]const u8) = .empty,

    const Key = struct { scope: *Scope, node: Ast.Node.Index };

    /// Describe the public declarations of a root file, such as src/root.zig as `py`.
    pub fn walkRoot(self: *Walker, root: config.Root) ![]const Item {
        const arena = self.context.arena;
        const scope = try self.context.file(root.path);

        var items: std.ArrayList(Item) = .empty;
        var buffer: [2]Ast.Node.Index = undefined;
        for (scope.source.members(.root, &buffer)) |node| {
            const decl = scope.source.declOf(node) orelse continue;
            if (!decl.is_pub or decl.kind == .field) continue;

            const heading = try std.fmt.allocPrint(arena, "{s}.{s}", .{ root.prefix, decl.name });
            if (contains(&config.hidden, heading)) continue;

            if (externalItem(heading)) |item| {
                try items.append(arena, item);
                continue;
            }
            try items.append(arena, try self.describe(.{ .scope = scope, .decl = decl }, decl.name, root.prefix, null));
        }
        return items.items;
    }

    fn describe(self: *Walker, ref: Scope.Ref, name: []const u8, prefix: []const u8, alias_doc: ?[]const u8) anyerror!Item {
        const arena = self.context.arena;
        const printed = try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, name });
        try self.register(ref, printed);
        const own_doc = try ref.scope.source.docComment(arena, ref.decl);

        if (ref.decl.kind == .variable) {
            switch (try self.context.deref(ref)) {
                .decl => |target| return self.describe(target, name, prefix, alias_doc orelse own_doc),
                .container => |container| return self.describeContainer(ref, container, printed, alias_doc orelse own_doc),
                else => {},
            }
        }

        const doc = try self.require(ref, printed, alias_doc orelse own_doc);
        if (ref.decl.kind == .function and self.context.isTypeFunction(ref)) {
            const names = try self.context.parameterNames(ref);
            const heading = try std.fmt.allocPrint(arena, "{s}({s})", .{ printed, try std.mem.join(arena, ", ", names) });
            const args = try arena.alloc(Scope.Value, names.len);
            for (args, names) |*arg, parameter| arg.* = .{ .unbound = parameter };

            var item = self.leaf(ref, name, heading, .type_function, doc);
            const value = try self.context.instantiate(ref, args);
            if (value == .container) {
                value.container.display = heading;
                item.members = try self.walkMembers(value.container, heading, shownMembers(printed));
            }
            return item;
        }
        return self.leaf(ref, name, printed, switch (ref.decl.kind) {
            .function => .function,
            .field => .field,
            .variable => .constant,
        }, doc);
    }

    fn describeContainer(self: *Walker, ref: Scope.Ref, container: *Scope, printed: []const u8, doc: ?[]const u8) !Item {
        if (container.display == null) container.display = printed;
        const whole_file = container.container.? == .root;

        var item = self.leaf(ref, ref.decl.name, printed, .namespace, try self.require(ref, printed, doc));
        if (whole_file) {
            item.path = container.source.path;
            item.line = 0;
        }
        if (hasFields(container)) item.kind = .type;
        item.members = try self.walkMembers(container, container.display.?, null);
        return item;
    }

    fn walkMembers(self: *Walker, container: *Scope, display: []const u8, shown: ?[]const []const u8) ![]const Item {
        const arena = self.context.arena;
        const source = container.source;

        var items: std.ArrayList(Item) = .empty;
        var buffer: [2]Ast.Node.Index = undefined;
        for (source.members(container.container.?, &buffer)) |node| {
            const decl = source.declOf(node) orelse continue;
            if (!decl.is_pub or std.mem.startsWith(u8, decl.name, config.marker_prefix)) continue;
            if (contains(&config.hidden_members, decl.name)) continue;
            if (shown) |names| if (!contains(names, decl.name)) continue;

            const ref: Scope.Ref = .{ .scope = container, .decl = decl };
            if (decl.kind == .field and try source.docComment(arena, decl) == null) {
                const path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ try normalize(arena, display), decl.name });
                if (!contains(&config.internal_fields, path)) try self.problem(ref, path);
                continue;
            }
            if (decl.kind == .function and try self.unavailable(ref)) continue;
            try items.append(arena, try self.describe(ref, decl.name, display, null));
        }
        return items.items;
    }

    fn leaf(_: *Walker, ref: Scope.Ref, name: []const u8, heading: []const u8, kind: Item.Kind, doc: []const u8) Item {
        const source = ref.scope.source;
        return .{
            .heading = heading,
            .name = name,
            .kind = kind,
            .doc = doc,
            .ref = ref,
            .path = source.path,
            .line = source.line(ref.decl.first_token),
        };
    }

    fn register(self: *Walker, ref: Scope.Ref, printed: []const u8) !void {
        const entry = try self.names.getOrPut(self.context.arena, .{ .scope = ref.scope, .node = ref.decl.node });
        if (!entry.found_existing) entry.value_ptr.* = printed;
    }

    fn require(self: *Walker, ref: Scope.Ref, printed: []const u8, doc: ?[]const u8) ![]const u8 {
        if (doc) |text| return text;

        try self.problem(ref, printed);
        return "";
    }

    fn problem(self: *Walker, ref: Scope.Ref, name: []const u8) !void {
        const source = ref.scope.source;
        const message = try std.fmt.allocPrint(self.context.arena, "{s}:{d}: {s} has no doc comment", .{
            source.path, source.line(ref.decl.first_token), name,
        });
        try self.problems.append(self.context.arena, message);
    }

    fn unavailable(self: *Walker, ref: Scope.Ref) !bool {
        const tree = &ref.scope.source.tree;
        const body = tree.nodeData(ref.decl.node).node_and_node[1];
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, body) orelse return false;
        if (statements.len == 0) return false;

        const first = statements[0];
        if (isCompileError(tree, first)) return true;

        const condition = tree.fullIf(first) orelse return false;
        if (condition.ast.else_expr != .none or !isCompileError(tree, condition.ast.then_expr)) return false;
        return try self.context.evalBool(ref.scope, condition.ast.cond_expr) orelse false;
    }
};

/// Remove the parameters from a heading: "py.Dict.Iterator(K, V).next" becomes "py.Dict.Iterator.next".
pub fn normalize(arena: std.mem.Allocator, heading: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    for (heading) |char| switch (char) {
        '(' => depth += 1,
        ')' => depth -= 1,
        else => if (depth == 0) try result.append(arena, char),
    };
    return result.items;
}

fn isCompileError(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@compileError"),
        else => false,
    };
}

fn hasFields(container: *Scope) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    for (container.source.members(container.container.?, &buffer)) |node| {
        const decl = container.source.declOf(node) orelse continue;
        if (decl.kind == .field) return true;
    }
    return false;
}

fn shownMembers(printed: []const u8) ?[]const []const u8 {
    for (config.shown_members) |entry| {
        if (std.mem.eql(u8, entry.function, printed)) return entry.members;
    }
    return null;
}

fn externalItem(heading: []const u8) ?Item {
    for (config.external) |entry| {
        if (!std.mem.eql(u8, entry.name, heading)) continue;
        return .{ .heading = heading, .name = heading, .kind = .external, .doc = entry.summary, .ref = null, .path = "", .line = 0, .url = entry.url };
    }
    return null;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}
