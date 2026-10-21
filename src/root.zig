//! ZyPy: write Python extensions in Zig and embed Python in Zig programs.

const options = @import("zypy_options");

/// The CPython C API, for anything ZyPy doesn't cover.
pub const c = @import("python");

/// The Python executable this program was built against (`-Dpython`), or `null` if it ships its own Python.
pub const build_python: ?[:0]const u8 = options.python;

pub const Error = @import("errors.zig").Error;
pub const raise = @import("errors.zig").raise;
pub const raiseFmt = @import("errors.zig").raiseFmt;
pub const exceptionType = @import("errors.zig").exceptionType;
/// The current Python exception: `matches`, `clear` and `take`.
pub const exception = @import("exception.zig");
/// A reference to an exception object, such as one taken with `py.exception.take()`.
pub const Exception = @import("types/Exception.zig");

/// A reference to a Python object of any type.
pub const Object = @import("types/Object.zig");
/// A reference to a Python `str` or subclass.
pub const Str = @import("types/Str.zig");
/// A reference to Python `bytes` or a subclass.
pub const Bytes = @import("types/Bytes.zig");
/// A reference to a Python `list` or subclass.
pub const List = @import("types/List.zig");
/// A reference to a Python `tuple` or subclass, including named tuples.
pub const Tuple = @import("types/Tuple.zig");
/// A reference to a Python `dict` or subclass, including `defaultdict`.
pub const Dict = @import("types/Dict.zig");
pub const Set = @import("types/set.zig").Set;
pub const FrozenSet = @import("types/set.zig").FrozenSet;
pub const Sequence = @import("types/sequence.zig").Sequence;
pub const Iterator = @import("types/iterator.zig").Iterator;
pub const Buffer = @import("types/buffer.zig").Buffer;
pub const BufferMut = @import("types/buffer.zig").BufferMut;
pub const StridedBuffer = @import("types/buffer.zig").StridedBuffer;
pub const StridedBufferMut = @import("types/buffer.zig").StridedBufferMut;
pub const deinit = @import("runtime/ownership.zig").deinit;

pub const function = @import("function.zig").function;
/// The extra positional arguments of a call, for a `*args` parameter of an exported function.
pub const Args = @import("types/Args.zig");
/// The extra keyword arguments of a call, for a `**kwargs` parameter of an exported function.
pub const Kwargs = @import("types/Kwargs.zig");
pub const allowThreads = @import("runtime/gil.zig").allowThreads;
pub const Gil = @import("runtime/gil.zig").Gil;
pub const BorrowScope = @import("runtime/borrowed.zig").BorrowScope;
/// Lock one or two objects on free-threaded Python. Use this for instances the call does not lock automatically.
/// Keep the section in a local `var` until `end`. It does nothing on Python builds with the GIL.
/// For example: `var section: py.CriticalSection = .{}; section.begin(.{ self, other }); defer section.end();`.
pub const CriticalSection = @import("runtime/CriticalSection.zig");
pub const class = @import("class.zig").class;
pub const base_alignment = @import("class.zig").base_alignment;
pub const property = @import("class/attributes.zig").property;
pub const enumClass = @import("enum_class.zig").enumClass;
pub const Instance = @import("types/instance.zig").Instance;
pub const Class = @import("types/class_object.zig").Class;
pub const Owned = @import("types/owned.zig").Owned;
pub const module = @import("module.zig").module;
pub const exportModule = @import("module.zig").exportModule;
pub const import = @import("run.zig").import;
pub const run = @import("run.zig").run;
pub const runIn = @import("run.zig").runIn;
pub const eval = @import("run.zig").eval;
pub const evalIn = @import("run.zig").evalIn;

pub const allocator = @import("runtime/memory.zig").allocator;
pub const raw_allocator = @import("runtime/memory.zig").raw_allocator;

/// Python embedded in a program built with `zypy.addExecutable`.
/// Start it only once per process. Restarting after `deinit` is unreliable.
pub const Interpreter = @import("Interpreter.zig");

/// Type stubs (`.pyi`) for extensions, which `zypy.addExtension` writes at build time.
pub const stubs = @import("stubs.zig");
