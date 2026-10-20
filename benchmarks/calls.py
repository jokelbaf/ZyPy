import argparse
import importlib
import os
import pathlib
import sys
import tempfile
import timeit
import types
import typing

import zypy.settings
import zypy.zig

REPO: typing.Final = pathlib.Path(__file__).resolve().parent.parent

LOOP: typing.Final = 100_000

PYTHON_CALLS: typing.Final = {
    "Python to Zig: add(1, 2)": "ext.add(1, 2)",
    "Python to Zig: keyword_sum(1, 2, c=3, d=4)": "ext.keyword_sum(1, 2, c=3, d=4)",
    "Python to Zig: keyword_sum(a=1, b=2, c=3, d=4)": "ext.keyword_sum(a=1, b=2, c=3, d=4)",
    "Python to Zig: wide_sum(1, ..., eta=7, theta=8)": "ext.wide_sum(1, 2, 3, 4, 5, 6, eta=7, theta=8)",
    "Python to Zig: point.scale(1.0)": "point.scale(1.0)",
    "Python to Zig: point.scale(factor=1.0)": "point.scale(factor=1.0)",
    "Python to Zig: Point.hypot(3.0, 4.0)": "Point.hypot(3.0, 4.0)",
    "Python to Zig: Point.hypot(3.0, dy=4.0)": "Point.hypot(3.0, dy=4.0)",
    "Python to Zig: Point.hypot(dx=3.0, dy=4.0)": "Point.hypot(dx=3.0, dy=4.0)",
    "Python to Zig: wide_value(Wide.m0)": "ext.wide_value(first)",
    "Python to Zig: wide_value(Wide.m255)": "ext.wide_value(last)",
    "Python to Zig: wide_member(255)": "ext.wide_member(255)",
    "Python to Python: keyword_sum(1, 2, c=3, d=4)": "keyword_sum(1, 2, c=3, d=4)",
}

ZIG_LOOPS: typing.Final = {
    "Zig to Python: f(1)": "ext.call_repeatedly(target, LOOP)",
    "Zig to Python: f(1, scale=2, offset=3)": "ext.call_keywords_repeatedly(target, LOOP)",
    "Zig to Python: obj.touch(1)": "ext.call_method_repeatedly(obj, LOOP)",
    "Zig to Python: obj.touch(1, flag=True)": "ext.call_method_keywords_repeatedly(obj, LOOP)",
}


class Target:
    """A Python object used to benchmark method calls from Zig."""

    def touch(self, a: int, *, flag: bool = False) -> None:
        """Do nothing."""


def target(a: int, scale: int = 0, offset: int = 0) -> None:
    """Accept calls from Zig without doing any work."""


def keyword_sum(a: int, b: int, *, c: int, d: int) -> int:
    """Add four numbers, like the Zig `keyword_sum`."""
    return a + b + c + d


def main() -> None:
    """Build tests/ext in fast mode and print the time of each call."""
    parser = argparse.ArgumentParser(description="Measure the overhead of calls between Python and Zig.")
    parser.add_argument("--prebuilt", type=pathlib.Path, help="use this build of tests/ext (its python/ directory)")
    parser.add_argument("--repeat", type=int, default=7, help="how often to repeat each measurement")
    args = parser.parse_args()

    os.environ.setdefault("ZIG_LOCAL_PKG_DIR", str(REPO / "zig-pkg"))
    os.environ.setdefault("ZIG_LOCAL_CACHE_DIR", str(REPO / ".zig-cache"))
    with tempfile.TemporaryDirectory(prefix="zypy-bench-") as prefix:
        installed = args.prebuilt or zypy.zig.build(
            REPO / "tests" / "ext",
            pathlib.Path(prefix),
            python=sys.executable,
            optimize=zypy.settings.Optimize.FAST,
            target=None,
        )
        sys.path.insert(0, str(installed))
        for name, nanoseconds in measure(importlib.import_module("zypy_tests"), args.repeat):
            print(f"{name:<48} {nanoseconds:7.1f} ns")


def measure(ext: types.ModuleType, repeat: int) -> list[tuple[str, float]]:
    """Measure nanoseconds per call, using the fastest of `repeat` runs."""
    names: dict[str, object] = {"ext": ext, "keyword_sum": keyword_sum, "target": target, "obj": Target(), "LOOP": LOOP}
    names["Point"], names["point"] = ext.Point, ext.Point(1.0, 2.0)
    names["first"], names["last"] = ext.Wide.m0, ext.Wide.m255
    results = [(name, best(statement, names, 200_000, repeat)) for name, statement in PYTHON_CALLS.items()]
    results += [(name, best(statement, names, 1, repeat) / LOOP) for name, statement in ZIG_LOOPS.items()]
    return results


def best(statement: str, names: dict[str, object], number: int, repeat: int) -> float:
    """Return the fastest repeated measurement in nanoseconds per execution."""
    return min(timeit.repeat(statement, number=number, repeat=repeat, globals=names)) / number * 1e9


if __name__ == "__main__":
    main()
