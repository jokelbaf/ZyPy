const std = @import("std");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) std.process.fatal("usage: download URL SHA256 OUTPUT", .{});
    const url, const sha256, const output = .{ args[1], args[2], args[3] };

    var cache = try Io.Dir.cwd().createDirPathOpen(io, try cachePath(arena, init.environ_map), .{});
    defer cache.close(io);
    const archive = try std.fmt.allocPrint(arena, "{s}.tar.gz", .{sha256});

    if (!try matches(io, cache, archive, sha256)) {
        download(init, cache, archive, url) catch |err| switch (err) {
            error.DownloadFailed => std.process.exit(1),
            else => |other| return other,
        };
        if (!try matches(io, cache, archive, sha256)) {
            cache.deleteFile(io, archive) catch {};
            std.process.fatal("{s} doesn't have the SHA-256 {s}", .{ url, sha256 });
        }
    }

    var directory = try Io.Dir.cwd().createDirPathOpen(io, output, .{});
    defer directory.close(io);
    try unpack(arena, io, cache, archive, directory);
}

fn cachePath(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    const zig_cache = std.zig.resolveGlobalCacheDir(arena, environ) catch |err| switch (err) {
        error.AppDataDirUnavailable => std.process.fatal("can't find Zig's cache: set ZIG_GLOBAL_CACHE_DIR", .{}),
        else => |other| return other,
    };
    return std.fs.path.join(arena, &.{ zig_cache, "zypy", "python" });
}

fn matches(io: Io, cache: Io.Dir, archive: []const u8, sha256: []const u8) !bool {
    var file = cache.openFile(io, archive, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        hash.update(chunk);
        reader.interface.toss(chunk.len);
    }

    const digest = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return std.ascii.eqlIgnoreCase(&digest, sha256);
}

fn download(init: std.process.Init, cache: Io.Dir, archive: []const u8, url: []const u8) !void {
    const io = init.io;
    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);

    // Use a temporary file so concurrent builds cannot read a partial archive.
    var file = try cache.createFileAtomic(io, archive, .{ .replace = true });
    defer file.deinit(io);

    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.file.writer(io, &buffer);
    const result = client.fetch(.{ .location = .{ .url = url }, .response_writer = &writer.interface }) catch |err| {
        std.log.err("can't download {s}: {t}", .{ url, err });
        return error.DownloadFailed;
    };
    if (result.status != .ok) {
        std.log.err("can't download {s}: HTTP {d}", .{ url, @backingInt(result.status) });
        return error.DownloadFailed;
    }

    try writer.interface.flush();
    try file.replace(io);
}

fn unpack(arena: std.mem.Allocator, io: Io, cache: Io.Dir, archive: []const u8, directory: Io.Dir) !void {
    var file = try cache.openFile(io, archive, .{});
    defer file.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&reader.interface, .gzip, &window);
    var diagnostics: std.tar.Diagnostics = .{ .allocator = arena };
    try std.tar.extract(io, directory, &decompress.reader, .{ .strip_components = 1, .diagnostics = &diagnostics });

    var links: std.ArrayList(Link) = .empty;
    for (diagnostics.errors.items) |item| switch (item) {
        // The Linux archives' share/terminfo has names that differ only in case: keep the first one.
        .unable_to_create_file => |info| if (!exists(io, directory, info.file_name)) {
            std.process.fatal("can't create {s}: {t}", .{ info.file_name, info.code });
        },
        .unable_to_create_sym_link => |info| switch (info.code) {
            error.PathAlreadyExists => {},
            // Windows creates links only with Developer Mode or an administrator's rights.
            else => try links.append(arena, .{ .path = info.file_name, .target = info.link_name }),
        },
        .unsupported_file_type => |info| std.process.fatal("{s} has the unsupported tar type {t}", .{
            info.file_name,
            info.file_type,
        }),
        .components_outside_stripped_prefix => |info| std.process.fatal("{s} is outside the archive's directory", .{
            info.file_name,
        }),
    };
    try copyLinks(arena, io, directory, links.items);
}

const Link = struct { path: []const u8, target: []const u8 };

fn exists(io: Io, directory: Io.Dir, path: []const u8) bool {
    _ = directory.statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// Replace each link that couldn't be created with a copy of its target. A target can be another such link, so
/// copy in rounds until a round copies nothing. Links to nothing are left out.
fn copyLinks(arena: std.mem.Allocator, io: Io, directory: Io.Dir, links: []Link) !void {
    // On Windows, a link that failed leaves an empty file behind, which mustn't pass for its target.
    for (links) |link| directory.deleteFile(io, link.path) catch {};

    var pending = links;
    while (pending.len > 0) {
        var left: usize = 0;
        for (pending) |link| {
            const target = try std.fs.path.resolveAllocPosix(arena, &.{
                std.fs.path.dirnamePosix(link.path) orelse ".",
                link.target,
            });
            const outside = std.mem.eql(u8, target, "..") or std.mem.startsWith(u8, target, "../");
            if (outside or std.fs.path.isAbsolutePosix(target)) {
                std.process.fatal("{s} links to {s}, outside the archive's directory", .{ link.path, link.target });
            }

            directory.copyFile(target, directory, link.path, io, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    pending[left] = link;
                    left += 1;
                },
                else => std.process.fatal("can't copy {s} to {s}: {t}", .{ target, link.path, err }),
            };
        }

        if (left == pending.len) return;
        pending = pending[0..left];
    }
}

test "links that couldn't be created become copies of their targets" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "share/a");
    try tmp.dir.createDirPath(io, "share/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/python3.14", .data = "python" });
    try tmp.dir.writeFile(io, .{ .sub_path = "share/a/term", .data = "term" });
    // The empty files that failed links leave on Windows.
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/python3", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "share/b/dangling", .data = "" });

    var links = [_]Link{
        .{ .path = "bin/python", .target = "python3" },
        .{ .path = "bin/python3", .target = "python3.14" },
        .{ .path = "share/b/term", .target = "../a/term" },
        .{ .path = "share/b/dangling", .target = "missing" },
    };
    try copyLinks(arena.allocator(), io, tmp.dir, &links);

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("python", try tmp.dir.readFile(io, "bin/python", &buffer));
    try std.testing.expectEqualStrings("python", try tmp.dir.readFile(io, "bin/python3", &buffer));
    try std.testing.expectEqualStrings("term", try tmp.dir.readFile(io, "share/b/term", &buffer));
    try std.testing.expect(!exists(io, tmp.dir, "share/b/dangling"));
}
