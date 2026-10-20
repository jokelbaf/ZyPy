const std = @import("std");
const Translator = @import("translate_c").Translator;

const zypy = @import("../build.zig");
const bundle = @import("bundle.zig");
const Python = @import("Python.zig");
const State = @import("State.zig");

/// Options for `zypy.addModule`.
pub const Options = struct {
    /// The target to build for.
    target: std.Build.ResolvedTarget,
    /// The optimize mode.
    optimize: std.lang.Optimize,
    /// The Python installation to build against. Defaults to `zypy.findPython`.
    python: ?Python = null,
    /// Export the module of the root file as an extension with this name.
    extension: ?[]const u8 = null,
    /// Use only the stable ABI (the limited C API) of this Python version, such as `"3.13"`.
    abi3: ?[]const u8 = null,
};

/// Create the `zypy` Zig module for a custom build setup.
pub fn add(b: *std.Build, options: Options) *std.Build.Module {
    const python = options.python orelse Python.find(b);
    const package = b.dependencyFromBuildZig(zypy, .{});

    const headers: Translator = .init(package.builder.dependency("translate_c", .{}), .{
        .c_source_file = package.path("src/python.h"),
        .target = options.target,
        .optimize = options.optimize,
    });
    headers.addIncludePath(if (python.bundle) |root| root.path(b, "include/python" ++ bundle.version) else .{
        .cwd_relative = python.include_dir,
    });
    const limited_api = if (options.abi3) |version| limitedApi(python, version) else null;
    if (limited_api) |hex| headers.defineCMacro("Py_LIMITED_API", b.fmt("0x{X:0>8}", .{hex}));

    const build_options = b.addOptions();
    build_options.addOption(?[]const u8, "extension", options.extension);
    build_options.addOption(?u32, "limited_api", limited_api);
    build_options.addOption(
        ?[:0]const u8,
        "python",
        if (python.bundle != null) null else b.graph.arena.dupeSentinel(u8, python.executable, 0) catch @panic("OOM"),
    );
    build_options.addOption(bool, "bundled_python", python.bundle != null);

    const module = b.createModule(.{
        .root_source_file = package.path("src/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    module.addImport("python", headers.mod);
    module.addOptions("zypy_options", build_options);
    return module;
}

/// Read `-Dabi3=<version>`, such as `-Dabi3=3.13`.
pub fn stableAbiOption(b: *std.Build) ?[]const u8 {
    const state = State.of(b);
    if (state.abi3) |version| return version;

    const version = b.option([]const u8, "abi3", "Build extensions for the stable ABI of this Python version and later");
    state.abi3 = version;
    return version;
}

fn limitedApi(python: Python, version: []const u8) u32 {
    const abi = parseVersion(version) orelse std.process.fatal("abi3 must be a Python version such as 3.13, not '{s}'", .{version});
    const built = parseVersion(python.version).?;
    if (abi[0] != 3 or abi[1] < 13) std.process.fatal("abi3 must be 3.13 or later, not {s}", .{version});
    if (abi[1] > built[1]) std.process.fatal("abi3 is {s}, but {s} is Python {s}", .{ version, python.executable, python.version });
    if (python.gil_disabled) std.process.fatal("free-threaded Python ({s}) has no stable ABI", .{python.executable});
    return @as(u32, abi[0]) << 24 | @as(u32, abi[1]) << 16;
}

fn parseVersion(text: []const u8) ?[2]u8 {
    var parts = std.mem.splitScalar(u8, text, '.');
    const major = std.fmt.parseInt(u8, parts.next().?, 10) catch return null;
    const minor = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null) return null;
    return .{ major, minor };
}
