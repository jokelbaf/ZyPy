import inspect
import types

import pytest


def test_construction(ext: types.ModuleType) -> None:
    """Check class construction through init with function-style argument binding."""
    point = ext.Point(3, 4)
    assert (point.x, point.y) == (3, 4)
    assert ext.Point(1).y == 0
    assert ext.Point(y=2, x=1).y == 2

    with pytest.raises(TypeError, match=r"^Point\(\) missing 1 required positional argument: 'x'$"):
        ext.Point()

    with pytest.raises(TypeError, match=r"^Point\(\) takes from 1 to 2 positional arguments but 3 were given$"):
        ext.Point(1, 2, 3)

    with pytest.raises(TypeError, match=r"^Point\(\) got an unexpected keyword argument 'z'$"):
        ext.Point(1, z=2)

    with pytest.raises(TypeError, match="must be real number, not str"):
        ext.Point("a")


def test_field_constructor(ext: types.ModuleType) -> None:
    """Check field-based constructors and field defaults for classes without init."""
    counter = ext.Counter()
    assert (counter.count, counter.step) == (0, 1)
    assert ext.Counter(step=5).step == 5

    node = ext.Node([1])
    assert node.value == [1]
    assert node.next is None

    with pytest.raises(TypeError, match=r"^Counter\(\) takes from 0 to 2 positional arguments but 3 were given$"):
        ext.Counter(1, 2, 3)

    with pytest.raises(TypeError, match=r"^Node\(\) missing 1 required positional argument: 'value'$"):
        ext.Node()


def test_instances_without_constructor(ext: types.ModuleType) -> None:
    """Check that .init = null blocks Python construction while allowing instances returned by Zig."""
    assert ext.open_handle(5).id == 5

    with pytest.raises(TypeError, match=r"cannot create 'zypy_tests.Handle' instances"):
        ext.Handle()


def test_signatures_and_docs(ext: types.ModuleType) -> None:
    """Check class, method, and property documentation and signatures."""
    assert str(inspect.signature(ext.Point)) == "(x, y=0.0)"
    assert str(inspect.signature(ext.Counter)) == "(count=0, step=1)"
    assert str(inspect.signature(ext.Node)) == "(value, next=None)"
    assert str(inspect.signature(ext.Point.scale)) == "(self, /, factor)"
    assert str(inspect.signature(ext.Point(1).scale)) == "(factor)"

    assert ext.Point.__doc__ == "A point in 2D."
    assert ext.Point.scale.__doc__ == "Scale the point in place."
    assert ext.Point.length.__doc__ == "The distance from the origin."
    assert ext.Point.__module__ == "zypy_tests"
    assert ext.Point.__qualname__ == "Point"
