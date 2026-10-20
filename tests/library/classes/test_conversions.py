import types

import pytest


def test_class_conversions(ext: types.ModuleType) -> None:
    """Check class conversions through pointers, copies, py.Instance, and return values."""
    a, b = ext.Point(0, 0), ext.Point(2, 4)
    assert ext.midpoint(a, b) == ext.Point(1, 2)
    assert ext.point_x(b) == 2

    assert ext.maybe_point(True) == ext.Point(1, 2)
    assert ext.maybe_point(False) is None
    assert ext.point_pair() == (ext.Point(1, 1), ext.Point(2, 2))

    assert ext.shift(a, 5) is a
    assert a.x == 5

    assert ext.new_instance(2) == ext.Point(2, 2)
    assert ext.total_x([ext.Point(1), ext.Point(2)]) == 3
    assert ext.call_point(lambda: ext.Point(9, 9)) == ext.Point(9, 9)
    assert ext.bag_total(ext.Bag([1, 2])) == 3
    assert list(ext.make_bag(3)) == [0, 1, 2]

    with pytest.raises(TypeError, match=r"^expected zypy_tests.Point, got int$"):
        ext.midpoint(1, b)

    with pytest.raises(TypeError, match=r"^expected zypy_tests.Point, got zypy_tests.Bag$"):
        ext.call_point(ext.Bag)


def test_subclass_conversions(ext: types.ModuleType) -> None:
    """Check subclass conversions to base pointers, copied values, and py.Instance references."""
    square = ext.Square("sq", 2)
    assert ext.label_length(square) == 2
    assert ext.relabel(square, "longer") is square
    assert square.label == "longer"

    stack = ext.Stack()
    stack.append(5)
    assert ext.bag_total(stack) == 5


def test_class_arguments(ext: types.ModuleType) -> None:
    """Check py.Class(T) arguments and constructor calls for classes and their subclasses."""

    class Recorded(ext.Shape):
        """A Python subclass whose __init__ runs when the class is called."""

        def __init__(self, name: str, sides: int) -> None:
            """Record the arguments."""
            self.given = (name, sides)

    assert type(ext.build_shape(ext.Shape, "a", 3)) is ext.Shape
    assert ext.build_shape(ext.Square, "s", 2).describe() == "s with 4 sides of side 2"
    assert ext.build_shape(Recorded, "r", 5).given == ("r", 5)

    with pytest.raises(TypeError, match=r"^expected a subclass of zypy_tests.Shape, got <class 'int'>$"):
        ext.build_shape(int, "x", 1)

    with pytest.raises(TypeError, match=r"^expected a subclass of zypy_tests.Shape, got 5$"):
        ext.build_shape(5, "x", 1)


def test_class_subscripts(ext: types.ModuleType) -> None:
    """Check that __class_getitem__ makes generic aliases."""
    alias = ext.Stack[int]
    assert (alias.__origin__, alias.__args__) == (ext.Stack, (int,))
