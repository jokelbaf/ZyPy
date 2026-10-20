import gc
import inspect
import operator
import types
import weakref

import pytest

import helpers


def test_zig_subclasses(ext: types.ModuleType) -> None:
    """Check Zig inheritance with custom and inherited attributes and methods."""
    square = ext.Square("sq", 2)
    assert isinstance(square, ext.Shape)
    assert ext.Square.__mro__ == (ext.Square, ext.Shape, object)
    assert ext.Square.__doc__ == "A shape with four equal sides."

    assert (square.label, square.sides, square.side, square.area()) == ("sq", 4, 2, 4)
    assert square.describe() == "sq with 4 sides of side 2"
    assert ext.Shape.describe(square) == "sq with 4 sides"

    square.label = "renamed"
    square.side = 3
    assert square.describe() == "renamed with 4 sides of side 3"

    prism = ext.Prism(square, 2)
    assert ext.Prism.__mro__ == (ext.Prism, ext.Square, ext.Shape, object)
    assert str(inspect.signature(ext.Prism)) == "(square, height=1.0)"
    assert (prism.volume(), prism.area(), prism.label) == (18, 9, "renamed")

    prism.label = "prism"
    assert square.label == "renamed"
    assert ext.Prism(ext.Square("p", 1)).height == 1


def test_zig_subclasses_check_their_receivers(ext: types.ModuleType) -> None:
    """Check that subclass methods and constructors reject base-class instances."""
    with pytest.raises(TypeError, match=r"^expected zypy_tests.Square, got zypy_tests.Shape$"):
        ext.Prism(ext.Shape("s", 4))

    with pytest.raises(TypeError, match=r"descriptor 'area' for 'zypy_tests.Square' objects doesn't apply"):
        ext.Square.area(ext.Shape("s", 4))

    with pytest.raises(TypeError, match=r"type 'zypy_tests.Prism' is not an acceptable base type"):
        type("Sub", (ext.Prism,), {})


def test_python_subclasses_of_zig_subclasses(ext: types.ModuleType) -> None:
    """Check a Python subclass of a Zig subclass."""

    class Tiled(ext.Square):
        """A Python subclass of a Zig subclass."""

        def tiles(self) -> float:
            """Count tiles, each covering a quarter of the area."""
            return self.area() * 4

    tiled = Tiled("t", 1)
    assert (tiled.tiles(), tiled.describe(), ext.label_length(tiled)) == (4, "t with 4 sides of side 1", 1)


def test_inherited_operators(ext: types.ModuleType) -> None:
    """Check that custom operators coexist with inherited ones."""
    score = ext.Score(2)
    assert repr(score) == "Score(2)"
    assert repr(score + 3) == "Number(5)"
    assert 3 + score == 5
    assert repr(score**2) == "Number(4)"
    assert divmod(ext.Score(7), 2) == (3, 1)
    assert ext.Score.__add__(score, 4) == ext.Number(6)
    assert ext.Score.__radd__(score, 4) == 6

    assert score == ext.Number(2)
    assert ext.Number(2) == score
    assert score < ext.Number(3)
    assert not score < ext.Number(2)

    with pytest.raises(TypeError, match="'<=' not supported"):
        operator.le(score, ext.Number(3))

    same = score
    score += 1
    assert score is same
    assert score.value == 3


def test_inherited_hashing(ext: types.ModuleType) -> None:
    """Check that a subclass with its own __eq__ but no __hash__ is unhashable."""
    assert hash(ext.Number(5)) == 5
    assert ext.Score.__hash__ is None

    with pytest.raises(TypeError, match=r"^unhashable type: 'zypy_tests.Score'$"):
        hash(ext.Score(2))


def test_inherited_containers_and_buffers(ext: types.ModuleType) -> None:
    """Check container and buffer methods that a Zig subclass inherits."""
    stack = ext.Stack()
    for value in (1, 2, 3):
        stack.append(value)

    assert (len(stack), list(stack), stack[-1], 2 in stack) == (3, [1, 2, 3], 3, True)
    assert stack.pop() == 3
    assert not {"__len__", "__iter__", "__getitem__"} & vars(ext.Stack).keys()

    view = memoryview(stack)
    assert view.tolist() == [1, 2]

    with pytest.raises(BufferError, match="Existing exports"):
        stack.append(4)

    view.release()

    with pytest.raises(IndexError, match=r"^pop from empty Stack$"):
        ext.Stack().pop()


def test_inherited_deinit(ext: types.ModuleType) -> None:
    """Check inherited cleanup and overrides that explicitly release the base."""
    before = ext.releases()

    stack = ext.Stack()
    stack.append(1)
    del stack
    assert ext.releases()["bags"] == before["bags"] + 1

    calls: list[int] = []
    alarm = ext.Alarm(lambda: calls.append(1))
    assert alarm.rings == 0

    del alarm
    assert calls == [1]
    assert ext.releases()["trackers"] == before["trackers"] + 1


def test_inherited_weak_references_and_dicts(ext: types.ModuleType) -> None:
    """Check that Zig subclasses of a class with .weak_references and .dict support both."""
    badge = ext.Badge("b")
    badge.color = "red"
    assert badge.__dict__ == {"color": "red"}

    badge.level = 3
    assert (badge.name, badge.level) == ("b", 3)

    reference = weakref.ref(badge)
    badge.me = badge
    badge.item = helpers.Item()
    item = weakref.ref(badge.item)

    del badge
    gc.collect()

    assert reference() is None
    assert item() is None
