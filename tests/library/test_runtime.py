import array
import collections.abc
import sys
import threading
import time
import tracemalloc
import types

import pytest

import helpers


def run_in_threads(function: collections.abc.Callable[[], object], count: int) -> float:
    """Run `function` in `count` threads and return the elapsed time in seconds."""
    threads = [threading.Thread(target=function) for _ in range(count)]
    start = time.perf_counter()

    for thread in threads:
        thread.start()

    for thread in threads:
        thread.join()

    return time.perf_counter() - start


def test_allocators(ext: types.ModuleType) -> None:
    """Check that Python-backed allocators pass the standard library allocator checks."""
    ext.allocator_stress(False)
    ext.allocator_stress(True)
    assert ext.join_numbers(range(5)) == "0, 1, 2, 3, 4"


def test_allocators_are_traced(ext: types.ModuleType) -> None:
    """Check that tracemalloc tracks Python-backed allocators."""
    size = 1 << 20
    tracemalloc.start()
    try:
        assert size <= ext.traced_allocation(size, False) < size + 4096
        assert size <= ext.traced_allocation(size, True) < size + 4096
    finally:
        tracemalloc.stop()


def test_releasing_the_gil(ext: types.ModuleType) -> None:
    """Check concurrent Python execution during Zig calls with the GIL released or disabled."""
    held = run_in_threads(lambda: ext.sleep_held(150), 4)
    if sys._is_gil_enabled():
        assert held >= 0.6
    else:
        assert held < 0.45

    assert run_in_threads(lambda: ext.sleep_released(150), 4) < 0.45
    assert run_in_threads(lambda: ext.sleep_allowing_threads(150), 4) < 0.45
    assert ext.sum_without_gil(array.array("d", [1, 2]), 2) == 6


def test_zig_threads(ext: types.ModuleType) -> None:
    """Check Python calls from Zig threads using py.Gil, including nested acquisitions."""
    assert ext.call_from_thread(threading.get_ident) != threading.get_ident()
    assert ext.call_from_thread(lambda: [1, 2]) == [1, 2]
    assert ext.nested_gil(lambda: "held") == "held"

    with pytest.raises(KeyError, match="from a Zig thread"):
        ext.call_from_thread(helpers.raiser(KeyError("from a Zig thread")))
