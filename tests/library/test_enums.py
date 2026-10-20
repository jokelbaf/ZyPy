import enum
import importlib.util
import inspect
import pathlib
import string
import sys
import types
import typing

import pytest

import helpers
import zypy.zig

WIDE_ENUM: typing.Final = """
const py = @import("zypy");

const Wide = enum(u16) {
$tags
    pub const class = py.enumClass(.{});
};

fn identity(tag: Wide) Wide {
    return tag;
}

pub const module = py.module(.{
    .enums = .{ .Wide = Wide },
    .functions = .{ .identity = identity },
    .free_threaded = true,
});

comptime {
    py.exportModule(module);
}
"""


def test_enums(ext: types.ModuleType) -> None:
    """Check conversions between Zig enums, Python strings, and enum.Enum member names."""

    class Color(enum.Enum):
        """A Python enum with the same names as the Zig one."""

        red = 1
        green = 2

    class Shade(enum.StrEnum):
        """A str enum whose values are the Zig tag names."""

        RED = "red"

    assert ext.next_color("red") == "green"
    assert ext.next_color(Color.green) == "blue"
    assert ext.next_color(Shade.RED) == "green"
    assert ext.next_color() == "red"
    assert str(inspect.signature(ext.next_color)) == "(color='blue')"

    assert ext.color_names(["blue", Color.red]) == ["blue", "red"]
    assert ext.quoted_tag('say "hi"') == 'say "hi"'

    with pytest.raises(ValueError, match="expected one of 'red', 'green', 'blue', got 'purple'"):
        ext.next_color("purple")

    with pytest.raises(TypeError, match="expected str, got int"):
        ext.next_color(1)


def test_enum_classes(ext: types.ModuleType) -> None:
    """Check enums exported as enum.Enum classes, and conversions to and from their members."""
    assert ext.Level.__mro__[1:] == (enum.Enum, object)
    assert (ext.Level.__module__, ext.Level.__qualname__, ext.Level.__doc__) == ("zypy_tests", "Level", "How much.")
    assert [(member.name, member.value) for member in ext.Level] == [("low", 1), ("medium", 5), ("high", 10)]
    assert [member.value for member in ext.Direction] == [0, 1, 2, 3]

    assert ext.raise_level(ext.Level.low) is ext.Level.medium
    assert ext.turn(ext.Direction.west) is ext.Direction.north
    assert ext.turn() is ext.Direction.east
    assert str(inspect.signature(ext.turn)) == "(direction=Ellipsis)"
    assert ext.levels() == list(ext.Level)
    assert ext.DEFAULT_LEVEL is ext.Level.medium
    assert ext.call_level(lambda: ext.Level.high) is ext.Level.high


def test_enum_classes_reject_other_values(ext: types.ModuleType) -> None:
    """Check that enum class conversions reject values outside that enum."""
    lookalike = enum.Enum("Level", {"low": 1})

    for value in ("low", 1, lookalike.low, ext.Direction.north):
        with pytest.raises(TypeError, match=r"^expected zypy_tests\.Level, got "):
            ext.raise_level(value)

    with pytest.raises(TypeError, match=r"^expected zypy_tests\.Level, got str$"):
        ext.call_level(lambda: "high")


def test_enum_class_lookups(ext: types.ModuleType) -> None:
    """Check conversion of every member of a large enum class and rejection of other objects."""
    members = list(ext.Wide)
    assert [ext.wide_value(member) for member in members] == list(range(256))
    assert all(ext.wide_member(value) is member for value, member in enumerate(members))

    impostor = object.__new__(ext.Wide)
    for value in (impostor, ext.Level.low, 0, "m0"):
        with pytest.raises(TypeError, match=r"^expected zypy_tests\.Wide, got "):
            ext.wide_value(value)


def test_enum_classes_with_many_members(tmp_path: pathlib.Path) -> None:
    """Check a large enum class with decreasing, nonconsecutive member values."""
    tags = "".join(f"    t{i} = {3 * (511 - i)},\n" for i in range(512))
    project = helpers.copy_example("hello", tmp_path)
    (project / "src" / "root.zig").write_text(string.Template(WIDE_ENUM).substitute(tags=tags))

    prefix = tmp_path / "install"
    helpers.run(*zypy.zig.command(), "build", "--prefix", prefix, f"-Dpython={sys.executable}", cwd=project)
    hello = load_extension(next((prefix / "python").glob("hello.*.so")))

    members = list(hello.Wide)
    assert [(member.name, member.value) for member in members[:2]] == [("t0", 1533), ("t1", 1530)]
    assert all(hello.identity(member) is member for member in members)
    assert "    t511 = 0\n" in (prefix / "python" / "hello.pyi").read_text()


def load_extension(path: pathlib.Path) -> types.ModuleType:
    """Import an extension module from `path` without adding its directory to sys.path."""
    spec = importlib.util.spec_from_file_location(path.name.split(".")[0], path)
    assert spec is not None
    assert spec.loader is not None

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
