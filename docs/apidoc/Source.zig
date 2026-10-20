const std = @import("std");
const Ast = std.zig.Ast;

const Source = @This();

/// The path from the repository root, such as "src/types/List.zig".
path: []const u8,
text: [:0]const u8,
tree: Ast,

/// A declaration or field of a container.
pub const Decl = struct {
    node: Ast.Node.Index,
    name: []const u8,
    kind: Kind,
    is_pub: bool,
    /// The first token after the doc comment.
    first_token: Ast.TokenIndex,

    pub const Kind = enum { variable, function, field };
};

/// Read and parse `path`, relative to `root`.
pub fn load(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path: []const u8) !*Source {
    const text = root.readFileAllocOptions(io, path, arena, .limited(1 << 22), .of(u8), 0) catch |err| {
        std.log.err("can't read {s}: {t}", .{ path, err });
        return err;
    };
    const tree = try Ast.parse(arena, text, .{ .mode = .zig });
    if (tree.errors.len > 0) {
        std.log.err("{s} has syntax errors", .{path});
        return error.ParseError;
    }

    const source = try arena.create(Source);
    source.* = .{ .path = path, .text = text, .tree = tree };
    return source;
}

/// Get container members, or file members for `.root`. The result may borrow `buffer`.
pub fn members(self: *const Source, node: Ast.Node.Index, buffer: *[2]Ast.Node.Index) []const Ast.Node.Index {
    if (node == .root) return self.tree.rootDecls();
    return self.tree.fullContainerDecl(buffer, node).?.ast.members;
}

/// Describe a container member, or return `null` for blocks and tests.
pub fn declOf(self: *const Source, node: Ast.Node.Index) ?Decl {
    const tree = &self.tree;
    if (tree.fullVarDecl(node)) |var_decl| {
        return .{
            .node = node,
            .name = tree.tokenSlice(var_decl.ast.mut_token + 1),
            .kind = .variable,
            .is_pub = var_decl.visib_token != null,
            .first_token = var_decl.firstToken(),
        };
    }
    if (tree.nodeTag(node) == .fn_decl) {
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node).?;
        return .{
            .node = node,
            .name = tree.tokenSlice(proto.name_token.?),
            .kind = .function,
            .is_pub = proto.visib_token != null,
            .first_token = proto.firstToken(),
        };
    }
    if (tree.fullContainerField(node)) |field| {
        return .{
            .node = node,
            .name = tree.tokenSlice(field.ast.main_token),
            .kind = .field,
            .is_pub = true,
            .first_token = field.firstToken(),
        };
    }
    return null;
}

/// Find the member named `name` of a container node.
pub fn find(self: *const Source, container: Ast.Node.Index, name: []const u8) ?Decl {
    var buffer: [2]Ast.Node.Index = undefined;
    for (self.members(container, &buffer)) |node| {
        const decl = self.declOf(node) orelse continue;
        if (decl.kind != .field and std.mem.eql(u8, decl.name, name)) return decl;
    }
    return null;
}

/// Get the doc comment above a declaration, without the slashes, or `null` if it has none.
pub fn docComment(self: *const Source, arena: std.mem.Allocator, decl: Decl) !?[]const u8 {
    var start = decl.first_token;
    while (start > 0 and self.tree.tokenTag(start - 1) == .doc_comment) start -= 1;
    if (start == decl.first_token) return null;

    var text: std.ArrayList(u8) = .empty;
    for (start..decl.first_token) |token| {
        const comment = self.tree.tokenSlice(@intCast(token))[3..];
        if (text.items.len > 0) try text.append(arena, '\n');
        try text.appendSlice(arena, if (std.mem.startsWith(u8, comment, " ")) comment[1..] else comment);
    }
    return text.items;
}

/// Get the 1-based line of a token.
pub fn line(self: *const Source, token: Ast.TokenIndex) usize {
    return self.tree.tokenLocation(0, token).line + 1;
}
