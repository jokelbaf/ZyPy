const std = @import("std");
const Ast = std.zig.Ast;

const Context = @import("Context.zig");
const Scope = @import("Scope.zig");
const Walker = @import("walk.zig").Walker;
const Item = @import("walk.zig").Item;

/// Signatures longer than this put one parameter per line.
const line_width = 90;

/// Write an item's signature the way users write it, or return `null` for items without one.
pub fn render(walker: *Walker, item: Item) !?[]const u8 {
    const ref = item.ref orelse return null;
    var printer: Printer = .{ .walker = walker, .out = .init(walker.context.arena) };
    const tree = &ref.scope.source.tree;

    switch (item.kind) {
        .function, .type_function => return try printer.function(ref, item.name),
        .field => {
            const field = tree.fullContainerField(ref.decl.node).?;
            try printer.write(item.name);
            try printer.write(": ");
            try printer.node(ref.scope, field.ast.type_expr.unwrap().?);
            if (field.ast.value_expr.unwrap()) |value| {
                try printer.write(" = ");
                try printer.node(ref.scope, value);
            }
        },
        .constant => {
            const var_decl = tree.fullVarDecl(ref.decl.node).?;
            try printer.write("const ");
            try printer.write(item.name);
            if (var_decl.ast.type_node.unwrap()) |type_node| {
                try printer.write(": ");
                try printer.node(ref.scope, type_node);
            } else if (var_decl.ast.init_node.unwrap()) |init| {
                switch (tree.nodeTag(init)) {
                    .string_literal, .number_literal, .error_set_decl => {
                        try printer.write(" = ");
                        try printer.node(ref.scope, init);
                    },
                    else => {},
                }
            }
        },
        else => return null,
    }
    return printer.out.written();
}

const Printer = struct {
    walker: *Walker,
    out: std.Io.Writer.Allocating,
    /// Alias expansion depth, used to detect cycles.
    depth: usize = 0,

    fn write(self: *Printer, text: []const u8) !void {
        try self.out.writer.writeAll(text);
    }

    fn function(self: *Printer, ref: Scope.Ref, name: []const u8) ![]const u8 {
        const arena = self.walker.context.arena;
        const tree = &ref.scope.source.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, ref.decl.node).?;

        var params: std.ArrayList([]const u8) = .empty;
        var iterator = proto.iterate(tree);
        while (iterator.next()) |param| {
            var part: Printer = .{ .walker = self.walker, .out = .init(arena) };
            if (param.comptime_noalias) |token| try part.print("{s} ", .{tree.tokenSlice(token)});
            try part.print("{s}: ", .{tree.tokenSlice(param.name_token.?)});
            if (param.type_expr) |type_expr| {
                try part.node(ref.scope, type_expr);
            } else {
                try part.write(tree.tokenSlice(param.anytype_ellipsis3.?));
            }
            try params.append(arena, part.out.written());
        }

        var result: Printer = .{ .walker = self.walker, .out = .init(arena) };
        if (proto.ast.callconv_expr.unwrap()) |calling_convention| {
            try result.write("callconv(");
            try result.node(ref.scope, calling_convention);
            try result.write(") ");
        }
        const returned = proto.ast.return_type.unwrap().?;
        if (tree.tokenTag(tree.firstToken(returned) - 1) == .bang) try result.write("!");
        try result.node(ref.scope, returned);
        const tail = result.out.written();

        const one_line = try std.fmt.allocPrint(arena, "fn {s}({s}) {s}", .{ name, try std.mem.join(arena, ", ", params.items), tail });
        if (one_line.len <= line_width or params.items.len == 0) return one_line;

        var lines: std.ArrayList(u8) = .empty;
        try lines.print(arena, "fn {s}(\n", .{name});
        for (params.items) |param| try lines.print(arena, "    {s},\n", .{param});
        try lines.print(arena, ") {s}", .{tail});
        return lines.items;
    }

    fn print(self: *Printer, comptime format: []const u8, args: anytype) !void {
        try self.out.writer.print(format, args);
    }

    /// Write a type expression, naming declarations by their public names and choosing comptime branches.
    fn node(self: *Printer, scope: *Scope, expression: Ast.Node.Index) anyerror!void {
        const tree = &scope.source.tree;
        if (tree.fullIf(expression)) |branches| {
            if (branches.ast.else_expr.unwrap()) |else_expr| {
                if (try self.walker.context.evalBool(scope, branches.ast.cond_expr)) |known| {
                    return self.node(scope, if (known) branches.ast.then_expr else else_expr);
                }
            }
        }
        try self.tokens(scope, tree.firstToken(expression), tree.lastToken(expression));
    }

    fn tokens(self: *Printer, scope: *Scope, first: Ast.TokenIndex, last: Ast.TokenIndex) !void {
        const tree = &scope.source.tree;
        var token = first;
        var previous: ?Ast.TokenIndex = null;
        while (token <= last) {
            if (tree.tokenTag(token) == .comma and token + 1 <= last and isClosing(tree.tokenTag(token + 1)) and
                !tree.tokensOnSameLine(token, token + 1))
            {
                token += 1;
                continue;
            }
            if (previous) |before| {
                if (spaced(tree, before, token)) try self.write(" ");
            }

            if (tree.tokenTag(token) == .identifier and !isName(tree, token, first)) {
                if (try self.chain(scope, token, last)) |end| {
                    previous = end;
                    token = end + 1;
                    continue;
                }
            }
            if (tree.tokenTag(token) == .builtin and std.mem.eql(u8, tree.tokenSlice(token), "@This") and token + 2 <= last) {
                if (scope.innermost().display) |display| {
                    try self.write(display);
                    previous = token + 2;
                    token += 3;
                    continue;
                }
            }
            try self.write(tree.tokenSlice(token));
            previous = token;
            token += 1;
        }
    }

    fn chain(self: *Printer, scope: *Scope, first: Ast.TokenIndex, last: Ast.TokenIndex) !?Ast.TokenIndex {
        const tree = &scope.source.tree;
        const context = self.walker.context;
        var value = scope.lookup(tree.tokenSlice(first)) orelse return null;
        var best: ?struct { text: []const u8, end: Ast.TokenIndex } = null;
        var end = first;
        while (true) {
            if (try self.publicName(value)) |text| best = .{ .text = text, .end = end };
            if (end + 2 > last or tree.tokenTag(end + 1) != .period or tree.tokenTag(end + 2) != .identifier) break;

            end += 2;
            value = try context.member(value, tree.tokenSlice(end)) orelse break;
        }
        const found = best orelse return null;
        try self.write(found.text);
        return found.end;
    }

    fn publicName(self: *Printer, value: Scope.Value) anyerror!?[]const u8 {
        const context = self.walker.context;
        switch (value) {
            .decl => |ref| {
                if (self.walker.names.get(.{ .scope = ref.scope, .node = ref.decl.node })) |public| return public;
                if (ref.decl.kind != .variable or self.depth > 8) return null;

                const target = try context.deref(ref);
                switch (target) {
                    .decl, .container, .module, .unbound => return self.publicName(target),
                    else => {},
                }
                // Inline private aliases of types, such as `const Pointer = if (writable) *T else *const T;`.
                const init = ref.scope.source.tree.fullVarDecl(ref.decl.node).?.ast.init_node.unwrap() orelse return null;
                var inner: Printer = .{ .walker = self.walker, .out = .init(context.arena), .depth = self.depth + 1 };
                try inner.node(ref.scope, init);
                return inner.out.written();
            },
            .container => |container| return container.display,
            .module => |module| return if (std.mem.eql(u8, module, "python")) "py.c" else null,
            .unbound => |parameter| return parameter,
            .expr => |expr| {
                var inner: Printer = .{ .walker = self.walker, .out = .init(context.arena), .depth = self.depth + 1 };
                try inner.node(expr.scope, expr.node);
                return inner.out.written();
            },
            else => return null,
        }
    }
};

fn isName(tree: *const Ast, token: Ast.TokenIndex, first: Ast.TokenIndex) bool {
    if (token > first and tree.tokenTag(token - 1) == .period) return true;
    if (token >= first + 2 and tree.tokenTag(token - 1) == .asterisk and tree.tokenTag(token - 2) == .l_bracket) return true;
    return tree.tokenTag(token + 1) == .colon;
}

fn isClosing(tag: std.zig.Token.Tag) bool {
    return tag == .r_paren or tag == .r_brace or tag == .r_bracket;
}

fn spaced(tree: *const Ast, before: Ast.TokenIndex, token: Ast.TokenIndex) bool {
    const before_tag = tree.tokenTag(before);
    const tag = tree.tokenTag(token);
    if (before_tag == .l_paren or before_tag == .l_bracket or tag == .r_paren or tag == .r_bracket or tag == .comma) {
        return false;
    }
    const end = tree.tokenStart(before) + tree.tokenSlice(before).len;
    return tree.tokenStart(token) > end;
}
