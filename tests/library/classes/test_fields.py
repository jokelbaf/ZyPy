import sys
import types

import pytest


def test_fields(ext: types.ModuleType) -> None:
    """Check read-only and writable attributes declared in .fields."""
    point = ext.Point(1, 2)
    point.x = 5
    assert point.x == 5

    with pytest.raises(AttributeError, match=r"attribute 'y' of 'zypy_tests.Point' objects is not writable"):
        point.y = 3

    with pytest.raises(AttributeError, match="can't delete attribute 'x'"):
        del point.x

    with pytest.raises(TypeError, match="must be real number"):
        point.x = "a"

    with pytest.raises(AttributeError, match="no __dict__ for setting new attributes"):
        point.z = 1

    with pytest.raises(TypeError, match=r"cannot set 'x' attribute of immutable type 'zypy_tests.Point'"):
        ext.Point.x = 1


def test_object_fields(ext: types.ModuleType) -> None:
    """Check that object fields retain their own references."""
    value = object()
    before = sys.getrefcount(value)

    node = ext.Node(value)
    assert sys.getrefcount(value) == before + 1
    assert node.value is value

    node.next = value
    assert sys.getrefcount(value) == before + 2

    node.value = 1
    node.next = None
    assert sys.getrefcount(value) == before


def test_array_fields(ext: types.ModuleType) -> None:
    """Check that array fields retain each object item."""
    value = object()
    before = sys.getrefcount(value)

    pair = ext.Pair(value, value)
    assert sys.getrefcount(value) == before + 2
    assert pair.items == [value, value]

    del pair
    assert sys.getrefcount(value) == before


def test_properties(ext: types.ModuleType) -> None:
    """Check computed property getters and setters."""
    point = ext.Point(3, 4)
    assert point.length == 5
    assert point.coordinates == (3, 4)

    point.coordinates = (1, 2)
    assert (point.x, point.y) == (1, 2)

    with pytest.raises(AttributeError, match="is not writable"):
        point.length = 1


def test_properties_of_strings(ext: types.ModuleType) -> None:
    """Check that a string property setter updates the value read by methods."""
    shape = ext.Shape("tri", 3)
    assert shape.label == "tri"
    assert shape.sides == 3

    shape.label = "triangle"
    assert shape.describe() == "triangle with 3 sides"

    with pytest.raises(AttributeError, match="can't delete attribute 'label'"):
        del shape.label

    with pytest.raises(TypeError, match="expected str, got int"):
        shape.label = 3
