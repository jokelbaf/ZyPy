import types
import weakref

import pytest


def test_attribute_hooks(ext: types.ModuleType) -> None:
    """Check missing-attribute hooks and fallback behavior for assignment and deletion."""
    record = ext.Record(1)
    record.color = "red"
    assert record.color == "red"

    record.id = 5
    assert record.id == 5

    with pytest.raises(AttributeError, match=r"^'zypy_tests.Record' object has no attribute 'size'$"):
        _ = record.size

    assert getattr(record, "size", None) is None
    assert hasattr(record, "color")

    del record.color
    assert not hasattr(record, "color")

    with pytest.raises(AttributeError, match=r"^Record has no attribute 'color' to delete$"):
        del record.color

    with pytest.raises(TypeError, match="cannot be interpreted as an integer"):
        record.id = "five"


def test_direct_attribute_hook_calls(ext: types.ModuleType) -> None:
    """Check calls of __getattr__ and __getattribute__ through the class."""
    record = ext.Record(1)
    record.color = "red"
    assert ext.Record.__getattr__(record, "color") == "red"
    assert ext.Record.__getattribute__(record, "id") == 1

    with pytest.raises(AttributeError, match=r"^'zypy_tests.Record' object has no attribute 'size'$"):
        ext.Record.__getattr__(record, "size")

    with pytest.raises(TypeError, match=r"^attribute name must be string, not 'int'$"):
        ext.Record.__getattr__(record, 5)

    with pytest.raises(AttributeError):
        ext.Record.__getattribute__(record, "color")


def test_attribute_hooks_of_subclasses(ext: types.ModuleType) -> None:
    """Check that subclasses can override, call, and inherit __getattr__."""

    class Defaulted(ext.Record):
        """A record with a default size."""

        def __getattr__(self, name: str) -> object:
            """Get the size, or ask the Zig hook for other names."""
            return 0 if name == "size" else super().__getattr__(name)

    class Inherited(ext.Record):
        """A record that keeps the Zig hooks."""

    defaulted = Defaulted(2)
    defaulted.color = "blue"
    assert (defaulted.size, defaulted.color, defaulted.id) == (0, "blue", 2)

    with pytest.raises(AttributeError, match="has no attribute 'shape'"):
        _ = defaulted.shape

    inherited = Inherited(3)
    inherited.color = "green"
    assert (inherited.color, getattr(inherited, "size", None)) == ("green", None)


def test_descriptors(ext: types.ModuleType) -> None:
    """Check classes that implement the descriptor protocol."""
    slot = ext.Slot()

    class Holder:
        """A class with descriptor attributes."""

        value = slot
        fixed = ext.Fixed(7)

    holder = Holder()
    assert Holder.value is Holder

    with pytest.raises(AttributeError, match=r"^the slot is empty$"):
        _ = holder.value

    holder.value = [1]
    assert holder.value == [1]
    assert Holder().value == [1]

    del holder.value
    with pytest.raises(AttributeError, match=r"^the slot is empty$"):
        _ = holder.value

    assert slot.reads == 5

    assert holder.fixed == 7
    holder.fixed = 8
    assert Holder.fixed == 8

    with pytest.raises(TypeError):
        holder.fixed = "eight"

    with pytest.raises(AttributeError, match=r"^'zypy_tests.Fixed' object has no attribute '__delete__'$"):
        del holder.fixed

    assert ext.Fixed(7).__get__(object()) == 7


def test_weak_references_and_dicts(ext: types.ModuleType) -> None:
    """Check instances of classes with .weak_references and .dict."""
    tag = ext.Tag("a")
    reference = weakref.ref(tag)
    assert reference() is tag

    tag.color = "red"
    assert tag.color == "red"
    assert tag.__dict__ == {"color": "red"}

    tag.__dict__ = {"size": 3}
    assert tag.size == 3

    with pytest.raises(AttributeError, match=r"'zypy_tests.Tag' object has no attribute 'color'"):
        _ = tag.color

    called: list[object] = []
    callback = weakref.ref(tag, called.append)
    del tag
    assert reference() is None
    assert called == [callback]

    with pytest.raises(TypeError, match=r"cannot create weak reference to 'zypy_tests.Point' object"):
        weakref.ref(ext.Point(1))


def test_weak_references_and_dicts_of_python_subclasses(ext: types.ModuleType) -> None:
    """Check that Python subclasses use the dict and weak references of the Zig class."""

    class Labelled(ext.Tag):
        """A Python subclass using the base class's dict and weak references."""

    labelled = Labelled("b")
    labelled.extra = [1]
    reference = weakref.ref(labelled)
    assert weakref.WeakValueDictionary({"x": labelled})["x"] is labelled

    del labelled
    assert reference() is None
