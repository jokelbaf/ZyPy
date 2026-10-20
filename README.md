<p align="center">
  <img src="docs/src/assets/logo.svg" alt="ZyPy logo" width="96">
</p>

<h1 align="center">ZyPy</h1>

ZyPy lets you write Python extensions in Zig and call Python from Zig programs. It includes a Zig library, a Python build backend, and the `zypy` command-line tool.

You can export functions and classes, work with Python objects and buffers, or embed Python in a Zig program. ZyPy builds Python packages and generates type stubs so editors and type checkers can understand your extensions.

**ZyPy is experimental and may be unstable in some scenarios.**

## Requirements

- Linux with glibc or musl, or macOS 11 or newer.
- CPython 3.13 or newer, including free-threaded builds.
- Zig 0.17. Python build tools install it through the `ziglang` package if needed.

The steps below use [uv](https://docs.astral.sh/uv/) to manage Python environments and builds.

## Quick start

ZyPy is on PyPI as `zypy`. Create a project and call it from Python:

```sh
uvx zypy new hello
cd hello
uv sync
uv run python -c "import hello; print(hello.add(1, 2))"
```

This creates a project, builds its extension, and calls it from Python. The result is `3`.

The generated `src/root.zig` defines a Python module with one function:

```zig
const std = @import("std");
const py = @import("zypy");

fn add(a: i64, b: i64) !i64 {
    return std.math.add(i64, a, b);
}

pub const module = py.module(.{
    .doc = "hello, written in Zig.",
    .functions = .{
        .add = py.function(add, .{ .doc = "Add two numbers." }),
    },
});

comptime {
    py.exportModule(module);
}
```

ZyPy converts arguments and return values for you. Returning a Zig error raises a Python exception. For example, if this sum is too large for `i64`, Python receives `OverflowError`.

After changing Zig code, run your code again with `uv run`, which rebuilds the extension when Zig files change. Run `uv build` to create a wheel and a source distribution for sharing or installation.

## Types

Zig functions can take and return these types. ZyPy converts them to and from Python values.

| Zig                                   | Python                                                                         |
| ------------------------------------- | ------------------------------------------------------------------------------ |
| `i8`, `u32`, `i128`, ... (any width)  | `int`, range-checked                                                           |
| `f32`, `f64`                          | `float`                                                                        |
| `bool`                                | `bool`; arguments accept any object, by truthiness                             |
| `void` (return)                       | `None`                                                                         |
| `?T`                                  | `T` or `None`                                                                  |
| `E!T` (return)                        | `T`, or an exception (`py.raise(...)`, or `RuntimeError` for other Zig errors) |
| tuples, e.g. `struct { i64, py.Str }` | `tuple`                                                                        |
| other structs                         | `dict`; arguments accept any mapping, with one key per field                   |
| enums                                 | `str` with the tag name; arguments also accept `enum.Enum` members             |
| `[]const u8`, `py.Bytes`              | `bytes`                                                                        |
| string literals (return)              | `str`                                                                          |
| other slices and arrays (return)      | `list`                                                                         |
| `py.Object`                           | any object                                                                     |
| `py.Str`                              | `str`                                                                          |
| `py.List`, `py.Tuple`                 | `list`, `tuple` of any length                                                  |
| `py.Dict`                             | `dict`                                                                         |
| `py.Set`, `py.FrozenSet`              | `set`, `frozenset`                                                             |
| `py.Sequence(T)`                      | any iterable except `str`                                                      |
| `py.Iterator(T)`                      | any iterable except `str`, read one item at a time                             |
| `py.Buffer(T)`, `py.BufferMut(T)`     | `bytearray`, `memoryview`, `array.array`, NumPy arrays, ...                    |
| `py.StridedBuffer(T)`, ...            | buffers that aren't contiguous, such as the NumPy slice `a[::2]`               |
| `py.Exception`                        | any exception object                                                           |
| classes: `*T`, `*const T`, `T`        | instances of a Zig struct that declares `pub const class = py.class(...)`      |
| `py.Instance(T)`                      | an instance of class `T`                                                       |
| `py.Class(T)`                         | class `T` or a subclass; as a method's first parameter, makes a class method   |

## Documentation and examples

ZyPy documentation and API reference is available at [zypy.jokelbaf.dev](https://zypy.jokelbaf.dev).

The repository also includes three example projects:

- [hello](examples/hello): a Python extension written in Zig.
- [mixed](examples/mixed): a Python package with a Zig extension.
- [embed](examples/embed): a Zig program that runs Python.

## License

ZyPy is licensed under the [MIT License](LICENSE).
