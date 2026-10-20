import gc
import importlib
import inspect
import pathlib
import subprocess
import sys
import types
import typing
import weakref

import pytest

import helpers

SUBINTERPRETER_CHECKS: typing.Final = """
assert ext.count_calls() == 1
assert ext.midpoint(ext.Point(0), ext.Point(2)) == ext.Point(1)
assert list(ext.Bag([1, 2])) == [1, 2]
assert ext.raise_level(ext.Level.low) is ext.Level.medium
assert ext.wide_value(ext.Wide.m255) == 255
assert ext.wide_member(255) is ext.Wide.m255
assert ext.sub.triple(2) == 6

try:
    ext.parse_number("x")
except ext.ParseError:
    pass
else:
    raise AssertionError("no ParseError")
"""


def ext_directory(ext: types.ModuleType) -> pathlib.Path:
    """Get the installed test extension directory."""
    assert ext.__file__ is not None
    return pathlib.Path(ext.__file__).parent


def import_code(ext: types.ModuleType, module: str) -> str:
    """Generate code to import `module` from the test extension directory."""
    return f"import sys\nsys.path.insert(0, {str(ext_directory(ext))!r})\nimport {module}\n"


def run_in_subinterpreter(code: str, config: str) -> str | None:
    """Run code in a new subinterpreter and return any exception as text."""
    interpreters = pytest.importorskip("_interpreters")
    interpreter = interpreters.create(config)
    try:
        failure = interpreters.run_string(interpreter, code)
    finally:
        interpreters.destroy(interpreter)

    return None if failure is None else failure.formatted


def test_constants(ext: types.ModuleType) -> None:
    """Check that module import converts constants, including class instances."""
    assert ext.__version__ == "1.0.0"
    assert ext.MAX_SIZE == 4096
    assert ext.LIMITS == (0, 10)
    assert isinstance(ext.ORIGIN, ext.Point)
    assert ext.Point(0, 0) == ext.ORIGIN


def test_exception_types(ext: types.ModuleType) -> None:
    """Check custom exception classes, base types, and docstrings."""
    assert ext.ParseError.__module__ == "zypy_tests"
    assert ext.ParseError.__mro__[1:] == ValueError.__mro__
    assert ext.ParseError.__doc__ == "The input couldn't be parsed."
    assert issubclass(ext.StrictError, ext.ParseError)
    assert ext.PlainError.__mro__[1] is Exception
    assert ext.parse_error_class() is ext.ParseError


def test_raising_custom_exceptions(ext: types.ModuleType) -> None:
    """Check that py.raise and .errors mappings raise custom exceptions."""
    assert ext.parse_number("12") == 12
    assert ext.limit(5) == 5

    with pytest.raises(ext.ParseError, match="not a number"):
        ext.parse_number("x")

    with pytest.raises(ext.StrictError, match="-3 is negative"):
        ext.strict_number(-3)

    with pytest.raises(ext.PlainError, match="plain"):
        ext.raise_plain()

    with pytest.raises(ext.ParseError, match="TooBig"):
        ext.limit(11)

    with pytest.raises(ext.StrictError, match="too small"):
        ext.limit(-1)


def test_catching_custom_exceptions(ext: types.ModuleType) -> None:
    """Check custom exception matching, including subclasses."""

    def fail() -> None:
        """Raise a subclass of ParseError."""
        raise type("Custom", (ext.ParseError,), {})("custom")

    assert ext.classify(lambda: ext.strict_number(-1)) == "strict"
    assert ext.classify(lambda: ext.parse_number("z")) == "parse!"
    assert ext.classify(lambda: None) == "nofail"
    assert ext.classify(fail) == "parse!"

    with pytest.raises(KeyError):
        ext.classify(lambda: {}["missing"])


def test_submodules(ext: types.ModuleType) -> None:
    """Check submodule attributes, sys.modules entries, and imports by full name."""
    assert ext.sub.__name__ == "zypy_tests.sub"
    assert ext.sub.__doc__ == "A submodule."
    assert ext.sub.__spec__.name == "zypy_tests.sub"
    assert ext.sub.triple(3) == 9
    assert ext.sub.deep.ANSWER == 42

    assert sys.modules["zypy_tests.sub"] is ext.sub
    assert sys.modules["zypy_tests.sub.deep"] is ext.sub.deep
    assert importlib.import_module("zypy_tests.sub.deep") is ext.sub.deep


def test_submodules_use_classes_of_other_modules(ext: types.ModuleType) -> None:
    """Check that submodules can return instances of parent-module classes."""
    point = ext.sub.point(2)
    assert type(point) is ext.Point
    assert point == ext.Point(2, -2)


def test_module_state(ext: types.ModuleType) -> None:
    """Check that module import creates state that persists between calls."""
    first = ext.count_calls()
    assert ext.count_calls() == first + 1
    assert ext.state_version() == "1.0.0"
    assert ext.Counter().module_calls() == first + 1
    assert ext.Counter.total_calls() == first + 1
    assert str(inspect.signature(ext.Counter.total_calls)) == "()"


def test_module_state_keeps_objects(ext: types.ModuleType) -> None:
    """Check that module state holds a reference to the objects it stores until they're replaced."""
    value = object()
    before = sys.getrefcount(value)

    ext.remember("key", value)
    assert ext.recall("key") is value
    assert ext.recall("other") is None
    assert ext.last_remembered() is value
    assert sys.getrefcount(value) == before + 2

    ext.remember("key", 1)
    assert sys.getrefcount(value) == before


def test_class_in_two_modules(ext: types.ModuleType) -> None:
    """Check that a duplicate class definition fails to import without breaking the first module."""
    with pytest.raises(ImportError, match=r"class Point is already defined by module 'zypy_tests' \(list it in one"):
        ext.load_conflicting("conflicting")

    assert ext.midpoint(ext.Point(0), ext.Point(2)) == ext.Point(1)


def test_reimport(ext: types.ModuleType) -> None:
    """Check that reimport creates independent state and classes without breaking existing objects."""
    saved = {name: module for name, module in sys.modules.items() if name.split(".")[0] == "zypy_tests"}
    for name in saved:
        del sys.modules[name]

    try:
        fresh = importlib.import_module("zypy_tests")
    finally:
        sys.modules.update(saved)

    assert fresh is not ext
    assert fresh.Point is not ext.Point

    ext.count_calls()
    calls = ext.count_calls()
    assert fresh.count_calls() == 1
    assert fresh.Counter.total_calls() == 1
    assert ext.Counter.total_calls() == calls

    assert ext.midpoint(ext.Point(0), ext.Point(2)) == ext.Point(1)
    assert type(fresh.midpoint(fresh.Point(0), ext.Point(2))) is fresh.Point
    assert fresh.Level is not ext.Level
    assert fresh.raise_level(ext.Level.low) is fresh.Level.medium
    assert ext.raise_level(fresh.Level.medium) is fresh.Level.high
    assert fresh.wide_value(ext.Wide.m255) == ext.wide_value(fresh.Wide.m255) == 255

    collected = weakref.ref(fresh)
    del fresh
    gc.collect()

    assert collected() is None
    assert type(ext.midpoint(ext.Point(0), ext.Point(2))) is ext.Point
    assert ext.raise_level(ext.Level.low) is ext.Level.medium


def test_failed_import_leaves_no_submodules(ext: types.ModuleType) -> None:
    """Check that failed imports remove newly added submodules and their children."""
    sys.modules["failing.bad"] = types.ModuleType("failing.bad")
    try:
        with pytest.raises(RuntimeError, match=r"^SetupFailed$"):
            ext.load_failing("failing")

        assert isinstance(sys.modules["failing.bad"], types.ModuleType)
        assert [name for name in sys.modules if name.startswith("failing.")] == ["failing.bad"]
    finally:
        del sys.modules["failing.bad"]


@pytest.mark.parametrize("config", ["isolated", "legacy"])
def test_subinterpreters(ext: types.ModuleType, config: str) -> None:
    """Check that .subinterpreters gives each interpreter independent module state."""
    calls = ext.count_calls()
    code = import_code(ext, "zypy_tests as ext") + SUBINTERPRETER_CHECKS

    assert run_in_subinterpreter(code, config) is None
    assert ext.count_calls() == calls + 1


def test_modules_without_subinterpreters(ext: types.ModuleType) -> None:
    """Check that modules without .subinterpreters reject interpreters with a separate GIL."""
    code = import_code(ext, "zypy_tests_single")
    failure = run_in_subinterpreter(code, "isolated")
    assert failure == "ImportError: module zypy_tests_single does not support loading in subinterpreters"

    code += "assert zypy_tests_single.answer() == 42\n"
    assert run_in_subinterpreter(code, "legacy") == (failure if helpers.FREE_THREADED else None)
    subprocess.run([sys.executable, "-c", code], check=True)
