import struct
import types

import pytest


def test_subclassing(ext: types.ModuleType) -> None:
    """Check Python subclasses of classes with .subclassable enabled."""

    class Square(ext.Shape):
        """A shape with four sides."""

        def area(self, side: float) -> float:
            """Get the area for a side length."""
            return side * side

    class Loud(ext.Counter):
        """A counter that counts twice."""

        def __call__(self, times: int = 1) -> int:
            """Count twice as much."""
            return super().__call__(times * 2)

    square = Square("square", 4)
    assert isinstance(square, ext.Shape)
    assert square.describe() == "square with 4 sides"
    assert square.area(2) == 4

    square.color = "red"
    assert square.color == "red"

    assert Loud()() == 2


def test_classes_without_subclassable(ext: types.ModuleType) -> None:
    """Check that classes without .subclassable refuse Python subclasses."""
    with pytest.raises(TypeError, match=r"type 'zypy_tests.Point' is not an acceptable base type"):
        type("Sub", (ext.Point,), {})


def test_python_subclasses_of_small_values(ext: types.ModuleType) -> None:
    """Check that Python subclasses of small Zig values can add slots and attributes."""
    pointer = struct.calcsize("P")
    classes = [value for value in vars(ext).values() if isinstance(value, type) and value.__module__ == "zypy_tests"]
    assert [cls for cls in classes if cls.__basicsize__ % pointer] == []

    class Slotted(ext.Marker):
        """A subclass with slots after a one-byte Zig value."""

        __slots__ = ("first", "second")

    class Open(ext.Marker):
        """A subclass whose instances have a __dict__."""

    slotted = Slotted()
    slotted.first, slotted.second = [1], "two"
    assert (slotted.first, slotted.second) == ([1], "two")

    opened = Open()
    opened.items = [1, 2]
    assert vars(opened) == {"items": [1, 2]}


def test_mixins_of_classes_without_fields(ext: types.ModuleType) -> None:
    """Check multiple inheritance and cleanup for Zig classes without fields."""

    class Mixin:
        """A Python base class."""

    class Mixed(Mixin, ext.Blank):
        """A Blank subclass with another base listed first."""

    class Reversed(ext.Blank, Mixin):
        """A Blank subclass with another base listed second."""

    before = ext.releases()["blanks"]

    for cls in (ext.Blank, Mixed, Reversed):
        assert cls.__base__ is ext.Blank or cls is ext.Blank

        blank = cls()
        assert ext.blank_address(blank) == blank.address()
        assert type(ext.new_blank(cls)) is cls
        del blank

    assert ext.releases()["blanks"] == before + 6

    with pytest.raises(TypeError, match="lay-out conflict"):
        type("Both", (ext.Blank, ext.OtherBlank), {})
