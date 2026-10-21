import array
import collections.abc
import operator
import types
import weakref

import helpers

type Call = collections.abc.Callable[[], object]


class Touchable:
    """An object with a method that Zig calls with keywords."""

    def touch(self, a: int, *, flag: bool = False) -> None:
        """Do nothing."""


def calls(ext: types.ModuleType) -> list[Call]:
    """List successful calls that create, convert, and release objects."""
    return [
        *values(ext),
        *containers(ext),
        *buffers(ext),
        *calling_python(ext),
        *functions(ext),
        *runtime(ext),
        *classes(ext),
        *modules(ext),
    ]


def values(ext: types.ModuleType) -> list[Call]:
    """List calls that convert numbers, bytes, structs, arrays and enums."""
    return [
        lambda: ext.labelled(3),
        lambda: ext.identity128(2**100),
        lambda: ext.reverse(b"abcdef"),
        lambda: ext.describe_user({"name": "Ann", "age": 3}),
        lambda: ext.new_user("Bo", 4),
        lambda: ext.call_user(lambda: {"name": "Cy", "age": 5}),
        lambda: ext.job_total({"data": array.array("d", [1, 2]), "owner": {"name": "Zed"}}),
        lambda: ext.flagged({"owned": True, "value": [1]}),
        lambda: ext.record_value({"value": [1]}, list),
        lambda: ext.call_record(lambda: types.MappingProxyType({"value": [2]})),
        lambda: ext.call_wrapped(lambda: {"obj": [3]}),
        ext.str_array,
        ext.release_array,
        lambda: ext.next_color("red"),
        lambda: ext.color_names(["red", "blue"]),
        lambda: ext.quoted_tag("plain"),
        lambda: ext.raise_level(ext.Level.low),
        ext.levels,
        ext.turn,
        lambda: ext.call_level(lambda: ext.Level.high),
        lambda: ext.wide_value(ext.Wide.m200),
        lambda: ext.wide_member(7),
    ]


def containers(ext: types.ModuleType) -> list[Call]:
    """List calls that create, read, and update containers."""
    return [
        lambda: ext.range(50),
        ext.squares,
        lambda: ext.append_owned([]),
        lambda: ext.list_ops([1, 2, 3]),
        lambda: ext.seq_sum(x for x in range(20)),
        lambda: ext.nested_sum([[1, 2], range(3)]),
        lambda: ext.make_user("Ann", 3),
        lambda: ext.count_words(["a", "b", "c", "a"]),
        lambda: ext.invert({i: str(i) for i in range(10)}),
        lambda: ext.dict_ops({"a": 1, "b": 2}),
        lambda: ext.first_key({"k": 1}),
        ext.small_set,
        lambda: ext.change_set({1, 2, 3}),
        ext.letters,
        lambda: ext.frozen_sum(frozenset(range(10))),
        lambda: ext.iter_sum(x for x in range(20)),
        lambda: ext.first_two(x for x in range(5)),
        lambda: ext.call_iter_sum(lambda: range(4)),
        lambda: ext.squares_tuple(10),
        lambda: ext.tuple_sum((1, 2, 3)),
        ext.halves_tuple,
        lambda: ext.read_then_call([[1]], list),
        lambda: ext.lookup_then_call({"k": [1]}, "k", list),
        lambda: ext.total_length(["ab", "cde"]),
        lambda: ext.scoped_reads([[1]], 10, list),
        lambda: ext.nested_scopes([[1]], list),
    ]


def buffers(ext: types.ModuleType) -> list[Call]:
    """List calls that view contiguous, strided and bool buffers."""
    not_contiguous = ext.malformed_exporter("not_contiguous")

    return [
        lambda: ext.buf_sum(array.array("d", [1, 2, 3])),
        lambda: ext.byte_sum(b"abc"),
        lambda: ext.strided_sum(memoryview(array.array("d", range(10)))[::2]),
        lambda: ext.strided_layout(memoryview(bytes(12)).cast("B", [3, 4])),
        lambda: ext.strided_sum(not_contiguous),
        lambda: ext.true_count(memoryview(bytearray(b"\x01\x00")).cast("?")),
    ]


def calling_python(ext: types.ModuleType) -> list[Call]:
    """List calls that access Python attributes, call functions, handle exceptions, or run code."""
    return [
        lambda: ext.call_two(operator.add, 1, 2),
        lambda: ext.call_kw(helpers.record, 3),
        lambda: ext.call_pair(lambda: (1, "x")),
        lambda: ext.call_method([3, 1], "count", 1),
        lambda: ext.call_keywords_repeatedly(helpers.record, 3),
        lambda: ext.call_method_keywords_repeatedly(Touchable(), 3),
        lambda: ext.get_attr(types.SimpleNamespace(x=[1]), "x"),
        lambda: ext.json_dumps({"a": [1, 2]}),
        lambda: ext.get_or_none({}, "missing"),
        lambda: ext.describe(helpers.raiser(KeyError("k"))),
        lambda: ext.run_in_namespace("items = [base] * 3"),
        lambda: ext.eval_in_namespace({"x": 1}, "x + 1"),
        lambda: ext.eval_code("[1, 2]"),
    ]


def functions(ext: types.ModuleType) -> list[Call]:
    """List calls with keywords, defaults and extra arguments."""
    return [
        lambda: ext.greet("Ann", loud=True),
        lambda: ext.greet("Ann", **{"".join(["greet", "ing"]): "Hi"}),
        ext.with_defaults,
        ext.unicode_default,
        lambda: ext.collect(1, 2, 3, flag=True, x=4),
        lambda: ext.kwarg_names(a=1, b=2),
        lambda: ext.keyword_sum(1, 2, c=3, d=4),
    ]


def runtime(ext: types.ModuleType) -> list[Call]:
    """List calls using allocators, releasing the GIL, or running in Zig threads."""
    return [
        lambda: ext.join_numbers(range(10)),
        lambda: ext.sum_without_gil(array.array("d", [1, 2]), 2),
        lambda: ext.call_from_thread(list),
        lambda: ext.nested_gil(dict),
    ]


def classes(ext: types.ModuleType) -> list[Call]:
    """List calls that create and use class instances."""
    holder = type("Holder", (), {"value": ext.Slot(), "fixed": ext.Fixed(1)})()

    def use_descriptors() -> None:
        """Read, write, and delete descriptor attributes on `holder`."""
        holder.value = [2]
        _ = holder.value, holder.fixed
        del holder.value

    return [
        lambda: ext.Point(3, 4).norm(),
        lambda: ext.Point(1, 2) + ext.Point(3, 4) * 2,
        lambda: repr(ext.Point(1, 2)),
        lambda: hash(ext.Point(1, 2)),
        lambda: ext.Point.hypot(3.0, dy=4.0),
        lambda: ext.midpoint(ext.Point(0), ext.Point(2)),
        ext.point_pair,
        lambda: ext.new_instance(1).scaled(2),
        lambda: ext.total_x([ext.Point(1), ext.Point(2)]),
        lambda: list(ext.Bag(range(10))),
        lambda: memoryview(ext.Bag([1, 2])).tolist(),
        lambda: ext.make_bag(5).total(),
        lambda: ext.Node(ext.Node([1])).next,
        lambda: ext.value_after_call(ext.Node([1]), list),
        lambda: ext.Node([1]).value_after(list),
        lambda: ext.Node([1]).release_value(),
        lambda: ext.Courier({"label": {"function": str}, "item": [1]}).parcel_copy(),
        lambda: ext.hold_parcel({"label": {"function": str}, "item": [1]}),
        lambda: ext.Pair([1], [2]).items,
        lambda: ext.Counter(step=2)(3),
        lambda: ext.Tracker(int),
        lambda: ext.Shape("a", 3).describe(),
        lambda: ext.label_length(ext.Shape("a", 3)),
        lambda: ext.Shape.triangle("t").describe(),
        lambda: ext.build_shape(ext.Square, "s", 2),
        lambda: ext.Prism(ext.Square("p", 2), 2).describe(),
        lambda: ext.relabel(ext.Square("a", 1), "b"),
        lambda: (ext.Positions()[-1], list(ext.Positions()), ext.Labels()["last"]),
        lambda: make_cycle(ext),
        lambda: use_tag(ext),
        lambda: use_operators(ext),
        lambda: use_attribute_hooks(ext),
        use_descriptors,
        lambda: use_subclasses(ext),
    ]


def modules(ext: types.ModuleType) -> list[Call]:
    """List calls that use module state, submodules and custom exceptions."""
    return [
        lambda: ext.remember("key", [1, 2]),
        lambda: ext.recall("key"),
        lambda: ext.sub.point(1),
        lambda: ext.parse_number("12"),
    ]


def make_cycle(ext: types.ModuleType) -> None:
    """Create a reference cycle through two instances."""
    first = ext.Node([1])
    first.next = ext.Node(2, first)


def use_tag(ext: types.ModuleType) -> None:
    """Exercise weak references and instance attributes in a reference cycle."""
    tag = ext.Tag("a")
    tag.me = tag
    tag.items = [1]
    weakref.ref(tag, lambda _: None)


def use_operators(ext: types.ModuleType) -> None:
    """Use in-place operators, pow and divmod."""
    number = ext.Number(2)
    number += 3
    number -= ext.Number(1)
    number **= 2
    number *= 2

    divmod(number, 3)
    pow(number, 2, 5)
    _ = 2 ** ext.Number(3)


def use_attribute_hooks(ext: types.ModuleType) -> None:
    """Read, write, and delete attributes through custom hooks."""
    record = ext.Record(1)
    record.color = [1]
    _ = record.color
    del record.color


def use_subclasses(ext: types.ModuleType) -> None:
    """Use class methods and inherited operators, buffers, dictionaries, and finalizers."""
    score = ext.Score(2)
    score += 1
    _ = score + 1, 1 + score, score == ext.Number(3)

    stack = ext.Stack()
    stack.append(1)
    memoryview(stack).release()
    stack.pop()

    badge = ext.Badge("b")
    badge.me = badge
    ext.Alarm(int).__del__()
    _ = ext.Stack[int], ext.Counter.from_calls()

    marker, reflected = ext.Marker(), ext.ReflectedMarker()
    _ = marker + reflected, marker - ext.PlainMarker(), ext.ForwardMarker() ** marker, marker - reflected
    _ = list(ext.DoubleCountdown(3)), ext.Countdown.starting(cls=1)
