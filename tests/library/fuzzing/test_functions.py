import gc
import types
import typing

import pytest

import library.fuzzing.calls
import library.fuzzing.stubs
import library.fuzzing.values

pytestmark = pytest.mark.filterwarnings("ignore::pytest.PytestUnraisableExceptionWarning")

EXCLUDED: typing.Final = frozenset(
    {
        "allocator_stress",
        "eval_code",
        "eval_in_namespace",
        "import_module",
        "load_conflicting",
        "load_failing",
        "run_code",
        "run_in_namespace",
        "sleep_allowing_threads",
        "sleep_held",
        "sleep_released",
    }
)

LOOPING: typing.Final = frozenset(
    {
        "call_keywords_repeatedly",
        "call_method_keywords_repeatedly",
        "call_method_repeatedly",
        "call_repeatedly",
        "make_bag",
        "range",
        "scoped_reads",
        "squares_tuple",
        "traced_allocation",
        "unscoped_reads",
    }
)


def test_functions(
    ext: types.ModuleType, signatures: dict[str, library.fuzzing.stubs.Signature], subtests: pytest.Subtests
) -> None:
    """Check that calls with fuzzed arguments raise Python exceptions instead of crashing."""
    for name in functions(ext):
        with subtests.test(name):
            fuzz_function(ext, name, signatures.get(name))

    gc.collect()


def fuzz_function(ext: types.ModuleType, name: str, signature: library.fuzzing.stubs.Signature | None) -> None:
    """Call function `name` with typed, hostile and random arguments."""
    function = getattr(ext, name)
    values = library.fuzzing.values.Values(ext=ext, small=name in LOOPING)

    library.fuzzing.calls.fuzz(values.arguments(signature), lambda arguments: arguments.apply(function))


def functions(ext: types.ModuleType) -> list[str]:
    """List functions to fuzz, excluding code execution, imports, and sleep."""
    return sorted(
        name
        for name, value in vars(ext).items()
        if callable(value) and not isinstance(value, type) and name not in EXCLUDED
    )
