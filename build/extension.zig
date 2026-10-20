const std = @import("std");

const zypy = @import("../build.zig");
const module = @import("module.zig");
const Python = @import("Python.zig");

/// Options for `zypy.addExtension`.
pub const Options = struct {
    /// The module name Python imports, which may be dotted, such as `"mypkg._core"`.
    name: []const u8,
    /// The root Zig file, which exports the module with `py.exportModule`.
    root_source_file: std.Build.LazyPath,
    /// The target to build for, usually `b.standardTargetOptions(.{})`.
    target: std.Build.ResolvedTarget,
    /// The optimize mode, usually `b.standardOptimizeOption(.{})`.
    optimize: std.lang.Optimize,
    /// Strip debug info. Defaults to true for release builds.
    strip: ?bool = null,
    /// The Python installation to build against. Defaults to `zypy.findPython`.
    python: ?Python = null,
    /// Build for the stable ABI (abi3) of this Python version and later ones, such as `"3.13"`.
    /// Defaults to `-Dabi3`, which the build backend sets from pyproject.toml.
    abi3: ?[]const u8 = null,
    /// Generate and install type stubs (`.pyi`) next to the extension.
    /// Requires `pub const module = py.module(...)` in the root file and a target this machine can run.
    stubs: bool = true,
};

/// Build a Python extension module and install it into `python/` under the install prefix.
pub fn add(b: *std.Build, options: Options) *std.Build.Step.Compile {
    const python = options.python orelse Python.find(b);
    checkModuleName(options.name);
    const abi3 = options.abi3 orelse module.stableAbiOption(b);

    const root = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .strip = options.strip orelse (options.optimize != .debug),
    });
    root.addImport("zypy", module.add(b, .{
        .target = options.target,
        .optimize = options.optimize,
        .python = python,
        .extension = options.name,
        .abi3 = abi3,
    }));

    const short_name = if (std.mem.lastIndexOfScalar(u8, options.name, '.')) |dot| options.name[dot + 1 ..] else options.name;
    const lib = b.addLibrary(.{ .name = short_name, .linkage = .dynamic, .root_module = root });
    // The Python that imports the extension provides the C API.
    lib.linker_allow_shlib_undefined = true;

    const dest = b.fmt("{s}{s}", .{ options.name, if (abi3 != null) ".abi3.so" else python.ext_suffix });
    std.mem.replaceScalar(u8, dest[0..options.name.len], '.', '/');
    const install = b.addInstallFileWithDir(lib.getEmittedBin(), .{ .custom = "python" }, dest);
    b.getInstallStep().dependOn(&install.step);
    if (options.stubs) addStubs(b, lib, short_name, options.target);

    return lib;
}

fn addStubs(b: *std.Build, lib: *std.Build.Step.Compile, name: []const u8, target: std.Build.ResolvedTarget) void {
    const host = b.graph.host.result;
    const executor = std.zig.system.getExternalExecutor(b.graph.io, &target.result, .{
        .host_cpu_arch = host.cpu.arch,
        .host_os_tag = host.os.tag,
        // Zig links musl programs statically.
        .link_mode = if (target.result.abi.isMusl()) .static else .dynamic,
        .link_libc = true,
    });
    if (executor != .native) return;

    const package = b.dependencyFromBuildZig(zypy, .{});
    const root = b.createModule(.{
        .root_source_file = package.path("build/stubs.zig"),
        .target = target,
        .optimize = lib.root_module.optimize,
        .link_libc = true,
    });
    root.addImport("zypy", lib.root_module.import_table.get("zypy").?);
    root.addImport("extension", lib.root_module);

    const generator = b.addExecutable(.{ .name = b.fmt("{s}-stubs", .{name}), .root_module = root });
    const run = b.addRunArtifact(generator);
    const stubs = run.addOutputDirectoryArg("stubs");
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = stubs,
        .install_dir = .{ .custom = "python" },
        .install_subdir = "",
    }).step);
}

fn checkModuleName(name: []const u8) void {
    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |part| {
        if (!isIdentifier(part)) std.process.fatal("invalid Python module name: '{s}'", .{name});
    }
}

fn isIdentifier(text: []const u8) bool {
    if (text.len == 0 or std.ascii.isDigit(text[0])) return false;
    for (text) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    }
    return true;
}
