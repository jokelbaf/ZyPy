import collections.abc
import itertools
import operator
import types
import typing

import library.fuzzing.calls

UNARY: typing.Final = (repr, str, hash, len, bool, operator.neg, operator.pos, abs, operator.invert, int, float)

BINARY: typing.Final = (
    operator.add,
    operator.sub,
    operator.mul,
    operator.matmul,
    operator.truediv,
    operator.floordiv,
    operator.mod,
    operator.pow,
    operator.lshift,
    operator.rshift,
    operator.and_,
    operator.or_,
    operator.xor,
    divmod,
    operator.eq,
    operator.ne,
    operator.lt,
    operator.le,
    operator.gt,
    operator.ge,
    operator.getitem,
    operator.contains,
    operator.iadd,
    operator.isub,
    operator.imul,
    operator.ipow,
    operator.imod,
    operator.ior,
)

ATTRIBUTES: typing.Final = ("x", "y", "count", "step", "name", "label", "value", "next", "items", "level", "rings", "z")


def make(ext: types.ModuleType, cls: type) -> object:
    """Create an instance of `cls` with known valid arguments, or return None on failure."""
    makers: dict[type, collections.abc.Callable[[], object]] = {
        ext.Point: lambda: ext.Point(1.0, 2.0),
        ext.Shape: lambda: ext.Shape("s", 3),
        ext.Square: lambda: ext.Square("s", 2.0),
        ext.Prism: lambda: ext.Prism(ext.Square("p", 1.0), 2.0),
        ext.Node: lambda: ext.Node([1]),
        ext.Bag: lambda: ext.Bag([1, 2]),
        ext.BagIterator: lambda: iter(ext.Bag([1, 2])),
        ext.Handle: lambda: ext.open_handle(1),
        ext.Tag: lambda: ext.Tag("t"),
        ext.Badge: lambda: ext.Badge("b"),
        ext.Number: lambda: ext.Number(2),
        ext.Score: lambda: ext.Score(2),
        ext.Record: lambda: ext.Record(1),
        ext.Fixed: lambda: ext.Fixed(1),
        ext.Tracker: lambda: ext.Tracker(int),
        ext.Alarm: lambda: ext.Alarm(int),
        ext.Pair: lambda: ext.Pair([1], [2]),
        ext.Countdown: lambda: ext.Countdown(3),
        ext.DoubleCountdown: lambda: ext.DoubleCountdown(3),
    }

    return library.fuzzing.calls.attempt(makers.get(cls, cls))


def exercise(instance: object, operands: tuple[object, object, object]) -> None:
    """Exercise operators, items, attributes, buffers, iteration, and descriptors on `instance`."""
    first, second, third = operands

    use_operators(instance, first, second)
    use_items(instance, first, second)
    iterate(instance)
    library.fuzzing.calls.attempt(memoryview, instance)
    use_attributes(instance, third)
    use_as_descriptor(instance, first)


def use_operators(instance: object, operand: object, modulo: object) -> None:
    """Exercise operators and calls on `instance`, trying both operand orders."""
    for apply in UNARY:
        library.fuzzing.calls.attempt(apply, instance)

    for apply in BINARY:
        library.fuzzing.calls.attempt(apply, instance, operand)
        library.fuzzing.calls.attempt(apply, operand, instance)

    library.fuzzing.calls.attempt(pow, instance, operand, modulo)
    library.fuzzing.calls.attempt(instance, operand)


def use_items(instance: object, key: object, value: object) -> None:
    """Set and delete an item of `instance`."""
    library.fuzzing.calls.attempt(operator.setitem, instance, key, value)
    library.fuzzing.calls.attempt(operator.delitem, instance, key)


def iterate(instance: object) -> None:
    """Read at most 50 items from `instance` to avoid infinite iteration."""
    iterator = library.fuzzing.calls.attempt(iter, instance)
    if isinstance(iterator, collections.abc.Iterator):
        items = typing.cast("collections.abc.Iterator[object]", iterator)
        library.fuzzing.calls.attempt(list, itertools.islice(items, 50))


def use_attributes(instance: object, value: object) -> None:
    """Read, write, and delete known test attributes on `instance`."""
    for name in ATTRIBUTES:
        library.fuzzing.calls.attempt(getattr, instance, name)
        library.fuzzing.calls.attempt(setattr, instance, name, value)
        library.fuzzing.calls.attempt(delattr, instance, name)


def use_as_descriptor(instance: object, value: object) -> None:
    """Use `instance` as a descriptor and exercise attribute reads, writes, and deletion."""
    owner = library.fuzzing.calls.attempt(type, "Owner", (), {"attribute": instance})
    if not isinstance(owner, type):
        return

    holder = library.fuzzing.calls.attempt(owner)
    library.fuzzing.calls.attempt(getattr, owner, "attribute")
    library.fuzzing.calls.attempt(getattr, holder, "attribute")
    library.fuzzing.calls.attempt(setattr, holder, "attribute", value)
    library.fuzzing.calls.attempt(delattr, holder, "attribute")
