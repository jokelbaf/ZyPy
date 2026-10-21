const std = @import("std");

const bundle = @import("bundle.zig");
const module = @import("module.zig");
const Python = @import("Python.zig");
const State = @import("State.zig");

/// Options for `zypy.addExecutable`.
pub const Options = struct {
    /// The program's name.
    name: []const u8,
    /// The Zig file with the program's `main`.
    root_source_file: std.Build.LazyPath,
    /// The target to build for, usually `b.standardTargetOptions(.{})`.
    target: std.Build.ResolvedTarget,
    /// The optimize mode, usually `b.standardOptimizeOption(.{})`.
    optimize: std.lang.Optimize,
    /// The Python installation to build against. Defaults to `zypy.findPython`.
    python: ?Python = null,
    /// Ship Python with the program, from `zypy.bundledPython`. Leave `.python` unset.
    bundle_python: bool = false,
};

/// Build and install a program that embeds Python with `py.Interpreter`.
pub fn add(b: *std.Build, options: Options) *std.Build.Step.Compile {
    if (options.bundle_python and options.python != null) {
        std.process.fatal("zypy.addExecutable: set either .python or .bundle_python, not both", .{});
    }
    const python = if (options.bundle_python) bundle.python(b, options.target) else options.python orelse Python.find(b);

    const root = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    root.addImport("zypy", module.add(b, .{
        .target = options.target,
        .optimize = options.optimize,
        .python = python,
    }));
    linkPython(root, python);

    const exe = b.addExecutable(.{ .name = options.name, .root_module = root });
    b.installArtifact(exe);
    if (python.bundle) |root_path| {
        // Keep the build machine's library directories out of the program's search path.
        exe.each_lib_rpath = false;
        installBundle(b, root_path, options.target);
    }
    return exe;
}

/// Link libpython for embedding. Extensions use the library of the interpreter that imports them.
pub fn linkPython(root: *std.Build.Module, python: Python) void {
    if (!python.shared) {
        std.process.fatal("{s} has no shared libpython to embed (it was built without --enable-shared)", .{python.executable});
    }
    if (python.bundle) |bundle_path| {
        root.addLibraryPath(bundle_path.path(root.owner, "lib"));
        // The bundled libpython is installed into lib/, next to the program's bin/.
        const darwin = root.resolved_target.?.result.os.tag.isDarwin();
        root.addRPathSpecial(if (darwin) "@executable_path/../lib" else "$ORIGIN/../lib");
    } else {
        root.addLibraryPath(.{ .cwd_relative = python.lib_dir });
        root.addRPath(.{ .cwd_relative = python.lib_dir });
    }
    root.linkSystemLibrary(python.lib_name, .{ .use_pkg_config = .no });
}

fn installBundle(b: *std.Build, root: std.Build.LazyPath, target: std.Build.ResolvedTarget) void {
    const state = State.of(b);
    if (state.installed_bundle) return;
    state.installed_bundle = true;

    const version = bundle.version;
    const library = if (target.result.os.tag.isDarwin()) "libpython" ++ version ++ ".dylib" else "libpython" ++ version ++ ".so.1.0";
    b.getInstallStep().dependOn(&b.addInstallLibFile(root.path(b, b.fmt("lib/{s}", .{library})), library).step);
    b.installDirectory(.{
        .source_dir = root.path(b, "lib/python" ++ version),
        .install_dir = .lib,
        .install_subdir = "python" ++ version,
    });
}
