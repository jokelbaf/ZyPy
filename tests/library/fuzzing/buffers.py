import array
import collections.abc
import typing

import hypothesis.strategies

TYPECODES: typing.Final = "bBhHiIlLqQfd"


def buffers() -> hypothesis.strategies.SearchStrategy[object]:
    """Generate varied buffer layouts, including read-only data and invalid bool values."""
    arrays = hypothesis.strategies.builds(
        filled_array, hypothesis.strategies.sampled_from(TYPECODES), hypothesis.strategies.binary(max_size=48)
    )
    data = hypothesis.strategies.binary(max_size=24)

    return hypothesis.strategies.one_of(
        arrays,
        arrays.map(memoryview),
        arrays.map(lambda items: memoryview(items)[::2]),
        arrays.map(lambda items: memoryview(items)[::-1]),
        data.map(bytearray),
        data.map(lambda raw: memoryview(raw).toreadonly()),
        data.map(lambda raw: memoryview(bytearray(raw)).cast("?")),
        fresh(
            lambda: memoryview(bytearray(24)).cast("B", [2, 3, 4]),
            lambda: memoryview(bytearray(24)).cast("d", [3, 1]),
            lambda: memoryview(array.array("h", range(8)))[1::3],
            lambda: memoryview(bytes(8)).cast("d", []),
        ),
    )


def filled_array(typecode: str, data: bytes) -> array.array[typing.Any]:
    """Create an array of `typecode` from the complete items in `data`."""
    items = array.array(typecode)
    items.frombytes(data[: len(data) - len(data) % items.itemsize])
    return items


def fresh(*makers: collections.abc.Callable[[], object]) -> hypothesis.strategies.SearchStrategy[object]:
    """Create a fresh buffer for each generated example."""
    return hypothesis.strategies.sampled_from(makers).map(lambda make: make())
