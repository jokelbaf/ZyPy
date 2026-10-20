import array
import collections
import collections.abc
import sys
import types

import pytest


def test_basic_types(ext: types.ModuleType) -> None:
    """Check conversions for integers, floats, bools, and void."""
    assert ext.add(2, 3) == 5
    assert ext.add(-(2**62), 2**62) == 0
    assert ext.add_u8(250, 10) == 4
    assert ext.half(3) == 1.5
    assert ext.negate(True) is False
    assert ext.negate([]) is True
    assert ext.nothing() is None


def test_int_range(ext: types.ModuleType) -> None:
    """Check integer range validation against the Zig type."""
    with pytest.raises(OverflowError, match="out of range for i64"):
        ext.add(2**63, 0)

    with pytest.raises(ValueError, match="negative"):
        ext.add_u8(-1, 0)

    with pytest.raises(OverflowError, match="out of range for u8"):
        ext.add_u8(256, 0)


def test_wide_ints(ext: types.ModuleType) -> None:
    """Check conversions of integers wider than 64 bits."""
    for value in (2**100, -(2**127), 2**127 - 1, 0, -1):
        assert ext.identity128(value) == value

    with pytest.raises(OverflowError):
        ext.identity128(2**127)


def test_zero_bit_ints(ext: types.ModuleType) -> None:
    """Check that u0 accepts only zero."""
    assert ext.zero(0) == 0

    with pytest.raises(OverflowError, match="out of range for u0"):
        ext.zero(1)

    with pytest.raises(ValueError, match="negative"):
        ext.zero(-1)


def test_optionals_and_tuples(ext: types.ModuleType) -> None:
    """Check optional and tuple conversions."""
    assert ext.or_default(None) == -1
    assert ext.or_default(5) == 5
    assert ext.maybe(True) == 42
    assert ext.maybe(False) is None

    assert ext.swap((1, "a")) == ("a", 1)
    assert ext.labelled(5) == ("label", 5)

    with pytest.raises(TypeError, match="expected tuple of length 2, got 3"):
        ext.swap((1, "a", 2))

    with pytest.raises(TypeError, match="expected tuple, got list"):
        ext.swap([1, "a"])


def test_errors(ext: types.ModuleType) -> None:
    """Check that Zig errors become Python exceptions."""
    with pytest.raises(ValueError, match="bad value"):
        ext.fail(0)

    with pytest.raises(MemoryError):
        ext.fail(1)

    with pytest.raises(RuntimeError, match="SomethingBroke"):
        ext.fail(2)


def test_default_error_mappings(ext: types.ModuleType) -> None:
    """Check that overflow and division by zero raise the matching Python exceptions."""
    assert ext.add(2**63 - 2, 1) == ext.quotient(2**63 - 1, 1) == 2**63 - 1

    with pytest.raises(OverflowError, match=r"^Overflow$"):
        ext.add(2**63 - 1, 1)

    with pytest.raises(OverflowError, match=r"^Overflow$"):
        ext.quotient(-(2**63), -1)

    with pytest.raises(ZeroDivisionError, match=r"^DivisionByZero$"):
        ext.quotient(1, 0)


@pytest.mark.parametrize("text", ["a", "é", "中", "\U0001d11e", "a中"])
def test_long_formatted_messages(ext: types.ModuleType, text: str) -> None:
    """Check that long error messages are truncated at a UTF-8 boundary and end with `...`."""
    with pytest.raises(ValueError, match=r"\.\.\.$") as raised:
        ext.raise_repeated(text, 600)

    message = str(raised.value)
    assert message.startswith(text * 10)
    assert len(message.removesuffix("...").encode()) > 504
    assert len(message.encode()) <= 511


def test_objects(ext: types.ModuleType) -> None:
    """Check py.Object conversion to and from Python objects."""
    o = object()
    assert ext.identity(o) is o
    assert ext.is_none(None)
    assert not ext.is_none(0)
    assert ext.as_int(7) == 7

    with pytest.raises(TypeError):
        ext.as_int("7")


def test_strings(ext: types.ModuleType) -> None:
    """Check UTF-8 string access and conversion of string literals."""
    assert ext.str_len("héllo") == 6
    assert ext.greeting() == "hello"

    with pytest.raises(TypeError, match="expected str, got bytes"):
        ext.str_len(b"x")


def test_bytes(ext: types.ModuleType) -> None:
    """Check conversion of byte slices and py.Bytes."""
    assert ext.reverse(b"abc") == b"cba"
    assert ext.echo_bytes(b"\x00\xff") == b"\x00\xff"

    with pytest.raises(TypeError, match="expected bytes, got str"):
        ext.reverse("abc")


def test_structs(ext: types.ModuleType) -> None:
    """Check conversions between Zig structs and Python mappings."""
    full = {"name": "Ann", "age": 3, "email": "a@b.c", "active": False, "extra": 1}
    assert ext.describe_user({"name": "Ann", "age": 3}) == ("Ann", 3, None, True)
    assert ext.describe_user(full) == ("Ann", 3, "a@b.c", False)
    assert ext.describe_user(types.MappingProxyType({"name": "Ann", "age": 3})) == ("Ann", 3, None, True)

    assert ext.new_user("Bo", 4) == {"name": "Bo", "age": 4, "email": None, "active": True}
    assert ext.call_user(lambda: {"name": "Cy", "age": 5}) == {"name": "Cy", "age": 5, "email": None, "active": True}

    users = collections.defaultdict(lambda: "missing", {"name": "Ann", "age": 1})
    ext.describe_user(users)
    assert dict(users) == {"name": "Ann", "age": 1}

    with pytest.raises(KeyError, match="'age'"):
        ext.describe_user({"name": "Ann"})

    with pytest.raises(TypeError, match="expected a mapping, got list"):
        ext.describe_user([("name", "Ann")])

    with pytest.raises(TypeError, match="expected str, got int"):
        ext.describe_user({"name": 1, "age": 2})


def test_struct_fields_keep_their_values(ext: types.ModuleType) -> None:
    """Check that struct fields retain values created during mapping lookups."""
    events: list[str] = []

    class Item:
        """An object that records when it's freed."""

        def __del__(self) -> None:
            """Record the release."""
            events.append("released")

    class Fresh(collections.abc.Mapping[str, object]):
        """A mapping that creates a new value on each lookup."""

        def __getitem__(self, key: str) -> object:
            """Create the value for `key`."""
            if key != "value":
                raise KeyError(key)

            return Item()

        def __iter__(self) -> collections.abc.Iterator[str]:
            """Iterate over the keys."""
            return iter(["value"])

        def __len__(self) -> int:
            """Count the keys."""
            return 1

    value, observed = ext.record_value(Fresh(), lambda: list(events))
    assert isinstance(value, Item)
    assert observed == []
    assert isinstance(ext.call_record(Fresh), Item)


def test_fields_named_owned(ext: types.ModuleType) -> None:
    """Check that an ordinary field named `owned` does not affect ownership handling."""
    value = object()
    before = sys.getrefcount(value)

    assert ext.flagged({"owned": True, "value": value}) == (True, value)
    assert ext.flagged({"owned": False, "value": value}) == (False, value)
    assert sys.getrefcount(value) == before


def test_records_with_an_obj_field(ext: types.ModuleType) -> None:
    """Check that a plain struct with an `obj` field converts from a mapping."""
    child = object()
    mapping = {"obj": child}
    before = sys.getrefcount(mapping), sys.getrefcount(child)

    for _ in range(100):
        assert ext.call_wrapped(lambda: mapping) is child

    assert (sys.getrefcount(mapping), sys.getrefcount(child)) == before


def test_arrays(ext: types.ModuleType) -> None:
    """Check array-to-list conversion and cleanup of object items."""
    assert ext.str_array() == ["one", "two"]
    assert ext.release_array() is None


def test_struct_fields_are_released(ext: types.ModuleType) -> None:
    """Check that struct field views are released after calls and failed conversions."""
    data = array.array("d", [1, 2])
    assert ext.job_total({"data": data, "weight": 2, "owner": {"name": "Zed"}}) == (6, "Zed", False)
    assert ext.job_total({"data": data, "owner": {"name": "Zed", "admin": True}}) == (3, "Zed", True)

    with pytest.raises(TypeError, match="must be real number"):
        ext.job_total({"data": data, "weight": "heavy", "owner": {"name": "Zed"}})

    with pytest.raises(KeyError, match="'name'"):
        ext.job_total({"data": data, "owner": {}})

    data.append(3)
