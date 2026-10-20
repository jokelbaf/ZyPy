/// An API entry point and its public import name.
pub const Root = struct { path: []const u8, prefix: []const u8 };

pub const roots = [_]Root{
    .{ .path = "src/root.zig", .prefix = "py" },
    .{ .path = "build.zig", .prefix = "zypy" },
};

/// A page of the reference and the top-level declarations it documents, in order.
pub const Page = struct {
    slug: []const u8,
    title: []const u8,
    description: []const u8,
    items: []const []const u8,
};

pub const pages = [_]Page{
    .{
        .slug = "objects",
        .title = "Python objects",
        .description = "References to Python objects: py.Object, py.Str, py.List, py.Dict and the other built-in types.",
        .items = &.{ "py.Object", "py.Str", "py.Bytes", "py.List", "py.Tuple", "py.Dict", "py.Set", "py.FrozenSet", "py.deinit" },
    },
    .{
        .slug = "iterables-and-buffers",
        .title = "Iterables and buffers",
        .description = "Views of iterables and buffers: py.Sequence, py.Iterator, py.Buffer and the strided buffers.",
        .items = &.{ "py.Sequence", "py.Iterator", "py.Buffer", "py.BufferMut", "py.StridedBuffer", "py.StridedBufferMut" },
    },
    .{
        .slug = "functions-and-modules",
        .title = "Functions and modules",
        .description = "Exporting functions and modules: py.function, py.Args, py.Kwargs, py.module and py.exportModule.",
        .items = &.{ "py.function", "py.Args", "py.Kwargs", "py.module", "py.exportModule" },
    },
    .{
        .slug = "classes-and-enums",
        .title = "Classes and enums",
        .description = "Zig structs as Python classes and Zig enums as enum.Enum classes.",
        .items = &.{ "py.class", "py.property", "py.Instance", "py.Class", "py.Owned", "py.base_alignment", "py.enumClass" },
    },
    .{
        .slug = "exceptions",
        .title = "Exceptions",
        .description = "Raising, defining and catching Python exceptions.",
        .items = &.{ "py.Error", "py.raise", "py.raiseFmt", "py.exceptionType", "py.exception", "py.Exception" },
    },
    .{
        .slug = "running-python",
        .title = "Running Python",
        .description = "Importing modules, running code and allocating memory through Python.",
        .items = &.{ "py.import", "py.run", "py.runIn", "py.eval", "py.evalIn", "py.allocator", "py.raw_allocator" },
    },
    .{
        .slug = "threads",
        .title = "Threads and the GIL",
        .description = "Releasing the GIL, using Python from Zig threads, and free-threaded Python.",
        .items = &.{ "py.allowThreads", "py.Gil", "py.BorrowScope" },
    },
    .{
        .slug = "embedding",
        .title = "Embedding and the C API",
        .description = "Running Python inside a Zig program, and the CPython C API.",
        .items = &.{ "py.Interpreter", "py.build_python", "py.c" },
    },
    .{
        .slug = "build",
        .title = "Build helpers",
        .description = "The zypy build.zig helpers for extensions, programs that embed Python, and custom setups.",
        .items = &.{
            "zypy.addExtension",
            "zypy.ExtensionOptions",
            "zypy.addExecutable",
            "zypy.ExecutableOptions",
            "zypy.linkPython",
            "zypy.addModule",
            "zypy.ModuleOptions",
            "zypy.findPython",
            "zypy.bundledPython",
            "zypy.bundled_python_version",
            "zypy.Python",
        },
    },
};

/// Public declarations that users never call: ZyPy's own build function and the stub writer.
pub const hidden = [_][]const u8{ "zypy.build", "py.stubs" };

/// Members hidden everywhere: the conversion protocol that ZyPy calls, and markers for its type checks.
pub const hidden_members = [_][]const u8{ "fromPython", "toPython", "usable_without_gil", "Item", "Value" };

/// Prefix of marker declarations that ZyPy's type checks look for.
pub const marker_prefix = "zypy_";

/// Members to include for types returned by these functions.
pub const Shown = struct { function: []const u8, members: []const []const u8 };

pub const shown_members = [_]Shown{
    .{ .function = "py.module", .members = &.{ "init", "State", "stateOf" } },
    .{ .function = "py.exceptionType", .members = &.{"object"} },
};

/// Fields that only ZyPy uses. Every other field needs a doc comment.
pub const internal_fields = [_][]const u8{
    "py.Sequence.items",
    "py.Iterator.state",
    "py.Buffer.view",
    "py.Buffer.layout",
    "py.BufferMut.view",
    "py.BufferMut.layout",
    "py.StridedBuffer.view",
    "py.StridedBuffer.layout",
    "py.StridedBuffer.Iterator.buffer",
    "py.StridedBuffer.Iterator.offsets",
    "py.StridedBufferMut.view",
    "py.StridedBufferMut.layout",
    "py.StridedBufferMut.Iterator.buffer",
    "py.StridedBufferMut.Iterator.offsets",
    "py.Dict.Iterator.position",
    "py.Dict.Iterator.size",
    "py.Owned.value",
    "py.Gil.state",
    "py.Gil.frame",
    "py.BorrowScope.frame",
    "py.Interpreter.frame",
};

/// Declarations documented elsewhere, linked instead of listed.
pub const External = struct { name: []const u8, url: []const u8, summary: []const u8 };

pub const external = [_]External{.{
    .name = "py.c",
    .url = "https://docs.python.org/3/c-api/index.html",
    .summary = "The CPython C API, translated from Python's headers, for anything ZyPy doesn't cover.",
}};

/// The source URL used by reference links.
pub const repository = "https://github.com/jokelbaf/ZyPy/blob/master/";
