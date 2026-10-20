import inspect
import types

import pytest


def test_methods(ext: types.ModuleType) -> None:
    """Check instance methods using pointers or copies and static methods without a receiver."""
    point = ext.Point(3, 4)
    assert point.norm() == 5

    assert point.scale(2) is None
    assert (point.x, point.y) == (6, 8)

    assert point.scaled(factor=0.5) == ext.Point(3, 4)
    assert (point.x, point.y) == (6, 8)

    assert ext.Point.origin() == ext.Point(0, 0)
    assert point.origin() == ext.Point(0, 0)

    with pytest.raises(TypeError, match=r"^Point.scale\(\) missing 1 required positional argument: 'factor'$"):
        point.scale()

    with pytest.raises(TypeError, match=r"descriptor 'scale' for 'zypy_tests.Point' objects doesn't apply"):
        ext.Point.scale(5, 2)


def test_static_methods(ext: types.ModuleType) -> None:
    """Check static methods with keywords and module state."""
    assert ext.Point.hypot(3.0, 4.0) == ext.Point.hypot(3.0, dy=4.0) == ext.Point.hypot(dy=4.0, dx=3.0) == 5.0
    assert ext.Point(1).hypot(dx=3.0, dy=4.0) == 5.0
    assert isinstance(ext.Point.__dict__["hypot"], staticmethod)
    assert str(inspect.signature(ext.Point.hypot)) == "(dx, dy)"

    assert type(ext.Counter.__dict__["total_calls"]).__name__ == "classmethod_descriptor"
    assert str(inspect.signature(ext.Counter.total_calls)) == "()"

    with pytest.raises(TypeError, match=r"^Point\.hypot\(\) got an unexpected keyword argument 'dz'$"):
        ext.Point.hypot(3.0, dz=4.0)

    with pytest.raises(TypeError, match=r"^Point\.hypot\(\) got multiple values for argument 'dx'$"):
        ext.Point.hypot(3.0, dx=4.0)


def test_class_methods(ext: types.ModuleType) -> None:
    """Check class-method receivers through classes and instances."""
    triangle = ext.Shape.triangle("t")
    assert type(triangle) is ext.Shape
    assert (triangle.label, triangle.sides) == ("t", 3)
    assert type(ext.Shape("a", 4).triangle("b")) is ext.Shape

    assert ext.Shape.kind() == "Shape"
    assert str(inspect.signature(ext.Shape.triangle)) == "(name)"
    assert ext.Shape.triangle.__doc__ == "Make a shape with three sides."
    assert type(ext.Shape.__dict__["triangle"]).__name__ == "classmethod_descriptor"
    assert ext.Counter.from_calls().count == ext.count_calls() - 1

    with pytest.raises(TypeError, match=r"^Shape.triangle\(\) missing 1 required positional argument: 'name'$"):
        ext.Shape.triangle()


def test_class_methods_of_subclasses(ext: types.ModuleType) -> None:
    """Check that class methods create instances of the subclass they're called on."""

    class Flat(ext.Shape):
        """A Python subclass whose __init__ is skipped by direct instance creation."""

        def __init__(self, name: str, sides: int) -> None:
            """Mark the instance."""
            self.initialized = (name, sides)

    flat = Flat.triangle("f")
    assert type(flat) is Flat
    assert flat.describe() == "f with 3 sides"
    assert not hasattr(flat, "initialized")
    assert Flat.kind() == "Flat"

    with pytest.raises(
        TypeError, match=r"^cannot create 'zypy_tests.Square' instances from a 'zypy_tests.Shape' value$"
    ):
        ext.Square.triangle("s")


def test_own_iterators_and_receiver_names(ext: types.ModuleType) -> None:
    """Check self-iterating classes, Zig subclasses, and receiver-name conflicts with self and cls."""
    countdown = ext.Countdown(3)
    assert iter(countdown) is countdown
    assert list(countdown) == [3, 2, 1]
    assert list(ext.DoubleCountdown(5)) == [5, 3, 1]

    countdown.restart(self=2)
    assert list(countdown) == [2, 1]
    assert ext.Countdown.starting(cls=4).left == 4

    assert str(inspect.signature(ext.Countdown.restart)) == "(_self, /, self)"
    assert str(inspect.signature(countdown.restart)) == "(self)"
    assert str(inspect.signature(ext.Countdown.starting)) == "(cls)"
