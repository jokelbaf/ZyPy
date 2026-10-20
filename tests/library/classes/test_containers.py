import operator
import types

import pytest


def test_containers(ext: types.ModuleType) -> None:
    """Check container special methods, including negative indexes."""
    bag = ext.Bag([1, 2, 3])
    assert len(bag) == 3
    assert (bag[0], bag[-1]) == (1, 3)
    assert 2 in bag
    assert 5 not in bag
    assert "x" not in bag

    bag[0] = 10
    del bag[1]
    bag.append(4)
    assert list(bag) == [10, 3, 4]
    assert bag.total() == 17
    assert len(ext.Bag()) == 0

    with pytest.raises(IndexError, match=r"^OutOfRange$"):
        operator.getitem(bag, 3)

    with pytest.raises(IndexError, match=r"^Bag index out of range$"):
        operator.getitem(bag, -4)

    with pytest.raises(IndexError, match=r"^Bag assignment index out of range$"):
        operator.setitem(bag, 5, 1)

    with pytest.raises(TypeError, match="sequence index must be integer, not 'str'"):
        operator.getitem(bag, "x")


def test_iterators(ext: types.ModuleType) -> None:
    """Check class-based iterators and their __next__ methods."""
    bag = ext.Bag([1, 2])
    iterator = iter(bag)
    assert type(iterator) is ext.BagIterator
    assert iter(iterator) is iterator
    assert next(iterator) == 1
    assert list(iterator) == [2]

    with pytest.raises(StopIteration):
        next(iterator)

    with pytest.raises(TypeError, match=r"cannot create 'zypy_tests.BagIterator' instances"):
        ext.BagIterator()


def test_buffers(ext: types.ModuleType) -> None:
    """Check that __buffer__ exposes Zig memory without copying."""
    bag = ext.Bag([1, 2, 3])
    view = memoryview(bag)
    assert (view.format, view.itemsize, view.shape, view.readonly) == ("q", 8, (3,), False)
    assert view.tolist() == [1, 2, 3]

    view[0] = 7
    assert bag[0] == 7

    view.release()
    assert bytes(ext.Bag([1]))[:2] == b"\x01\x00"


def test_buffer_exports(ext: types.ModuleType) -> None:
    """Check that active buffer views prevent resizing instance memory."""
    bag = ext.Bag([1, 2])
    view = memoryview(bag)

    with pytest.raises(BufferError, match="Existing exports"):
        bag.append(3)

    view.release()
    bag.append(3)
    assert list(bag) == [1, 2, 3]
    assert memoryview(ext.Bag()).tolist() == []


def test_failed_exports_count_no_views(ext: types.ModuleType) -> None:
    """Check that failed buffer requests do not increase the active-view count."""
    frozen = ext.Frozen()

    with pytest.raises(BufferError, match=r"^Frozen buffers are read-only$"):
        ext.fill(frozen, 0)

    assert frozen.exports == 0

    with memoryview(frozen) as view:
        assert (view.tobytes(), view.readonly, frozen.exports) == (b"\x01\x02\x03", True, 1)

    assert frozen.exports == 0


def test_item_slots_of_zig_subclasses(ext: types.ModuleType) -> None:
    """Check item access when a Zig subclass changes its key type."""
    names = ext.Names()
    names["second"] = 5
    assert names["second"] == 5

    positions = ext.Positions()
    positions[1] = 5
    assert (positions[0], positions[1], positions[-1]) == (1, 5, 3)
    assert list(positions) == [1, 5, 3]

    for key in ("first", 1.5):
        with pytest.raises(TypeError, match=r"^sequence index must be integer, not '(str|float)'$"):
            positions[key]

        with pytest.raises(TypeError, match=r"^sequence index must be integer, not '(str|float)'$"):
            positions[key] = 1

    with pytest.raises(IndexError, match=r"^OutOfRange$"):
        positions[3]

    labels = ext.Labels()
    assert (labels["last"], labels["other"]) == (3, -1)

    with pytest.raises(TypeError, match=r"^expected str, got int$"):
        list(labels)

    labels[0] = 7
    assert ext.Positions.__getitem__(labels, 0) == ext.Positions.__getitem__(labels, -3) == 7


def test_item_slots_called_through_super(ext: types.ModuleType) -> None:
    """Check calls to Zig __getitem__ through super() in a Python subclass."""

    class Doubled(ext.Positions):
        """A Python subclass that doubles the items."""

        def __getitem__(self, index: int) -> int:
            """Double the item."""
            return super().__getitem__(index) * 2

    assert (Doubled()[0], Doubled()[-1]) == (2, 6)
