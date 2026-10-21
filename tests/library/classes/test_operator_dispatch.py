import operator
import types
import typing


class Marker:
    """A Python equivalent of zypy_tests.Marker, returning operator names or NotImplemented."""

    def __add__(self, other: object) -> object:
        """Return the method name for a marker, or NotImplemented for other operands."""
        return "Marker.__add__" if isinstance(other, Marker) else NotImplemented

    def __radd__(self, other: object) -> object:
        """Return the method name for a marker, or NotImplemented for other operands."""
        return "Marker.__radd__" if isinstance(other, Marker) else NotImplemented

    def __sub__(self, other: object) -> object:
        """Return the method name for an integer, or NotImplemented for other operands."""
        return "Marker.__sub__" if isinstance(other, int) else NotImplemented

    def __rsub__(self, other: object) -> object:
        """Return the method name for a marker, or NotImplemented for other operands."""
        return "Marker.__rsub__" if isinstance(other, Marker) else NotImplemented

    def __mul__(self, other: object) -> object:
        """Return NotImplemented for any operand."""
        return NotImplemented

    def __rmul__(self, other: object) -> object:
        """Return the method name for a marker, or NotImplemented for other operands."""
        return "Marker.__rmul__" if isinstance(other, Marker) else NotImplemented

    def __pow__(self, other: object) -> object:
        """Return the method name for a marker, or NotImplemented for other operands."""
        return "Marker.__pow__" if isinstance(other, Marker) else NotImplemented

    def __rpow__(self, other: object) -> object:
        """Return the method name for a marker, or NotImplemented for other operands."""
        return "Marker.__rpow__" if isinstance(other, Marker) else NotImplemented


class PlainMarker(Marker):
    """A Python equivalent of zypy_tests.PlainMarker."""


class ForwardMarker(Marker):
    """A Python equivalent of zypy_tests.ForwardMarker."""

    @typing.override
    def __add__(self, other: object) -> object:
        """Return the method name for a marker, or NotImplemented for other operands."""
        return "ForwardMarker.__add__" if isinstance(other, Marker) else NotImplemented

    @typing.override
    def __pow__(self, other: object) -> object:
        """Return the method name for a marker, or NotImplemented for other operands."""
        return "ForwardMarker.__pow__" if isinstance(other, Marker) else NotImplemented


class ReflectedMarker(PlainMarker):
    """A Python equivalent of zypy_tests.ReflectedMarker."""

    @typing.override
    def __radd__(self, other: object) -> object:
        """Return the method name for a marker, or NotImplemented for other operands."""
        return "ReflectedMarker.__radd__" if isinstance(other, Marker) else NotImplemented

    @typing.override
    def __rpow__(self, other: object) -> object:
        """Return the method name for a marker, or NotImplemented for other operands."""
        return "ReflectedMarker.__rpow__" if isinstance(other, Marker) else NotImplemented


class PythonOverriding(Marker):
    """A Marker subclass that overrides reflected operators."""

    @typing.override
    def __radd__(self, other: object) -> object:
        """Return the reflected addition method name."""
        return "Overriding.__radd__"

    @typing.override
    def __rpow__(self, other: object) -> object:
        """Return the reflected power method name."""
        return "Overriding.__rpow__"


def outcome(apply: typing.Callable[[typing.Any, typing.Any], object], left: object, right: object) -> object:
    """Apply an operator, returning TypeError if it raises that exception."""
    try:
        return apply(left, right)
    except TypeError:
        return TypeError


def test_reflected_operator_order(ext: types.ModuleType) -> None:
    """Check that inherited operator dispatch matches equivalent Python classes."""

    class Overriding(ext.Marker):
        """A Python subclass of zypy_tests.Marker that replaces reflected operators."""

        def __radd__(self, other: object) -> object:
            """Return the reflected addition method name."""
            return "Overriding.__radd__"

        def __rpow__(self, other: object) -> object:
            """Return the reflected power method name."""
            return "Overriding.__rpow__"

    zig = (ext.Marker(), ext.PlainMarker(), ext.ForwardMarker(), ext.ReflectedMarker(), Overriding(), 1)
    python = (Marker(), PlainMarker(), ForwardMarker(), ReflectedMarker(), PythonOverriding(), 1)

    for left, python_left in zip(zig, python, strict=True):
        for right, python_right in zip(zig, python, strict=True):
            for apply in (operator.add, operator.sub, operator.mul, operator.pow):
                expected = outcome(apply, python_left, python_right)
                assert outcome(apply, left, right) == expected, (apply, left, right)


def test_inherited_operators(ext: types.ModuleType) -> None:
    """Check operator selection when Zig subclasses inherit or override operators."""
    assert ext.Marker() + ext.ForwardMarker() == "Marker.__add__"
    assert ext.Marker() + ext.ReflectedMarker() == "ReflectedMarker.__radd__"
    assert ext.Marker() - ext.PlainMarker() == "Marker.__rsub__"
    assert ext.ForwardMarker.__radd__(ext.ForwardMarker(), ext.Marker()) == "Marker.__radd__"
    assert ext.Marker() * ext.PlainMarker() == "Marker.__rmul__"
    assert ext.Marker.__mul__(ext.Marker(), ext.Marker()) is NotImplemented

    assert "__add__" not in vars(ext.PlainMarker)
    assert "__radd__" in vars(ext.ForwardMarker)
