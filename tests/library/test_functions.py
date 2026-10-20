import collections
import collections.abc
import inspect
import re
import types

import pytest


def bind(a: int, /, b: int, c: int | None = None, *, d: int = 4, e: bool = False) -> object:
    """Take the same parameters as ext.bind."""
    return a, b, c, d, e


def keywords_only(*, x: int, y: int, z: int) -> object:
    """Take the same parameters as ext.keywords_only."""
    return x, y, z


def collect(first: int, *rest: object, flag: bool = False, **options: object) -> object:
    """Take the same parameters as ext.collect."""
    return first, rest, flag, options


def test_module(ext: types.ModuleType) -> None:
    """Check the imported module name and docstrings."""
    assert ext.__name__ == "zypy_tests"
    assert ext.__doc__ == "ZyPy's test module"
    assert ext.add.__module__ == "zypy_tests"
    assert ext.add.__doc__ == "Add two numbers."
    assert ext.add_u8.__doc__ is None


def test_argument_count(ext: types.ModuleType) -> None:
    """Check TypeError for the wrong argument count."""
    with pytest.raises(TypeError, match=r"add\(\) takes 2 arguments \(1 given\)"):
        ext.add(1)

    with pytest.raises(TypeError, match=r"nothing\(\) takes no arguments \(1 given\)"):
        ext.nothing(1)

    with pytest.raises(TypeError, match=r"half\(\) takes exactly one argument \(0 given\)"):
        ext.half()

    with pytest.raises(TypeError, match="takes no keyword arguments"):
        ext.half(x=1)


def test_keyword_arguments(ext: types.ModuleType) -> None:
    """Check named, positional-only, and keyword-only parameters."""
    assert ext.greet("Ann") == "Hello, Ann."
    assert ext.greet("Ann", "Hi") == "Hi, Ann."
    assert ext.greet("Ann", greeting="Hi", loud=True) == "Hi, Ann!"

    assert ext.bind(1, 2) == (1, 2, None, 4, False)
    assert ext.bind(1, c=3, b=2, e=True) == (1, 2, 3, 4, True)
    assert ext.bind(1, 2, 3, d=5) == (1, 2, 3, 5, False)
    assert ext.keywords_only(z=3, y=2, x=1) == 123


@pytest.mark.parametrize(
    ("python", "args", "kwargs"),
    [
        (bind, (), {"a": 1, "b": 2}),
        (bind, (1, 2), {"a": 1, "b": 3}),
        (bind, (1,), {}),
        (bind, (), {}),
        (bind, (1, 2, 3, 4), {}),
        (bind, (1, 2, 3, 4), {"d": 1}),
        (bind, (1, 2), {"x": 1}),
        (bind, (1, 2), {"b": 3}),
        (keywords_only, (), {}),
        (keywords_only, (), {"x": 1}),
        (keywords_only, (), {"y": 1, "z": 2}),
        (keywords_only, (1,), {}),
        (keywords_only, (1, 2), {}),
        (collect, (), {}),
        (collect, (1,), {"first": 2}),
    ],
)
def test_argument_binding_errors(
    ext: types.ModuleType,
    python: collections.abc.Callable[..., object],
    args: tuple[object, ...],
    kwargs: dict[str, object],
) -> None:
    """Check that invalid arguments produce the same messages as Python functions."""
    with pytest.raises(TypeError) as expected:
        python(*args, **kwargs)

    with pytest.raises(TypeError) as actual:
        getattr(ext, python.__name__)(*args, **kwargs)

    assert str(actual.value) == str(expected.value)


def test_positional_only_arguments_passed_as_keywords(ext: types.ModuleType) -> None:
    """Check the error for a positional-only parameter passed by name."""
    with pytest.raises(TypeError, match="positional-only arguments passed as keyword arguments: 'name'"):
        ext.greet(name="Ann")


def test_trailing_optionals(ext: types.ModuleType) -> None:
    """Check that trailing optional parameters can be omitted, with or without .params."""
    assert ext.optional_tail(1) == (1, None, None)
    assert ext.optional_tail(1, 2) == (1, 2, None)
    assert ext.optional_tail(1, None, 3) == (1, None, 3)
    assert ext.or_default() == -1

    with pytest.raises(TypeError, match=r"optional_tail\(\) takes at least 1 argument \(0 given\)"):
        ext.optional_tail()

    with pytest.raises(TypeError, match=r"optional_tail\(\) takes at most 3 arguments \(4 given\)"):
        ext.optional_tail(1, 2, 3, 4)

    with pytest.raises(TypeError, match="takes no keyword arguments"):
        ext.optional_tail(1, b=2)


def test_defaults(ext: types.ModuleType) -> None:
    """Check that default values are converted from Zig on every call."""
    first = ext.with_defaults()
    assert first == ("it's", [1, 2], b"raw\n", 2.0, 3, None)

    first[1].append(3)
    assert ext.with_defaults()[1] == [1, 2]

    assert ext.with_defaults("x", [], b"", 0.5, 1, "fast") == ("x", [], b"", 0.5, 1, "fast")
    assert ext.with_defaults(count=7, mode=None) == ("it's", [1, 2], b"raw\n", 2.0, 7, None)

    with pytest.raises(TypeError, match="expected list, got int"):
        ext.with_defaults(items=5)


def test_extra_arguments(ext: types.ModuleType) -> None:
    """Check that py.Args and py.Kwargs collect extra arguments."""
    assert ext.collect(1) == (1, (), False, {})
    assert ext.collect(1, 2, 3, flag=True, x=4) == (1, (2, 3), True, {"x": 4})
    assert ext.collect(first=1, x=2) == (1, (), False, {"x": 2})

    options = {"x": 1}
    assert ext.collect(1, **options)[3] is not options
    assert ext.positional_and_kwargs(1, a=2) == (1, {"a": 2})


def test_args(ext: types.ModuleType) -> None:
    """Check reads of py.Args items."""
    assert ext.sum_args() == 0
    assert ext.sum_args(1, 2, 3) == 6

    with pytest.raises(TypeError, match="cannot be interpreted as an integer"):
        ext.sum_args(1, "2")

    with pytest.raises(TypeError, match="takes no keyword arguments"):
        ext.sum_args(x=1)


def test_kwargs(ext: types.ModuleType) -> None:
    """Check py.Kwargs iteration and lookups."""
    assert ext.kwarg_names(b=1, a=2) == ["b", "a"]
    assert ext.kwarg_names() == []
    assert ext.kwarg_lookup() == (0, None, False)
    assert ext.kwarg_lookup(n=5, flag=0) == (2, 5, True)

    with pytest.raises(TypeError, match=r"kwarg_names\(\) takes no arguments \(1 given\)"):
        ext.kwarg_names(1)


def test_text_signatures(ext: types.ModuleType) -> None:
    """Check that .params provides signatures for help(), inspect, and IDEs."""
    assert ext.greet.__text_signature__ == "(name, /, greeting='Hello', *, loud=False)"
    assert str(inspect.signature(ext.greet)) == "(name, /, greeting='Hello', *, loud=False)"
    assert ext.greet.__doc__ == "Greet someone."

    assert str(inspect.signature(ext.bind)) == "(a, /, b, c=None, *, d=4, e=False)"
    assert ext.bind.__doc__ is None
    assert str(inspect.signature(ext.collect)) == "(first, *rest, flag=False, **options)"
    assert str(inspect.signature(ext.positional_and_kwargs)) == "(a, /, **kwargs)"

    assert str(inspect.signature(ext.with_defaults)) == (
        "(text=\"it's\", items=Ellipsis, data=b'raw\\n', factor=2.0, count=3, mode=None)"
    )
    assert ext.with_defaults.__doc__ == "Return the arguments."

    assert str(inspect.signature(ext.unicode_default)) == "(text='héllo ✓ \U0001d11e\\n')"
    assert ext.unicode_default() == "héllo ✓ \U0001d11e\n"

    assert ext.add.__text_signature__ is None
    with pytest.raises(ValueError, match="no signature found"):
        inspect.signature(ext.add)


def test_error_mapping(ext: types.ModuleType) -> None:
    """Check that function error mappings take precedence over module mappings."""
    assert ext.parse(3) == 42

    with pytest.raises(ValueError, match=r"^InvalidInput$"):
        ext.parse(0)

    with pytest.raises(KeyError, match="no such key"):
        ext.parse(1)

    with pytest.raises(RuntimeError, match=r"^Unmapped$"):
        ext.parse(2)

    with pytest.raises(ConnectionError, match=r"^ModuleWide$"):
        ext.module_errors(0)

    with pytest.raises(TypeError, match=r"^InvalidInput$"):
        ext.module_errors(1)

    with pytest.raises(RuntimeError, match=r"^Unmapped$"):
        ext.module_errors(2)


def test_keywords_without_interned_names(ext: types.ModuleType) -> None:
    """Check keyword matching for strings that are not interned."""
    greeting = "".join(["greet", "ing"])
    assert ext.greet("Ann", **{greeting: "Hi"}) == "Hi, Ann."
    assert ext.wide_sum(1, 2, 3, 4, 5, 6, **{"".join(["e", "ta"]): 7, "".join(["the", "ta"]): 8}) == 36

    surrogate = "\udc80"
    with pytest.raises(TypeError, match=re.escape(f"greet() got an unexpected keyword argument '{surrogate}'")):
        ext.greet("Ann", **{surrogate: "Hi"})
