const std = @import("std");
const builtin = @import("builtin");

const State = @import("State.zig");

const Python = @This();

/// The interpreter's path.
executable: []const u8,
/// The version, such as `"3.13"`.
version: []const u8,
/// The directory with Python's C headers.
include_dir: []const u8,
/// The extension file suffix reported by Python.
ext_suffix: []const u8,
/// The directory containing libpython or, on Windows, Python's import libraries.
lib_dir: []const u8,
/// The library name used to link Python.
lib_name: []const u8,
/// Whether Python provides a shared library for embedding, including macOS frameworks.
shared: bool,
/// Whether this is a free-threaded build of Python.
gil_disabled: bool = false,
/// The directory containing Python's DLLs on Windows. Empty on other systems.
dll_dir: []const u8 = "",
/// The unpacked Python bundle, for programs that ship their own interpreter.
bundle: ?std.Build.LazyPath = null,

/// Find the Python to build against, in this order: `-Dpython=<executable>`, the active venv
/// (`VIRTUAL_ENV`), a `.venv` in the project, then `python3` on PATH (`python` on Windows).
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
    // The last value may be empty, and Python on Windows ends lines with "\r\n".
    var lines = std.mem.splitScalar(u8, output, '\n');
    var values: [9][]const u8 = undefined;
    for (&values) |*value| value.* = std.mem.trimEnd(u8, lines.next().?, "\r");

    return .{
        .executable = values[0],
        .version = values[1],
        .include_dir = values[2],
        .ext_suffix = values[3],
        .lib_dir = values[4],
        .lib_name = values[5],
        .shared = std.mem.eql(u8, values[6], "1"),
        .gil_disabled = std.mem.eql(u8, values[7], "1"),
        .dll_dir = values[8],
    };
}

/// Get Python's Windows import library for the selected ABI.
pub fn importLibrary(python: Python, b: *std.Build, stable: bool) std.Build.LazyPath {
    const name = b.fmt("{s}.lib", .{if (!stable) python.lib_name else if (python.gil_disabled) "python3t" else "python3"});
    if (python.bundle) |root| return root.path(b, b.fmt("libs/{s}", .{name}));
    return .{ .cwd_relative = b.pathJoin(&.{ python.lib_dir, name }) };
}

fn defaultExecutable(b: *std.Build) []const u8 {
    const windows = builtin.os.tag == .windows;
    const venv_python: []const []const u8 = if (windows) &.{ "Scripts", "python.exe" } else &.{ "bin", "python" };
    if (b.graph.environ_map.get("VIRTUAL_ENV")) |venv| return b.pathJoin(&.{ venv, venv_python[0], venv_python[1] });

    const local = b.root.joinString(b.graph.arena, b.pathJoin(&.{ ".venv", venv_python[0], venv_python[1] })) catch @panic("OOM");
    std.Io.Dir.cwd().access(b.graph.io, local, .{}) catch return if (windows) "python" else "python3";
    return local;
}

const script =
    \\import os, sys, sysconfig
    \\v = sysconfig.get_config_var
    \\if sys.implementation.name != "cpython": sys.exit(f"ZyPy needs CPython, got {sys.implementation.name}")
    \\if sys.version_info < (3, 13): sys.exit(f"ZyPy needs Python 3.13+, got {sys.version.split()[0]}")
    \\windows = sys.platform == "win32"
    \\if windows:
    \\    import _winapi
    \\    dll = _winapi.GetModuleFileName(sys.dllhandle)
    \\    lib, dll_dir, shared = os.path.splitext(os.path.basename(dll))[0], os.path.dirname(dll), True
    \\else:
    \\    lib, dll_dir, shared = "python" + (v("LDVERSION") or ""), "", v("Py_ENABLE_SHARED") or v("PYTHONFRAMEWORK")
    \\print(sys.executable, "%d.%d" % sys.version_info[:2], sysconfig.get_path("include"), v("EXT_SUFFIX"), v("LIBDIR") or "", lib, int(bool(shared)), int(bool(v("Py_GIL_DISABLED"))), dll_dir, sep="\n")
;
