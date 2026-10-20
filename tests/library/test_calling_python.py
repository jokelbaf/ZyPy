import array
import collections.abc
import json
import operator
import os
import sys
import types

import pytest

import helpers


def test_attributes(ext: types.ModuleType) -> None:
    """Check attribute reads, writes, existence checks, and deletion."""
    holder = types.SimpleNamespace(count=3)
    assert ext.get_attr(holder, "count") == 3
    assert ext.attr_count(holder) == 3

    ext.set_attr(holder, "name", "Ann")
    assert holder.name == "Ann"
    assert ext.has_attr(holder, "name")

    ext.del_attr(holder, "name")
    assert not ext.has_attr(holder, "name")

    with pytest.raises(AttributeError, match="nope"):
        ext.get_attr(holder, "nope")

    with pytest.raises(AttributeError, match="nope"):
        ext.del_attr(holder, "nope")

    with pytest.raises(TypeError, match="cannot be interpreted as an integer"):
        ext.attr_count(types.SimpleNamespace(count="3"))


def test_attribute_checks_raise_other_errors(ext: types.ModuleType) -> None:
    """Check that attribute existence checks raise errors other than AttributeError."""

    class Broken:
        """An object whose attribute lookup raises ValueError."""

        @property
        def bad(self) -> int:
            """Raise ValueError."""
            raise ValueError("broken")

    with pytest.raises(ValueError, match="broken"):
        ext.has_attr(Broken(), "bad")


def test_calls(ext: types.ModuleType) -> None:
    """Check calls to Python functions and methods with positional and keyword arguments."""
    assert ext.call_no_args(helpers.record) == ((), {})
    assert ext.call_two(operator.add, 2, 3) == 5
    assert ext.call_two(helpers.record, "a", None) == (("a", None), {})
    assert ext.call_kw(helpers.record, 3) == ((3, "positional"), {"scale": 10, "label": "z", "flag": None})

    assert ext.call_method([1, 2, 1], "count", 1) == 2
    assert ext.call_method("a,b", "split", ",") == ["a", "b"]
    assert ext.call_method(types.SimpleNamespace(negate=operator.neg), "negate", 4) == -4

    items = [2, 3, 1]
    assert ext.sort_descending(items) is None
    assert items == [3, 2, 1]

    with pytest.raises(ZeroDivisionError):
        ext.call_two(operator.truediv, 1, 0)

    with pytest.raises(TypeError, match="not callable"):
        ext.call_no_args(5)

    with pytest.raises(AttributeError, match="nope"):
        ext.call_method([], "nope", 1)


def test_call_results(ext: types.ModuleType) -> None:
    """Check result conversion and cleanup when conversion fails."""
    assert ext.call_int(lambda: 7) == 7
    assert ext.call_list(lambda: [1]) == [1]
    assert ext.call_pair(lambda: (1, "x")) == (1, "x")
    assert ext.call_optional(lambda: None) is None
    assert ext.call_optional(lambda: "s") == "s"
    assert ext.call_seq_sum(lambda: (x for x in range(4))) == 6

    a = array.array("d", [1, 2])
    assert ext.call_buf_sum(lambda: a) == 3
    a.append(3)

    with pytest.raises(TypeError, match="cannot be interpreted as an integer"):
        ext.call_int(lambda: "7")

    with pytest.raises(TypeError, match="expected list, got tuple"):
        ext.call_list(lambda: (1,))

    with pytest.raises(TypeError, match="expected str, got int"):
        ext.call_pair(lambda: (1, 2))


def test_imports(ext: types.ModuleType) -> None:
    """Check module and submodule imports, including errors for missing modules."""
    assert ext.import_module("json") is json
    assert ext.import_module("os.path") is os.path
    assert ext.json_dumps({"b": 1, "a": [1, 2]}) == '{"a":[1,2],"b":1}'

    with pytest.raises(ModuleNotFoundError, match="no_such_module"):
        ext.import_module("no_such_module")


def test_catching_exceptions(ext: types.ModuleType) -> None:
    """Check that Zig can inspect, clear, take, and raise Python exceptions."""
    assert ext.get_or_none({"a": 1}, "a") == 1
    assert ext.get_or_none({}, "a") is None

    with pytest.raises(IndexError):
        ext.get_or_none([], 0)

    name, message, text = ext.describe(helpers.raiser(KeyError("k")))
    assert (name, message) == ("KeyError", "'k'")
    assert text.startswith("Traceback (most recent call last):\n")
    assert "in fail" in text
    assert text.endswith("KeyError: 'k'\n")

    with pytest.raises(AssertionError, match="didn't raise"):
        ext.describe(lambda: None)


def test_reraising_exceptions(ext: types.ModuleType) -> None:
    """Check that Zig can raise a caught exception again or replace it."""
    original = KeyError("k")
    with pytest.raises(KeyError) as caught:
        ext.reraise_lookup_error(helpers.raiser(original))

    assert caught.value is original

    with pytest.raises(RuntimeError, match="not a LookupError"):
        ext.reraise_lookup_error(helpers.raiser(ValueError("v")))


def test_exception_objects(ext: types.ModuleType) -> None:
    """Check that py.Exception accepts and raises Python exception objects."""
    error = ValueError("bad", 2)
    assert ext.exception_message(ValueError("bad")) == "bad"
    assert ext.exception_args(error) == ("bad", 2)

    with pytest.raises(ValueError, match="bad") as caught:
        ext.raise_given(error)

    assert caught.value is error

    with pytest.raises(TypeError, match="expected BaseException, got int"):
        ext.exception_message(5)


def test_running_code(ext: types.ModuleType) -> None:
    """Check default and explicit namespaces for running and evaluating Python code."""
    main = sys.modules["__main__"]
    ext.run_code("zypy_answer = 6 * 7")
    try:
        assert main.zypy_answer == 42
        assert ext.eval_code("zypy_answer + 1") == 43
    finally:
        del main.zypy_answer

    assert ext.eval_code(" \t[2**10, 'x']") == [1024, "x"]

    namespace = ext.run_in_namespace("import math\nresult = base + math.floor(2.5)\ndef twice(n): return 2 * n")
    assert namespace["result"] == 42
    assert namespace["twice"](4) == 8
    assert ext.eval_in_namespace({"x": 5}, "x * len([1, 2])") == 10


def test_running_code_errors(ext: types.ModuleType) -> None:
    """Check that exceptions from executed Python code reach the caller."""
    with pytest.raises(SyntaxError):
        ext.run_code("def")

    with pytest.raises(ZeroDivisionError):
        ext.eval_code("1 / 0")

    with pytest.raises(NameError, match="missing"):
        ext.eval_in_namespace({}, "missing")

    with pytest.raises(TypeError):
        ext.eval_in_namespace({}, "'text'")


def test_method_names(ext: types.ModuleType) -> None:
    """Check that literal method names are interned and runtime names stay unchanged."""
    seen: list[str] = []

    class Recorder:
        """An object that records method names requested through attribute lookup."""

        def __getattr__(self, name: str) -> collections.abc.Callable[[object], object]:
            """Record the attribute name and return a method that echoes its argument."""
            seen.append(name)
            return lambda value: value

    names = [f"zypy_method_{i}" for i in range(300)]
    assert [ext.call_method(Recorder(), name, i) for i, name in enumerate(names)] == list(range(300))
    assert all(given is name for given, name in zip(seen, names, strict=True))
    assert not any(sys._is_interned(name) for name in seen)

    seen.clear()
    ext.call_method_repeatedly(Recorder(), 2)
    assert seen == ["touch", "touch"]
    assert sys._is_interned(seen[0])
    assert seen[0] is seen[1]
