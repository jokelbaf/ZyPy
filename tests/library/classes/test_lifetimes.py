import gc
import sys
import types
import weakref

import pytest

import helpers


def test_finalizers(ext: types.ModuleType) -> None:
    """Check that finalizers run once."""
    calls: list[int] = []
    tracker = ext.Tracker(lambda: calls.append(len(calls)))
    assert calls == []

    del tracker
    assert calls == [0]


def test_finalizer_errors_are_unraisable(ext: types.ModuleType) -> None:
    """Check that exceptions raised by finalizers go to sys.unraisablehook."""

    def fail() -> None:
        """Raise an error from the finalizer."""
        raise LookupError("finalizer")

    reported: list[BaseException | None] = []
    previous = sys.unraisablehook
    sys.unraisablehook = lambda report: reported.append(report.exc_value)
    try:
        ext.Tracker(fail)
    finally:
        sys.unraisablehook = previous

    assert len(reported) == 1
    assert isinstance(reported[0], LookupError)


def test_explicit_finalizer_calls(ext: types.ModuleType) -> None:
    """Check that explicit __del__ calls propagate errors without preventing later finalization."""
    calls: list[int] = []
    alarm = ext.Alarm(lambda: calls.append(1))
    ext.Tracker.__del__(alarm)
    alarm.__del__()
    assert (calls, alarm.rings) == ([1, 1], 0)

    del alarm
    assert calls == [1, 1, 1]

    failures = [LookupError("explicit")]

    def fail_once() -> None:
        """Raise an error the first time."""
        if failures:
            raise failures.pop()

    tracker = ext.Tracker(fail_once)
    with pytest.raises(LookupError, match=r"^explicit$"):
        tracker.__del__()


def test_reference_cycles(ext: types.ModuleType) -> None:
    """Check garbage collection of cycles containing class instances."""
    calls: list[int] = []
    first = ext.Node(ext.Tracker(lambda: calls.append(1)))
    second = ext.Node(2, first)
    first.next = second

    del first, second
    assert calls == []

    gc.collect()
    assert calls == [1]


def test_fields_with_custom_conversions(ext: types.ModuleType) -> None:
    """Check cleanup and cycle collection for fields with a custom toPython conversion."""

    def label() -> str:
        """Return the parcel's label."""
        return "label"

    before = sys.getrefcount(label)
    for _ in range(1000):
        ext.Courier({"label": {"function": label}, "item": None})
        ext.hold_parcel({"label": {"function": label}, "item": None})

    assert sys.getrefcount(label) == before

    courier = ext.Courier({"label": {"function": label}, "item": None})
    courier.parcel = {"label": {"function": courier.parcel_copy}, "item": None}
    reference = weakref.ref(courier)

    del courier
    gc.collect()

    assert reference() is None


def test_iterators_keep_their_container(ext: types.ModuleType) -> None:
    """Check that an iterator keeps the instance it iterates over alive."""
    bag = ext.Bag([1])
    iterator = iter(bag)

    del bag
    assert list(iterator) == [1]


def test_dict_cycles(ext: types.ModuleType) -> None:
    """Check that the garbage collector sees references held by an instance's __dict__."""
    tag = ext.Tag("cycle")
    tag.me = tag
    tag.value = helpers.Item()
    item = weakref.ref(tag.value)
    reference = weakref.ref(tag)

    del tag
    gc.collect()

    assert reference() is None
    assert item() is None


def test_instance_reference_counts(ext: types.ModuleType) -> None:
    """Check reference counts across method calls, properties, and field access."""
    value = object()
    name = "name-" + str(id(value))
    node = ext.Node(value)
    shape = ext.Shape(name, 3)
    before = [sys.getrefcount(x) for x in (value, name, node, shape)]

    for _ in range(1000):
        assert node.value is value
        node.value = value
        node.next = node
        node.next = None

        assert shape.label is name
        shape.label = name
        shape.describe()

        ext.Node(value, value)
        ext.Shape(name, 1)
        ext.call_point(lambda: ext.Point(0))

        with pytest.raises(TypeError):
            ext.midpoint(value, ext.Point(0))

        with pytest.raises(TypeError):
            ext.Shape(value, 1)

    assert [sys.getrefcount(x) for x in (value, name, node, shape)] == before
