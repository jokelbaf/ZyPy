const std = @import("std");

const State = @import("State.zig");

const Python = @This();

/// The interpreter's path.
executable: []const u8,
/// The version, such as `"3.13"`.
version: []const u8,
/// The directory with Python's C headers.
include_dir: []const u8,
/// The extension file suffix, such as `".cpython-313-x86_64-linux-gnu.so"`.
ext_suffix: []const u8,
/// The directory with libpython, for embedding.
lib_dir: []const u8,
/// The library name for linking libpython, such as `"python3.13"`.
lib_name: []const u8,
/// Whether Python provides a shared library for embedding, including macOS frameworks.
shared: bool,
/// Whether this is a free-threaded build of Python.
gil_disabled: bool = false,
/// The unpacked Python bundle, for programs that ship their own interpreter.
bundle: ?std.Build.LazyPath = null,

/// Find the Python to build against, in this order: `-Dpython=<executable>`, the active venv
/// (`VIRTUAL_ENV`), a `.venv` in the project, then `python3` on PATH.
pub fn find(b: *std.Build) Python {
    // Each builder can declare the `python` option only once.
    const state = State.of(b);
    if (state.python) |python| return python;

    const executable = b.option([]const u8, "python", "Python interpreter to build against") orelse defaultExecutable(b);
    const python = query(b, executable);
    state.python = python;
    return python;
}

/// Describe the interpreter at `executable`. Fail the build if it isn't CPython 3.13 or newer.
pub fn query(b: *std.Build, executable: []const u8) Python {
    const output = b.run(&.{ executable, "-I", "-c", script });
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output, "\n"), '\n');

    return .{
        .executable = lines.next().?,
        .version = lines.next().?,
        .include_dir = lines.next().?,
        .ext_suffix = lines.next().?,
        .lib_dir = lines.next().?,
        .lib_name = b.fmt("python{s}", .{lines.next().?}),
        .shared = std.mem.eql(u8, lines.next().?, "1"),
        .gil_disabled = std.mem.eql(u8, lines.next().?, "1"),
    };
}

fn defaultExecutable(b: *std.Build) []const u8 {
    if (b.graph.environ_map.get("VIRTUAL_ENV")) |venv| return b.pathJoin(&.{ venv, "bin", "python" });

    const local = b.root.joinString(b.graph.arena, ".venv/bin/python") catch @panic("OOM");
    std.Io.Dir.cwd().access(b.graph.io, local, .{}) catch return "python3";
    return local;
}

const script =
    \\import sys, sysconfig
    \\v = sysconfig.get_config_var
    \\if sys.implementation.name != "cpython": sys.exit(f"ZyPy needs CPython, got {sys.implementation.name}")
    \\if sys.version_info < (3, 13): sys.exit(f"ZyPy needs Python 3.13+, got {sys.version.split()[0]}")
    \\print(sys.executable, "%d.%d" % sys.version_info[:2], sysconfig.get_path("include"), v("EXT_SUFFIX"), v("LIBDIR") or "", v("LDVERSION") or "", int(bool(v("Py_ENABLE_SHARED") or v("PYTHONFRAMEWORK"))), int(bool(v("Py_GIL_DISABLED"))), sep="\n")
;
