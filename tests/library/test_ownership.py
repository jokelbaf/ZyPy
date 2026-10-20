import collections.abc
import gc
import operator
import sys
import types
import typing
import weakref

import pytest

import helpers


def check_copy_keeps_value(
    ext: types.ModuleType, call: collections.abc.Callable[[typing.Any, collections.abc.Callable[[], None]], object]
) -> None:
    """Check that a Node copy passed to Zig retains values replaced by Python."""
    node = ext.Node(helpers.Item())
    item = weakref.ref(node.value)

    def replace() -> None:
        """Replace the node's value, which the copy still uses."""
        node.value = None
        assert item() is not None

    assert call(node, replace) is item()
    assert item() is None


def test_released_owned_fields(ext: types.ModuleType) -> None:
    """Check that released py.Owned fields remain safe for garbage collection."""
    node = ext.Node(helpers.Item())
    item = weakref.ref(node.value)

    node.release_value()
    assert item() is None
    assert node.value is None

    gc.collect()
    node.release_value()
    assert node.value is None


def test_copies_keep_their_references(ext: types.ModuleType) -> None:
    """Check that copied arguments and receivers retain their objects until the call returns."""
    check_copy_keeps_value(ext, ext.value_after_call)
    check_copy_keeps_value(ext, lambda node, callback: node.value_after(callback))


def test_tuple_copies_outlive_later_items(ext: types.ModuleType) -> None:
    """Check that copied class values survive changes during conversion of later tuple items."""
    node = ext.Node(helpers.Item())
    item = weakref.ref(node.value)

    class Index:
        """An integer-like object that releases a node's value during conversion."""

        def __index__(self) -> int:
            """Replace the value and return 1."""
            node.value = None
            return 1

    assert ext.node_value_in_tuple((node, Index())) is None
    assert item() is None


def test_reference_counts(ext: types.ModuleType) -> None:
    """Check that calls preserve argument reference counts."""
    o, k = object(), object()
    items, pair, d = [o], (o,), {k: o}
    holder = types.SimpleNamespace(x=o)
    before = [sys.getrefcount(x) for x in (o, k, items, pair, d, holder)]

    for _ in range(1000):
        ext.first(items)
        ext.materialize(items)
        ext.materialize(pair)
        ext.invert(d)
        ext.has(d, k)
        ext.count_words([k])
        ext.swap((1, "a"))
        ext.identity(o)
        ext.get_attr(holder, "x")
        ext.set_attr(holder, "x", o)
        ext.call_two(operator.is_, o, k)
        ext.call_no_args(lambda: o)
        ext.call_method(items, "count", o)
        ext.call_pair(lambda: (1, "x"))
        ext.exception_args(KeyError(o))
        ext.collect(1, o, flag=True, x=o)
        ext.positional_and_kwargs(1, a=o)
        ext.kwarg_lookup(n=1, other=o)
        ext.with_defaults(mode=o)
        ext.describe_user({"name": "Ann", "age": 1, "email": "x", "o": o})
        ext.call_user(lambda: {"name": "Ann", "age": 1, "o": o})
        ext.first_two(iter([o, o, o]))
        ext.pop_value({k: o}, k)
        ext.pop_at([o], 0)
        ext.tuple_item((o,), 0)
        ext.has_item(frozenset({k}), o)
        ext.same_iterator(iter(items))

        with pytest.raises(TypeError):
            ext.count_words([k, []])

        with pytest.raises(TypeError):
            ext.call_list(lambda: pair)

        with pytest.raises(TypeError):
            ext.bind(1, 2, b=o)

        with pytest.raises(TypeError):
            ext.with_defaults(mode=o, items=o)

        with pytest.raises(KeyError):
            ext.describe_user({"name": "Ann", "o": o})

        with pytest.raises(TypeError):
            ext.iter_sum([1, o])

    assert [sys.getrefcount(x) for x in (o, k, items, pair, d, holder)] == before
