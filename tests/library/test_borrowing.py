import collections.abc
import operator
import sys
import types
import typing
import weakref

import pytest

import helpers


def test_containers_changed_while_converting(ext: types.ModuleType) -> None:
    """Check that items survive changes to their container during conversion."""
    items: list[object] = []
    entries: dict[str, object] = {}
    keyed: dict[object, object] = {}

    class ClearsList:
        """An integer-like object that empties the list holding it."""

        def __index__(self) -> int:
            """Clear the list and return 7."""
            items.clear()
            return 7

    class ClearsDict:
        """A float-like object that empties the dict holding it."""

        def __float__(self) -> float:
            """Clear the dict and return 1.0."""
            entries.clear()
            return 1.0

    class ClearsKeys:
        """An integer-like value that clears the dict holding its key."""

        def __index__(self) -> int:
            """Clear the dict and return 1."""
            keyed.clear()
            return 1

    items.append(ClearsList())
    with pytest.raises(IndexError):
        ext.double(items)

    entries["k"] = ClearsDict()
    with pytest.raises(RuntimeError, match="dictionary changed size during iteration"):
        ext.sum_values(entries)

    keyed[object()] = ClearsKeys()
    with pytest.raises(RuntimeError, match="dictionary changed size during iteration"):
        ext.first_key(keyed)

    assert ext.first_key({"k": 1}) == "k"


def test_borrowed_reads(ext: types.ModuleType) -> None:
    """Check that container reads and instance copies stay valid across Python calls."""
    item = object()
    assert ext.read_then_call([item], list) is item
    assert ext.lookup_then_call({"key": item}, "key", list) is item
    assert ext.lookup_then_call({}, "key", list) is None
    assert ext.total_length(["ab", "cde", ""]) == 5
    assert ext.value_after_call(ext.Node(item), list) is item
    assert ext.label_length(ext.Shape("triangle", 3)) == 8

    with pytest.raises(TypeError, match=r"^expected str, got int$"):
        ext.total_length(["ab", 1])


def test_borrow_scopes(ext: types.ModuleType) -> None:
    """Check that ending a borrow scope releases its container references."""
    item = object()
    items = [item]
    counts: list[int] = []
    before = sys.getrefcount(item)

    ext.scoped_reads(items, 10_000, lambda: counts.append(sys.getrefcount(item)))
    ext.nested_scopes(items, lambda: counts.append(sys.getrefcount(item)))

    assert counts[0] == before
    assert counts[1] == (before + 1 if helpers.FREE_THREADED else before)
    assert sys.getrefcount(item) == before


def check_parcel_survives(ext: types.ModuleType, read: collections.abc.Callable[[typing.Any], object]) -> None:
    """Check that reading a parcel keeps its item alive if the label callback replaces the parcel."""
    item = helpers.Item()
    reference = weakref.ref(item)
    alive: list[bool] = []

    def replace() -> str:
        """Replace the parcel while its item is still needed for conversion."""
        courier.parcel = {"label": {"function": str}, "item": None}
        alive.append(reference() is not None)
        return "label"

    courier = ext.Courier({"label": {"function": replace}, "item": item})
    del item

    assert read(courier) == {"label": "label", "item": reference()}
    assert alive == [True]
    assert reference() is None


def test_conversions_that_replace_fields(ext: types.ModuleType) -> None:
    """Check that field and method results survive Python callbacks during conversion."""
    check_parcel_survives(ext, operator.attrgetter("parcel"))
    check_parcel_survives(ext, operator.methodcaller("parcel_copy"))
