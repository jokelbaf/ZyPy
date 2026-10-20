const std = @import("std");

const zypy = @import("../build.zig");
const Python = @import("Python.zig");
const State = @import("State.zig");

/// The version of the Python that `bundledPython` provides.
pub const version = "3.14";

const release = "20261013";
const full_version = "3.14.8";

const Platform = struct {
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,
    abi: std.Target.Abi,
    triple: []const u8,
    sha256: []const u8,
    ext_suffix: []const u8,
};

const platforms = [_]Platform{
    .{ .arch = .x86_64, .os = .linux, .abi = .gnu, .triple = "x86_64-unknown-linux-gnu", .sha256 = "d8faa1b588506b9e3e5a3f57807bb056d534a1641a6b10d15b6ea3f0b413b960", .ext_suffix = ".cpython-314-x86_64-linux-gnu.so" },
    .{ .arch = .aarch64, .os = .linux, .abi = .gnu, .triple = "aarch64-unknown-linux-gnu", .sha256 = "d8ae14f303d3971431184cf423ae5467202de2bc19bf6491a490250b87647d4b", .ext_suffix = ".cpython-314-aarch64-linux-gnu.so" },
    .{ .arch = .arm, .os = .linux, .abi = .gnueabihf, .triple = "armv7-unknown-linux-gnueabihf", .sha256 = "e110679c0b93ad5ebe2af32288a7c8240514442049b7b06510496a866b835189", .ext_suffix = ".cpython-314-arm-linux-gnueabihf.so" },
    .{ .arch = .powerpc64le, .os = .linux, .abi = .gnu, .triple = "ppc64le-unknown-linux-gnu", .sha256 = "aca672050e22b2b14099cc25ac10fc507aa5e10b6d6eb1bb8601685e2c50b3b2", .ext_suffix = ".cpython-314-powerpc64le-linux-gnu.so" },
    .{ .arch = .riscv64, .os = .linux, .abi = .gnu, .triple = "riscv64-unknown-linux-gnu", .sha256 = "19357f1d0acf942e04c6994ec56b1ff1c7fa2c8406ad3d6437c1dff128e5cb77", .ext_suffix = ".cpython-314-riscv64-linux-gnu.so" },
    .{ .arch = .s390x, .os = .linux, .abi = .gnu, .triple = "s390x-unknown-linux-gnu", .sha256 = "f5bad0228cfd6d5c9825c403b7ed11e234efa0e12c82e17b764a09ec7f206c18", .ext_suffix = ".cpython-314-s390x-linux-gnu.so" },
    .{ .arch = .x86_64, .os = .linux, .abi = .musl, .triple = "x86_64-unknown-linux-musl", .sha256 = "6ee5218694c3ddf1098aa306bb01b621d14c0bca4134b317614d9daa99f16ba2", .ext_suffix = ".cpython-314-x86_64-linux-musl.so" },
    .{ .arch = .aarch64, .os = .linux, .abi = .musl, .triple = "aarch64-unknown-linux-musl", .sha256 = "7b6714675192dc381e14de4f2615c73d8ce5c15775562f4843282c34c3df8b6c", .ext_suffix = ".cpython-314-aarch64-linux-musl.so" },
    .{ .arch = .x86_64, .os = .macos, .abi = .none, .triple = "x86_64-apple-darwin", .sha256 = "f0137337ecf6234b30c9c955219dae2d71e1a00387c4d204d6c6929e24bf9a90", .ext_suffix = ".cpython-314-darwin.so" },
    .{ .arch = .aarch64, .os = .macos, .abi = .none, .triple = "aarch64-apple-darwin", .sha256 = "994adadc202c5df0b4570192cc9a70e3f2c131e512f4a125c56efa8562f44b28", .ext_suffix = ".cpython-314-darwin.so" },
};

/// Get Python for `target` from python-build-standalone. Reuse the cached download when available.
/// Use `.bundle_python` to ship it with a program, or `.python` to build extensions for it.
pub fn python(b: *std.Build, target: std.Build.ResolvedTarget) Python {
    const result = target.result;
    const state = State.of(b);
    for (state.bundled.items) |entry| {
        if (entry.arch == result.cpu.arch and entry.os == result.os.tag and entry.abi == result.abi) return entry.python;
    }

    const platform = platformOf(result) orelse unsupported(b, result);

    const download = b.addRunArtifact(downloader(b));
    download.setName(b.fmt("download Python {s} for {s}", .{ full_version, platform.triple }));
    download.addArgs(&.{ b.fmt(
        "https://github.com/astral-sh/python-build-standalone/releases/download/{s}/cpython-{s}%2B{s}-{s}-install_only_stripped.tar.gz",
        .{ release, full_version, release, platform.triple },
    ), platform.sha256 });

    const bundled: Python = .{
        .executable = "",
        .version = version,
        .include_dir = "",
        .ext_suffix = platform.ext_suffix,
        .lib_dir = "",
        .lib_name = "python" ++ version,
        .shared = true,
        .bundle = download.addOutputDirectoryArg("python"),
    };
    state.bundled.append(b.graph.arena, .{
        .arch = result.cpu.arch,
        .os = result.os.tag,
        .abi = result.abi,
        .python = bundled,
    }) catch @panic("OOM");
    return bundled;
}

fn platformOf(target: std.Target) ?Platform {
    for (platforms) |platform| {
        if (platform.arch == target.cpu.arch and platform.os == target.os.tag and platform.abi == target.abi) return platform;
    }
    return null;
}

fn unsupported(b: *std.Build, target: std.Target) noreturn {
    var supported: std.ArrayList(u8) = .empty;
    for (platforms, 0..) |platform, i| {
        supported.appendSlice(b.graph.arena, if (i == 0) "" else ", ") catch @panic("OOM");
        supported.appendSlice(b.graph.arena, triple(b, platform.arch, platform.os, platform.abi)) catch @panic("OOM");
    }
    std.process.fatal("ZyPy has no Python to bundle for {s} (supported: {s})", .{
        triple(b, target.cpu.arch, target.os.tag, target.abi), supported.items,
    });
}

fn triple(b: *std.Build, arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag, abi: std.Target.Abi) []const u8 {
    if (abi == .none) return b.fmt("{t}-{t}", .{ arch, os });
    return b.fmt("{t}-{t}-{t}", .{ arch, os, abi });
}

fn downloader(b: *std.Build) *std.Build.Step.Compile {
    const state = State.of(b);
    if (state.downloader) |program| return program;

    const package = b.dependencyFromBuildZig(zypy, .{});
    const program = b.addExecutable(.{ .name = "zypy-download", .root_module = b.createModule(.{
        .root_source_file = package.path("build/download.zig"),
        .target = b.graph.host,
        .optimize = .fast,
    }) });
    state.downloader = program;
    return program;
}
