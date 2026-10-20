import collections
import collections.abc
import types
import typing

import pytest

import helpers


class Point(typing.NamedTuple):
    """A tuple subclass with named fields."""

    x: int
    y: int


def test_lists(ext: types.ModuleType) -> None:
    """Check reads, updates, and construction with py.List."""
    assert ext.range(5) == [0, 1, 2, 3, 4]
    assert ext.squares() == [1, 4, 9, 16]

    items = [1, 2, 3]
    ext.double(items)
    assert items == [2, 4, 6]

    o = object()
    assert ext.first([o]) is o
    assert ext.first([]) is None

    appended: list[object] = []
    ext.append_owned(appended)
    assert appended == ["owned", [True, False]]

    with pytest.raises(TypeError, match="expected list, got tuple"):
        ext.double((1, 2))


def test_list_operations(ext: types.ModuleType) -> None:
    """Check list insertion, removal, slicing, and clearing."""
    items = [1, 2, 3]
    assert ext.list_ops(items) == (1, [2, 3])
    assert items == [10, 2, 3, 99]

    o = object()
    holder = [1, o]
    assert ext.pop_at(holder, 1) is o
    assert holder == [1]

    ext.clear_list(holder)
    assert holder == []

    with pytest.raises(IndexError, match="pop from empty list"):
        ext.pop_at([], 0)

    with pytest.raises(IndexError, match="pop index out of range"):
        ext.pop_at([1], 1)

    with pytest.raises(IndexError, match="list index out of range"):
        ext.list_item([], 2**64 - 1)

    with pytest.raises(IndexError, match="list assignment index out of range"):
        ext.set_list_item([1], 2**63, o)


def test_sequences(ext: types.ModuleType) -> None:
    """Check that py.Sequence accepts iterables except str."""
    for xs in ([1, 2.5], (1, 2.5), iter([1, 2.5]), (x for x in [1, 2.5])):
        assert ext.seq_sum(xs) == 3.5

    assert ext.seq_sum(range(5)) == 10
    assert ext.seq_sum({1: "a", 2: "b"}) == 3
    assert ext.seq_sum(b"\x01\x02") == 3

    with pytest.raises(TypeError, match="expected a sequence, got str"):
        ext.seq_sum("abc")

    with pytest.raises(TypeError, match="not iterable"):
        ext.seq_sum(5)


def test_nested_sequences(ext: types.ModuleType) -> None:
    """Check sequences of tuples and of other sequences."""
    assert ext.sum_pairs([("a", 1), ("b", 2)]) == 3
    assert ext.nested_sum([[1, 2], (3,), range(4)]) == 12

    with pytest.raises(TypeError, match="not iterable"):
        ext.nested_sum([[1], 2])


def test_sequence_returns_its_list_or_tuple(ext: types.ModuleType) -> None:
    """Check that returning py.Sequence returns the list or tuple holding its items."""
    items, pair = [1, 2], (1, 2)
    assert ext.materialize(items) is items
    assert ext.materialize(pair) is pair
    assert ext.materialize(iter("xy")) == ["x", "y"]


def test_dicts(ext: types.ModuleType) -> None:
    """Check reads, updates, and construction with py.Dict."""
    assert ext.make_user("Ann", 30) == {"name": "Ann", "age": 30, "scores": [9.5, 7.0], "active": True, "visits": 0}

    assert ext.get_age({"age": 5}) == 5
    assert ext.get_age({}) is None
    assert ext.get_age(collections.defaultdict(int)) is None

    assert ext.count_words(["a", "b", "a", "c", "a"]) == {"a": 3, "b": 1, "c": 1}
    assert ext.sum_values({"a": 1, "b": 2.5}) == 3.5
    assert ext.invert({1: "a", 2: "b"}) == {"a": 1, "b": 2}
    assert ext.has({"a": 1}, "a")
    assert not ext.has({}, "a")

    with pytest.raises(TypeError, match="expected dict, got list"):
        ext.get_age([])

    with pytest.raises(TypeError, match="unhashable"):
        ext.count_words([[1]])

    with pytest.raises(TypeError, match="unhashable"):
        ext.has({}, [])


def test_dict_operations(ext: types.ModuleType) -> None:
    """Check dict removal, pop, and clear operations."""
    entries = {"a": 1, "b": 2, "c": 3}
    assert ext.dict_ops(entries) == (True, False, 2, None)
    assert entries == {"c": 3}

    value = [1]
    assert ext.pop_value({"k": value}, "k") is value
    assert ext.pop_value({}, "k") is None

    ext.clear_dict(entries)
    assert entries == {}

    with pytest.raises(TypeError, match="unhashable"):
        ext.pop_value({"k": 1}, [])


def test_dict_pops_hash_once(ext: types.ModuleType) -> None:
    """Check that popping a dict item hashes the key once."""

    class Key:
        """A key that counts how often it's hashed."""

        def __init__(self) -> None:
            """Start counting."""
            self.hashes = 0

        def __hash__(self) -> int:
            """Count the call."""
            self.hashes += 1
            return 42

    key = Key()
    values = {key: "value"}
    key.hashes = 0

    assert ext.pop_value(values, key) == "value"
    assert (key.hashes, values) == (1, {})


def test_sets(ext: types.ModuleType) -> None:
    """Check construction, reads, and supported updates for py.Set and py.FrozenSet."""
    assert ext.small_set() == {1, 2, 3}

    numbers = {1, 2}
    assert ext.change_set(numbers) == (True, True, False, 2)
    assert numbers == {2, 4}

    assert ext.letters() == frozenset({"a", "b"})
    assert type(ext.letters()) is frozenset
    assert ext.empty_frozenset() == frozenset()
    assert ext.frozen_sum(frozenset({1, 2, 3})) == 6
    assert ext.has_item(frozenset({"x"}), "x")
    assert not ext.has_item(frozenset(), "x")

    with pytest.raises(TypeError, match="expected set, got frozenset"):
        ext.change_set(frozenset())

    with pytest.raises(TypeError, match="expected frozenset, got set"):
        ext.frozen_sum({1})

    with pytest.raises(TypeError, match="unhashable"):
        ext.has_item(frozenset(), [])


def test_iterators(ext: types.ModuleType) -> None:
    """Check that py.Iterator reads supported iterables one item at a time."""
    consumed: list[int] = []

    def numbers() -> collections.abc.Iterator[int]:
        """Yield numbers, recording each one."""
        for n in range(5):
            consumed.append(n)
            yield n

    assert ext.iter_sum(numbers()) == 10
    assert ext.iter_sum([1, 2]) == 3
    assert ext.iter_sum({}) == 0
    assert ext.call_iter_sum(lambda: range(4)) == 6

    consumed.clear()
    assert ext.first_two(numbers()) == (0, 1)
    assert consumed == [0, 1]

    o = object()
    assert ext.first_two([o]) == (o, None)
    assert ext.first_two([]) == (None, None)

    items = iter([1, 2, 3])
    assert ext.same_iterator(items) is items


def test_iterator_errors(ext: types.ModuleType) -> None:
    """Check errors during iteration and item conversion."""
    with pytest.raises(ValueError, match="broken generator"):
        ext.iter_sum(helpers.failing_numbers())

    with pytest.raises(TypeError, match="cannot be interpreted as an integer"):
        ext.iter_sum([1, "2"])

    with pytest.raises(TypeError, match="expected an iterable other than str, got str"):
        ext.iter_sum("abc")

    with pytest.raises(TypeError, match="not iterable"):
        ext.iter_sum(5)


def test_tuples(ext: types.ModuleType) -> None:
    """Check construction and reads for tuples with runtime lengths."""
    assert ext.squares_tuple(4) == (0, 1, 4, 9)
    assert ext.squares_tuple(0) == ()
    assert ext.halves_tuple() == (0.5, 1.5)
    assert ext.empty_tuple() == ()

    assert ext.tuple_sum((1, 2.5, 3)) == 6.5
    assert ext.tuple_sum(()) == 0
    assert ext.tuple_sum(Point(1, 2)) == 3

    with pytest.raises(IndexError, match="tuple index out of range"):
        ext.tuple_item((1,), 1)

    with pytest.raises(IndexError, match="tuple index out of range"):
        ext.tuple_item((1,), 2**63)

    with pytest.raises(MemoryError):
        ext.squares_tuple(2**63)

    with pytest.raises(TypeError, match="expected tuple, got list"):
        ext.tuple_sum([1])

    with pytest.raises(SystemError):
        ext.set_shared((1, 2))
