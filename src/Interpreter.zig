const std = @import("std");
const c = @import("python");
const options = @import("zypy_options");

const borrowed = @import("runtime/borrowed.zig");

const Interpreter = @This();

frame: borrowed.Frame,

const log = std.log.scoped(.zypy);

/// A Zig module that embedded Python can import.
pub const Module = struct {
    /// Must stay valid while the interpreter runs.
    name: [:0]const u8,
    /// The `init` function of a `py.module`.
    init: *const fn () callconv(.c) [*c]c.PyObject,
};

/// Settings for `init`. Every field is optional.
pub const Options = struct {
    /// Zig modules to make importable.
    modules: []const Module = &.{},
    /// The Python executable to use. A virtual environment provides access to its packages.
    executable: ?[:0]const u8 = null,
    /// The command-line arguments that Python code sees as `sys.argv`. Python uses `[""]` if this is empty.
    argv: []const [:0]const u8 = &.{},
    /// The Python home directory, as in `PYTHONHOME`. Defaults to the location of `executable`.
    /// Bundled programs use the parent of `bin/`.
    home: ?[:0]const u8 = null,
    /// Directories added to the start of `sys.path` for module imports.
    search_paths: []const [:0]const u8 = &.{},
    /// Import the `site` module at start-up, which adds the site-packages directories to `sys.path`.
    site: bool = true,
    /// Ignore environment variables such as `PYTHONPATH`, and the user site-packages directory.
    isolated: bool = false,
};

/// Python initialization failed. The `zypy` log includes the reason.
pub const InitError = error{InterpreterInitFailed};

/// Start Python with the GIL held by the calling thread.
/// Log initialization failures and return `error.InterpreterInitFailed`.
pub fn init(settings: Options) InitError!Interpreter {
    if (c.Py_IsInitialized() != 0) {
        log.err("Python is already running", .{});
        return error.InterpreterInitFailed;
    }

    for (settings.modules) |module| {
        if (c.PyImport_AppendInittab(module.name.ptr, module.init) < 0) {
            log.err("can't register module '{s}'", .{module.name});
            return error.InterpreterInitFailed;
        }
    }

    var config: c.PyConfig = undefined;
    if (settings.isolated) c.PyConfig_InitIsolatedConfig(&config) else c.PyConfig_InitPythonConfig(&config);
    defer c.PyConfig_Clear(&config);

    config.parse_argv = 0;
    config.site_import = @intFromBool(settings.site);
    var bundle: Bundle = undefined;
    const bundled: Bundle.Found = if (options.bundled_python) try bundle.find() else .{};
    if (settings.executable orelse bundled.program) |path| {
        try check(c.PyConfig_SetBytesString(&config, &config.executable, path.ptr));
    }
    if (settings.home orelse bundled.home) |path| {
        try check(c.PyConfig_SetBytesString(&config, &config.home, path.ptr));
    }
    try setArgv(&config, settings.argv);
    try check(c.Py_InitializeFromConfig(&config));

    addSearchPaths(settings.search_paths) catch |err| {
        _ = c.Py_FinalizeEx();
        return err;
    };
    return .{ .frame = borrowed.enter(true) };
}

/// Stop Python, running exit handlers and flushing stdout and stderr.
/// Threads that use Python must finish first.
pub fn deinit(self: Interpreter) void {
    self.frame.leave();
    _ = c.Py_FinalizeEx();
}

const Bundle = struct {
    program_buffer: [std.Io.Dir.max_path_bytes]u8,
    home_buffer: [std.Io.Dir.max_path_bytes]u8,

    const Found = struct { program: ?[:0]const u8 = null, home: ?[:0]const u8 = null };

    fn find(self: *Bundle) InitError!Found {
        const io = std.Io.Threaded.global_single_threaded.io();
        const length = std.process.executablePath(io, self.program_buffer[0 .. self.program_buffer.len - 1]) catch |err| {
            log.err("can't find the program to locate its Python: {t}", .{err});
            return error.InterpreterInitFailed;
        };
        self.program_buffer[length] = 0;
        const program = self.program_buffer[0..length :0];

        const bin = std.fs.path.dirname(program) orelse program;
        const home = std.fs.path.dirname(bin) orelse bin;
        @memcpy(self.home_buffer[0..home.len], home);
        self.home_buffer[home.len] = 0;
        return .{ .program = program, .home = self.home_buffer[0..home.len :0] };
    }
};

fn setArgv(config: *c.PyConfig, argv: []const [:0]const u8) InitError!void {
    if (argv.len == 0) return;

    const pointers = std.heap.c_allocator.alloc([*:0]const u8, argv.len) catch {
        log.err("can't start Python: out of memory", .{});
        return error.InterpreterInitFailed;
    };
    defer std.heap.c_allocator.free(pointers);

    for (pointers, argv) |*pointer, arg| pointer.* = arg.ptr;
    try check(c.PyConfig_SetBytesArgv(config, @intCast(argv.len), @ptrCast(pointers.ptr)));
}

fn addSearchPaths(paths: []const [:0]const u8) InitError!void {
    if (paths.len == 0) return;

    errdefer {
        c.PyErr_Print();
        log.err("can't add the search paths to sys.path", .{});
    }
    const path = c.PySys_GetObject("path") orelse return error.InterpreterInitFailed;
    for (paths, 0..) |directory, i| {
        const item = c.PyUnicode_DecodeFSDefault(directory.ptr) orelse return error.InterpreterInitFailed;
        defer c.Py_DecRef(item);

        if (c.PyList_Insert(path, @intCast(i), item) < 0) return error.InterpreterInitFailed;
    }
}

fn check(status: c.PyStatus) InitError!void {
    if (c.PyStatus_Exception(status) == 0) return;

    if (status.err_msg) |message| log.err("can't start Python: {s}", .{std.mem.span(message)});
    return error.InterpreterInitFailed;
}
