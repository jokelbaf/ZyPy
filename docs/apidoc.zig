const std = @import("std");

const config = @import("apidoc/config.zig");
const Context = @import("apidoc/Context.zig");
const markdown = @import("apidoc/markdown.zig");
const walk = @import("apidoc/walk.zig");

/// Generate API pages and a link index from ZyPy's doc comments. Fail if public documentation is missing.
/// Run with `zig run apidoc.zig -- <repository> <pages directory> <link index>`.
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.log.err("usage: apidoc <repository> <pages directory> <link index>", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();

    var root = try cwd.openDir(io, args[1], .{});
    defer root.close(io);

    const output = generate(arena, io, root) catch |err| switch (err) {
        error.MissingDocs => std.process.exit(1),
        else => return err,
    };

    try cwd.deleteTree(io, args[2]);
    try cwd.createDirPath(io, args[2]);

    var pages = try cwd.openDir(io, args[2], .{});
    defer pages.close(io);

    for (output.pages.items) |page| try pages.writeFile(io, .{ .sub_path = page.name, .data = page.text });
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = try markdown.linkIndex(arena, output.links.items) });
}

/// Render API pages for `root`. Report missing doc comments and return `error.MissingDocs`.
pub fn generate(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !markdown.Output {
    var context: Context = .{ .arena = arena, .io = io, .root = root };
    var walker: walk.Walker = .{ .context = &context };
    var items: std.StringHashMapUnmanaged(walk.Item) = .empty;
    for (config.roots) |file| {
        for (try walker.walkRoot(file)) |item| try items.put(arena, try walk.normalize(arena, item.heading), item);
    }

    try checkPages(&walker, items);
    if (walker.problems.items.len > 0) {
        for (walker.problems.items) |problem| std.log.err("{s}", .{problem});
        std.log.err("add doc comments to the declarations above, or list internal fields in docs/apidoc/config.zig", .{});
        return error.MissingDocs;
    }
    return markdown.write(&walker, items);
}

// Require every public declaration on one page so new API entries cannot be overlooked.
fn checkPages(walker: *walk.Walker, items: std.StringHashMapUnmanaged(walk.Item)) !void {
    const arena = walker.context.arena;
    var listed: std.StringHashMapUnmanaged(void) = .empty;
    for (config.pages) |page| {
        for (page.items) |name| {
            if (!items.contains(name)) {
                try walker.problems.append(arena, try std.fmt.allocPrint(arena, "config.zig: page '{s}' lists {s}, which isn't public", .{ page.slug, name }));
            }
            if ((try listed.getOrPut(arena, name)).found_existing) {
                try walker.problems.append(arena, try std.fmt.allocPrint(arena, "config.zig: {s} is on two pages", .{name}));
            }
        }
    }

    var names = items.keyIterator();
    while (names.next()) |name| {
        if (!listed.contains(name.*)) {
            try walker.problems.append(arena, try std.fmt.allocPrint(arena, "config.zig: add {s} to a page", .{name.*}));
        }
    }
}

// The tests read the repository, so run them from its root: `zig test docs/apidoc.zig`.
const Generated = struct {
    arena: std.heap.ArenaAllocator,
    output: markdown.Output,

    fn init() !Generated {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        errdefer arena.deinit();

        const output = try generate(arena.allocator(), std.testing.io, std.Io.Dir.cwd());
        return .{ .arena = arena, .output = output };
    }

    fn deinit(self: *Generated) void {
        self.arena.deinit();
    }

    fn page(self: *const Generated, name: []const u8) []const u8 {
        for (self.output.pages.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.text;
        }
        return "";
    }

    fn link(self: *const Generated, name: []const u8) ?[]const u8 {
        for (self.output.links.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.url;
        }
        return null;
    }
};

test "signatures name types the way user code does" {
    var generated: Generated = try .init();
    defer generated.deinit();

    const objects = generated.page("objects.md");
    try std.testing.expect(std.mem.indexOf(u8, objects, "fn get(self: py.List, comptime T: type, index: usize) py.Error!T") != null);
    try std.testing.expect(std.mem.indexOf(u8, objects, "fn own(ptr: ?*py.c.PyObject) py.Error!py.Str") != null);

    const buffers = generated.page("iterables-and-buffers.md");
    try std.testing.expect(std.mem.indexOf(u8, buffers, "fn items(self: *const py.Buffer(T)) []const T") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffers, "fn items(self: *const py.BufferMut(T)) []T") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffers, "py.Error!*T") != null);

    const build = generated.page("build.md");
    try std.testing.expect(std.mem.indexOf(u8, build, "fn addExtension(b: *std.Build, options: zypy.ExtensionOptions) *std.Build.Step.Compile") != null);
}

test "re-exports and generic types document their members" {
    var generated: Generated = try .init();
    defer generated.deinit();

    try std.testing.expectEqualStrings("/api/objects/#pystrdeinit", generated.link("py.Str.deinit").?);
    try std.testing.expectEqualStrings("/api/objects/#pydictiteratork-vnext", generated.link("py.Dict.Iterator.next").?);
    try std.testing.expect(generated.link("py.Set.add") != null);
    try std.testing.expect(generated.link("py.FrozenSet.add") == null);
    try std.testing.expect(generated.link("py.module.init") != null);
}

test "internals and protocol hooks stay out" {
    var generated: Generated = try .init();
    defer generated.deinit();

    try std.testing.expect(generated.link("py.List.fromPython") == null);
    try std.testing.expect(generated.link("py.stubs") == null);
    try std.testing.expect(generated.link("py.module.def") == null);
    try std.testing.expect(generated.link("py.Gil.state") == null);
    try std.testing.expectEqualStrings("https://docs.python.org/3/c-api/index.html", generated.link("py.c").?);
}

test "headings become names and Starlight's anchors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings("py.Dict.Iterator.next", try walk.normalize(arena.allocator(), "py.Dict.Iterator(K, V).next"));
    try std.testing.expectEqualStrings("pydictiteratork-vnext", try markdown.slug(arena.allocator(), "py.Dict.Iterator(K, V).next"));
}
