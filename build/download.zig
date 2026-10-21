const std = @import("std");
const builtin = @import("builtin");

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
    try unpack(io, cache, archive, directory);
}

fn cachePath(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("ZIG_GLOBAL_CACHE_DIR")) |zig_cache| return std.fs.path.join(arena, &.{ zig_cache, "zypy", "python" });
    if (environ.get("XDG_CACHE_HOME")) |cache| return std.fs.path.join(arena, &.{ cache, "zig", "zypy", "python" });

    const home = environ.get("HOME") orelse std.process.fatal("can't find Zig's cache: HOME isn't set", .{});
    const caches = if (builtin.os.tag.isDarwin()) "Library/Caches" else ".cache";
    return std.fs.path.join(arena, &.{ home, caches, "zig", "zypy", "python" });
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

fn unpack(io: Io, cache: Io.Dir, archive: []const u8, directory: Io.Dir) !void {
    var file = try cache.openFile(io, archive, .{});
    defer file.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&reader.interface, .gzip, &window);
    try std.tar.extract(io, directory, &decompress.reader, .{ .strip_components = 1 });
}
