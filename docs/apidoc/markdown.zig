const std = @import("std");

const config = @import("config.zig");
const signature = @import("signature.zig");
const walk = @import("walk.zig");
const Item = walk.Item;
const Walker = walk.Walker;

/// Generated pages and API links indexed by names without parameters.
pub const Output = struct {
    /// File names in the pages directory and their contents.
    pages: std.ArrayList(Page) = .empty,
    links: std.ArrayList(Link) = .empty,

    pub const Page = struct { name: []const u8, text: []const u8 };
    pub const Link = struct { name: []const u8, url: []const u8 };
};

/// Write the overview and one page per entry of `config.pages`.
pub fn write(walker: *Walker, items: std.StringHashMapUnmanaged(Item)) !Output {
    const arena = walker.context.arena;
    var output: Output = .{};
    var overview: std.ArrayList(u8) = .empty;
    try frontMatter(arena, &overview, "API reference", "Overview", "Every declaration of the ZyPy Zig library and build helpers.", 0);
    try overview.appendSlice(arena, overview_intro);

    for (config.pages, 1..) |page, order| {
        const url = try std.fmt.allocPrint(arena, "/api/{s}/", .{page.slug});
        var text: std.ArrayList(u8) = .empty;
        try frontMatter(arena, &text, page.title, page.title, page.description, order);
        try text.appendSlice(arena, "<div class=\"api-page\">\n\n");
        try overview.print(arena, "\n## {s}\n\n| Declaration | Description |\n| --- | --- |\n", .{page.title});

        for (page.items) |name| {
            const item = items.get(name).?;
            try section(walker, &output, &text, item, 2, url, &.{});
            const target = item.url orelse try std.fmt.allocPrint(arena, "{s}#{s}", .{ url, try slug(arena, item.heading) });
            try overview.print(arena, "| [`{s}`]({s}) | {s} |\n", .{ item.heading, target, try summary(arena, item.doc) });
        }
        try text.appendSlice(arena, "</div>\n");
        try output.pages.append(arena, .{ .name = try std.fmt.allocPrint(arena, "{s}.md", .{page.slug}), .text = text.items });
    }
    try output.pages.append(arena, .{ .name = "index.md", .text = overview.items });
    return output;
}

/// Write the link index as JSON: `{ "py.List.get": "/api/objects/#pylistget", ... }`.
pub fn linkIndex(arena: std.mem.Allocator, links: []const Output.Link) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "{\n");
    for (links, 0..) |link, i| {
        try text.print(arena, "  \"{s}\": \"{s}\"{s}\n", .{ link.name, link.url, if (i + 1 < links.len) "," else "" });
    }
    try text.appendSlice(arena, "}\n");
    return text.items;
}

const overview_intro =
    \\The reference lists every public declaration of the Zig library and of the build helpers, with the doc comments from ZyPy's sources. Zig code imports the library as `py`, and `build.zig` imports the build helpers as `zypy`:
    \\
    \\```zig
    \\const py = @import("zypy"); // in the extension's Zig code
    \\const zypy = @import("zypy"); // in build.zig
    \\```
    \\
    \\Signatures show types the way your code names them, such as `py.Error` and `py.List`.
    \\
;

fn frontMatter(
    arena: std.mem.Allocator,
    text: *std.ArrayList(u8),
    title: []const u8,
    label: []const u8,
    description: []const u8,
    order: usize,
) !void {
    try text.print(arena,
        \\---
        \\title: "{s}"
        \\description: "{s}"
        \\editUrl: false
        \\sidebar:
        \\  label: "{s}"
        \\  order: {d}
        \\tableOfContents:
        \\  maxHeadingLevel: 2
        \\---
        \\
        \\
    , .{ title, description, label, order });
}

fn section(
    walker: *Walker,
    output: *Output,
    text: *std.ArrayList(u8),
    item: Item,
    level: usize,
    page_url: []const u8,
    siblings: []const Item,
) !void {
    const arena = walker.context.arena;
    const anchor = try slug(arena, item.heading);
    const url = item.url orelse try std.fmt.allocPrint(arena, "{s}#{s}", .{ page_url, anchor });
    try output.links.append(arena, .{ .name = try walk.normalize(arena, item.heading), .url = url });

    try text.appendNTimes(arena, '#', @min(level, 4));
    try text.print(arena, " `{s}`\n\n", .{item.heading});
    if (try signature.render(walker, item)) |code| try text.print(arena, "```zig frame=\"none\" wrap\n{s}\n```\n\n", .{code});

    try text.appendSlice(arena, try docText(arena, item.doc, siblings, item.name));
    try text.appendSlice(arena, "\n\n");
    if (item.url) |external| {
        try text.print(arena, "<p class=\"api-source\"><a href=\"{s}\">CPython C API reference</a></p>\n\n", .{external});
    } else if (item.line == 0) {
        try text.print(arena, "<p class=\"api-source\"><a href=\"{s}{s}\">{s}</a></p>\n\n", .{ config.repository, item.path, item.path });
    } else {
        try text.print(arena, "<p class=\"api-source\"><a href=\"{s}{s}#L{d}\">{s}:{d}</a></p>\n\n", .{
            config.repository, item.path, item.line, item.path, item.line,
        });
    }

    for (item.members) |member| try section(walker, output, text, member, level + 1, page_url, item.members);
}

fn docText(arena: std.mem.Allocator, doc: []const u8, siblings: []const Item, own_name: []const u8) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < doc.len) : (i += 1) {
        const char = doc[i];
        if (char == '`') {
            const end = std.mem.indexOfScalarPos(u8, doc, i + 1, '`') orelse doc.len;
            const code = doc[i + 1 .. @min(end, doc.len)];
            if (sibling(siblings, code, own_name)) |target| {
                try text.print(arena, "[`{s}`](#{s})", .{ code, try slug(arena, target.heading) });
            } else {
                try text.print(arena, "`{s}`", .{code});
            }
            i = end;
            continue;
        }
        switch (char) {
            '<' => try text.appendSlice(arena, "&lt;"),
            '*', '_' => try text.appendSlice(arena, &.{ '\\', char }),
            else => try text.append(arena, char),
        }
    }
    return text.items;
}

// Only functions and types: a field's name is often a parameter's name too.
fn sibling(siblings: []const Item, code: []const u8, own_name: []const u8) ?Item {
    if (std.mem.eql(u8, code, own_name)) return null;
    for (siblings) |candidate| {
        if (candidate.kind == .field or candidate.kind == .constant) continue;
        if (std.mem.eql(u8, candidate.name, code)) return candidate;
    }
    return null;
}

fn summary(arena: std.mem.Allocator, doc: []const u8) ![]const u8 {
    const paragraph = doc[0 .. std.mem.indexOf(u8, doc, "\n\n") orelse doc.len];
    var end: usize = paragraph.len;
    var in_code = false;
    for (paragraph, 0..) |char, i| {
        if (char == '`') in_code = !in_code;
        if (char == '.' and !in_code and (i + 1 == paragraph.len or paragraph[i + 1] == ' ' or paragraph[i + 1] == '\n')) {
            end = i + 1;
            break;
        }
    }
    const sentence = try std.mem.replaceOwned(u8, arena, paragraph[0..end], "\n", " ");
    return std.mem.replaceOwned(u8, arena, try docText(arena, sentence, &.{}, ""), "|", "\\|");
}

/// Get the Starlight heading anchor: lowercase, without punctuation, and with spaces replaced by hyphens.
pub fn slug(arena: std.mem.Allocator, heading: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (heading) |char| switch (char) {
        'A'...'Z' => try result.append(arena, char + ('a' - 'A')),
        'a'...'z', '0'...'9', '_', '-' => try result.append(arena, char),
        ' ' => try result.append(arena, '-'),
        else => {},
    };
    return result.items;
}
