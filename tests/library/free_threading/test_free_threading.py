import collections.abc
import os
import pathlib
import subprocess
import sys
import types
import typing
import weakref

import pytest

import helpers
import library.free_threading.checks
import zypy.zig

pytestmark = pytest.mark.skipif(not helpers.FREE_THREADED, reason="needs free-threaded Python")

CHECKS: typing.Final = (
    library.free_threading.checks.counter_calls,
    library.free_threading.checks.module_state,
    library.free_threading.checks.bag_appends,
    library.free_threading.checks.bag_iteration,
    library.free_threading.checks.stack_appends_and_pops,
    library.free_threading.checks.field_writes,
    library.free_threading.checks.property_writes,
    library.free_threading.checks.container_reads,
    library.free_threading.checks.pops,
    library.free_threading.checks.dict_iteration,
)


def without_python_gil() -> dict[str, str]:
    """Copy the environment without a PYTHON_GIL override."""
    return {name: value for name, value in os.environ.items() if name != "PYTHON_GIL"}


def run_python(ext: types.ModuleType, code: str) -> subprocess.CompletedProcess[str]:
    """Run code in a new Python process with access to the extension and test modules."""
    assert ext.__file__ is not None
    directories = [str(helpers.REPO / "tests"), str(pathlib.Path(ext.__file__).parent)]
    command = [sys.executable, "-c", f"import sys\nsys.path[:0] = {directories!r}\n{code}"]

    result = subprocess.run(command, env=without_python_gil(), capture_output=True, text=True, check=False, timeout=300)
    assert result.returncode == 0, result.stderr
    return result


def still_alive(
    item: weakref.ref[helpers.Item], remove: collections.abc.Callable[[], object]
) -> collections.abc.Callable[[], None]:
    """Create a callback that removes `item` and checks that it remains alive."""

    def callback() -> None:
        """Remove the item while the calling Zig function still uses it."""
        remove()
        assert item() is not None

    return callback


def test_free_threaded_modules_keep_the_gil_disabled(ext: types.ModuleType) -> None:
    """Check that .free_threaded modules keep the GIL disabled while other modules enable it."""
    code = "import zypy_tests\nprint(sys._is_gil_enabled())\nimport zypy_tests_single\nprint(sys._is_gil_enabled())\n"
    result = run_python(ext, code)

    assert result.stdout.split() == ["False", "True"]
    assert "enabled to load module 'zypy_tests_single'" in result.stderr


def test_calls_with_the_gil_keep_nothing(ext: types.ModuleType) -> None:
    """Check that calls with the GIL do not retain container reads."""
    code = (
        "import zypy_tests, zypy_tests_single\n"
        "item = object()\n"
        "items = [item]\n"
        "before = sys.getrefcount(item)\n"
        "inside = zypy_tests.call_no_args(lambda: [zypy_tests_single.read_items(items, 1000), sys.getrefcount(item)])\n"
        "print(inside[1] - before)\n"
    )

    assert run_python(ext, code).stdout.split() == ["0"]


def test_reads_stay_alive_until_the_call_returns(ext: types.ModuleType) -> None:
    """Check that free-threaded calls retain container reads and borrow scopes release them early."""
    item = helpers.Item()
    items = [item]
    counts: list[int] = []
    before = sys.getrefcount(item)

    ext.unscoped_reads(items, 1000, lambda: counts.append(sys.getrefcount(item)))
    ext.scoped_reads(items, 1000, lambda: counts.append(sys.getrefcount(item)))
    ext.nested_scopes(items, lambda: counts.append(sys.getrefcount(item)))

    assert counts == [before + 1000, before, before + 1]
    assert sys.getrefcount(item) == before


def test_borrowed_items_outlive_their_container(ext: types.ModuleType) -> None:
    """Check that borrowed items survive container removal until the function returns."""
    items = [helpers.Item()]
    item = weakref.ref(items[0])
    assert ext.read_then_call(items, still_alive(item, items.clear)) is item()
    assert item() is None

    values = {"key": helpers.Item()}
    item = weakref.ref(values["key"])
    assert ext.lookup_then_call(values, "key", still_alive(item, values.clear)) is item()
    assert item() is None


@pytest.mark.parametrize("check", CHECKS, ids=lambda check: check.__name__)
def test_threads_without_gil(ext: types.ModuleType, check: collections.abc.Callable[[], None]) -> None:
    """Check concurrent object access in a Python process with the GIL disabled."""
    run_python(ext, f"import library.free_threading.checks\nlibrary.free_threading.checks.{check.__name__}()\n")


def test_zig_threads_without_gil(tmp_path: pathlib.Path) -> None:
    """Check concurrent Zig-thread access to an instance and a list with free-threaded Python."""
    embed = helpers.REPO / "tests" / "embed"
    helpers.run(*zypy.zig.command(), "build", "--prefix", tmp_path, f"-Dpython={sys.executable}", cwd=embed)

    command = [tmp_path / "bin" / "threads"]
    result = subprocess.run(command, env=without_python_gil(), capture_output=True, text=True, check=False)

    assert result.returncode == 0, result.stderr
    assert result.stdout.split() == ["False", str(4 * 2000), "0"]
