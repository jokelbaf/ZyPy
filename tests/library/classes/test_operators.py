import operator
import types

import pytest


def test_comparisons_and_hashing(ext: types.ModuleType) -> None:
    """Check comparison and hash special methods."""
    assert ext.Point(1, 2) == ext.Point(1, 2)
    assert ext.Point(1, 2) != ext.Point(2, 1)
    assert ext.Point(1, 2) != 5
    assert ext.Point(1, 1) < ext.Point(3, 3)
    assert ext.Point(3, 3) > ext.Point(1, 1)

    assert hash(ext.Point(1, 2)) == hash(ext.Point(1, 2))
    assert len({ext.Point(1, 2), ext.Point(1, 2), ext.Point(0)}) == 2
    assert hash(ext.Point(-0.0, 1)) == hash(ext.Point(0.0, 1))
    assert len({ext.Point(-0.0, 1), ext.Point(0.0, 1)}) == 1

    with pytest.raises(TypeError, match="'<=' not supported"):
        operator.le(ext.Point(1), ext.Point(2))

    with pytest.raises(TypeError, match=r"'<' not supported between instances of 'zypy_tests.Point' and 'int'"):
        operator.lt(ext.Point(1), 1)


def test_identity_comparisons_and_hashing(ext: types.ModuleType) -> None:
    """Check the default comparison and hash of classes without __eq__ or __hash__."""
    shape = ext.Shape("a", 3)
    same = shape

    assert hash(shape) == hash(same)
    assert shape == same
    assert shape != ext.Shape("a", 3)


def test_number_methods(ext: types.ModuleType) -> None:
    """Check arithmetic special methods, including reflected operations."""
    assert ext.Point(1, 2) + ext.Point(3, 4) == ext.Point(4, 6)
    assert -ext.Point(1, 2) == ext.Point(-1, -2)
    assert ext.Point(1, 2) * 2 == ext.Point(2, 4)
    assert 3 * ext.Point(1, 2) == ext.Point(3, 6)

    with pytest.raises(TypeError, match=r"unsupported operand type\(s\) for \+: 'zypy_tests.Point' and 'int'"):
        operator.add(ext.Point(1), 1)

    with pytest.raises(TypeError, match=r"unsupported operand type\(s\) for -: 'int' and 'zypy_tests.Point'"):
        operator.sub(1, ext.Point(1))


def test_call_and_truth(ext: types.ModuleType) -> None:
    """Check argument binding for __call__ and truth testing through __bool__."""
    counter = ext.Counter()
    assert not counter
    assert counter() == 1
    assert counter(times=3) == 4
    assert counter

    counter.step = 10
    assert counter(2) == 24

    with pytest.raises(TypeError, match=r"^Counter.__call__\(\) takes from 0 to 1 positional arguments but 2 were"):
        counter(1, 2)


def test_in_place_operators(ext: types.ModuleType) -> None:
    """Check in-place operators, which change the instance or return a new value."""
    number = ext.Number(2)
    same = number

    number += 3
    assert number is same
    assert number.value == 5

    number -= ext.Number(1)
    assert number is same
    assert number.value == 4

    number **= 2
    assert number is same
    assert number.value == 16

    number *= 2
    assert number is not same
    assert (number.value, same.value) == (32, 16)

    with pytest.raises(TypeError, match=r"unsupported operand type\(s\) for \+=: 'zypy_tests.Number' and 'str'"):
        number += "x"

    with pytest.raises(TypeError, match=r"unsupported operand type\(s\) for -=: 'zypy_tests.Number' and 'int'"):
        number -= 1


def test_power_and_divmod(ext: types.ModuleType) -> None:
    """Check __pow__ with and without a modulo, __rpow__, __divmod__ and __rdivmod__."""
    assert (ext.Number(3) ** 2).value == 9
    assert pow(ext.Number(3), 3, 5).value == 2
    assert 2 ** ext.Number(5) == 32
    assert divmod(ext.Number(7), 2) == (3, 1)
    assert divmod(7, ext.Number(-2)) == (-4, -1)

    with pytest.raises(ValueError, match="pow\\(\\) 3rd argument cannot be 0"):
        pow(ext.Number(3), 3, 0)

    with pytest.raises(TypeError, match=r"unsupported operand type\(s\) for \*\* or pow\(\): 'zypy_tests.Number' and"):
        _ = ext.Number(3) ** "x"

    with pytest.raises(TypeError, match=r"unsupported operand type\(s\) for \*\* or pow\(\)"):
        pow(2, ext.Number(3), 5)

    with pytest.raises(ZeroDivisionError):
        divmod(1, ext.Number(0))


def test_overflowing_operators(ext: types.ModuleType) -> None:
    """Check that operators raise OverflowError for results outside their numeric range."""
    for overflowing in (
        lambda: ext.Number(2) ** 63,
        lambda: ext.Number(2**62) + 2**62,
        lambda: divmod(ext.Number(-(2**63)), -1),
        lambda: ext.Counter(step=2**62)(4),
    ):
        with pytest.raises(OverflowError, match=r"^Overflow$"):
            overflowing()


def test_operators_of_subclasses(ext: types.ModuleType) -> None:
    """Check operators that Python subclasses override, call through super(), or inherit."""

    class Added(ext.Number):
        """A number whose operators call the Zig ones."""

        def __add__(self, other: int) -> object:
            """Add through the base class."""
            return super().__add__(other)

        def __pow__(self, other: int, modulo: int | None = None) -> object:
            """Raise to a power through the base class."""
            return super().__pow__(other, modulo)

    class Inherited(ext.Number):
        """A number that keeps the Zig operators."""

    assert repr(Added(2) + 3) == "Number(5)"
    assert repr(Added(2) ** 3) == "Number(8)"
    assert repr(pow(Added(2), 3, 5)) == "Number(3)"

    assert (Inherited(2) + 3).value == 5
    assert 2 ** Inherited(3) == 8
    assert divmod(7, Inherited(2)) == (3, 1)


def test_direct_operator_calls(ext: types.ModuleType) -> None:
    """Check that explicit operator calls return NotImplemented for unsupported operands."""
    number = ext.Number(3)
    assert ext.Number.__add__(number, 4).value == 7
    assert ext.Number.__rpow__(number, 2) == 8
    assert ext.Number.__radd__(number, 4) is NotImplemented
    assert ext.Number.__add__(number, "x") is NotImplemented

    with pytest.raises(TypeError, match=r"^expected at least 1 argument, got 0$"):
        ext.Number.__pow__(number)

    with pytest.raises(TypeError, match=r"^expected at most 2 arguments, got 3$"):
        ext.Number.__pow__(number, 2, 3, 4)
