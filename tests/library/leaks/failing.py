import array
import collections.abc
import types
import typing

import helpers

type Call = collections.abc.Callable[[], object]

ERRORS: typing.Final = (
    TypeError,
    RuntimeError,
    LookupError,
    ImportError,
    ValueError,
    BufferError,
    AttributeError,
    ArithmeticError,
)


def calls(ext: types.ModuleType) -> list[Call]:
    """List calls expected to raise one of ERRORS."""
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
    """List calls with invalid values or returned Zig errors."""
    return [
        lambda: ext.fail(2),
        lambda: ext.add(2**63 - 1, 1),
        lambda: ext.quotient(1, 0),
        lambda: ext.raise_bytes(b"\xff"),
        lambda: ext.describe_user({"name": "Ann"}),
        lambda: ext.describe_user({"age": 1, "name": 2}),
        lambda: ext.job_total({"data": array.array("d", [1]), "weight": "x", "owner": {}}),
        lambda: ext.next_color("purple"),
        lambda: ext.raise_level("low"),
        lambda: ext.wide_value(object.__new__(ext.Wide)),
    ]


def containers(ext: types.ModuleType) -> list[Call]:
    """List calls with invalid containers, items, or indexes."""
    return [
        lambda: ext.seq_sum("abc"),
        lambda: ext.nested_sum([[1], 2]),
        lambda: ext.iter_sum(helpers.failing_numbers()),
        lambda: ext.iter_sum([1, "2"]),
        lambda: ext.pop_at([], 0),
        lambda: ext.list_item([], 2**63),
        lambda: ext.tuple_item((), 0),
        lambda: ext.first_key({"k": "not a number"}),
    ]


def buffers(ext: types.ModuleType) -> list[Call]:
    """List calls with buffers that ZyPy rejects."""
    wrong_length = ext.malformed_exporter("wrong_length")
    negative_strides = ext.malformed_exporter("negative_strides")

    return [
        lambda: ext.buf_sum(wrong_length),
        lambda: ext.strided_sum(negative_strides),
        lambda: ext.strided_true_count(memoryview(bytearray(b"\x03")).cast("?")),
    ]


def calling_python(ext: types.ModuleType) -> list[Call]:
    """List calls in which Python functions, imports, or executed code fail."""
    return [
        lambda: ext.call_list(lambda: (1,)),
        lambda: ext.import_module(""),
        lambda: ext.reraise_lookup_error(helpers.raiser(KeyError("k"))),
        lambda: ext.eval_in_namespace({}, "'text'"),
    ]


def functions(ext: types.ModuleType) -> list[Call]:
    """List calls with invalid arguments or mapped Zig errors."""
    return [
        lambda: ext.bind(1),
        lambda: ext.bind(1, 2, x=1),
        lambda: ext.collect(1, first=2, x=3),
        lambda: ext.with_defaults(items=5),
        lambda: ext.parse(1),
    ]


def runtime(ext: types.ModuleType) -> list[Call]:
    """List calls that fail in Zig threads."""
    return [
        lambda: ext.call_from_thread(helpers.raiser(KeyError("k"))),
    ]


def classes(ext: types.ModuleType) -> list[Call]:
    """List calls that fail during instance creation or use."""
    return [
        ext.Point,
        lambda: ext.Point(1, z=2),
        lambda: ext.Point.hypot(3.0, dz=4.0),
        lambda: ext.midpoint(1, ext.Point(0)),
        lambda: ext.Bag([1])[5],
        lambda: ext.Stack().pop(),
        lambda: ext.Shape("a", -1),
        lambda: ext.Square.triangle("s"),
        lambda: ext.build_shape(int, "x", 1),
        lambda: ext.Positions()["first"],
        lambda: list(ext.Labels()),
        lambda: ext.Record(1).missing,
        lambda: ext.Number(1) + "x",
        lambda: hash(ext.Score(1)),
    ]


def modules(ext: types.ModuleType) -> list[Call]:
    """List calls that raise custom exceptions."""
    return [
        lambda: ext.parse_number("x"),
        lambda: ext.limit(11),
    ]
