import collections.abc
import gc
import sys
import tracemalloc
import types

import pytest

import library.leaks.failing
import library.leaks.working


def test_no_leaks(ext: types.ModuleType) -> None:
    """Check that repeated calls and failures do not leak memory."""
    working = library.leaks.working.calls(ext)
    failing = library.leaks.failing.calls(ext)

    def churn() -> None:
        """Run each call once, including expected failures."""
        for call in working:
            call()

        for call in failing:
            with pytest.raises(library.leaks.failing.ERRORS):
                call()

    check_stable(churn)


def check_stable(churn: collections.abc.Callable[[], None]) -> None:
    """Check stable memory use and, on debug Python, stable total reference counts."""
    for _ in range(500):
        churn()

    gc.collect()
    references = total_references()

    tracemalloc.start()
    try:
        before = tracemalloc.take_snapshot()
        for _ in range(10):
            for _ in range(500):
                churn()

            gc.collect()

        after = tracemalloc.take_snapshot()
    finally:
        tracemalloc.stop()

    growth = sum(stat.size_diff for stat in after.compare_to(before, "filename"))
    del before, after
    assert growth < 64 * 1024, f"memory grew by {growth} bytes"

    if references is not None and (later := total_references()) is not None:
        assert later - references < 2500, f"the total reference count grew by {later - references}"


def total_references() -> int | None:
    """Get the total reference count on debug Python, or `None` on other builds."""
    return sys.gettotalrefcount() if hasattr(sys, "gettotalrefcount") else None
