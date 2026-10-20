import collections.abc
import dataclasses
import enum
import pathlib
import re
import typing

import zypy.errors
import zypy.target


class Optimize(enum.StrEnum):
    """Zig's optimize modes, as in `zig build -Doptimize=...`."""

    DEBUG = "debug"
    SAFE = "safe"
    FAST = "fast"
    SMALL = "small"


OVERRIDABLE: typing.Final = frozenset({"optimize", "manylinux"})
TABLE_KEYS: typing.Final = OVERRIDABLE | {"python-source", "exclude", "abi3"}

MINIMUM_ABI3: typing.Final = (3, 13)


@dataclasses.dataclass(frozen=True, slots=True, kw_only=True)
class Settings:
    """The `[tool.zypy]` table of pyproject.toml."""

    python_source: pathlib.Path | None = None
    optimize: Optimize = Optimize.FAST
    manylinux: zypy.target.GlibcVersion | None = zypy.target.MINIMUM_GLIBC
    exclude: tuple[str, ...] = ()
    abi3: tuple[int, int] | None = None

    @classmethod
    def load(cls, table: collections.abc.Mapping[str, object], root: pathlib.Path) -> typing.Self:
        """Read the `[tool.zypy]` table of the project in `root`."""
        if unknown := table.keys() - TABLE_KEYS:
            raise zypy.errors.ZypyError(f"unknown [tool.zypy] settings: {', '.join(sorted(unknown))}")

        settings = cls(
            python_source=_python_source(table.get("python-source"), root),
            exclude=_exclude(table.get("exclude")),
            abi3=_abi3(table.get("abi3")),
        )

        return settings.override({key: table[key] for key in OVERRIDABLE & table.keys()})

    def override(self, values: collections.abc.Mapping[str, object]) -> typing.Self:
        """Apply config settings, such as `optimize` from `uv build -C optimize=safe`."""
        if unknown := values.keys() - OVERRIDABLE:
            supported = ", ".join(sorted(OVERRIDABLE))
            raise zypy.errors.ZypyError(
                f"unknown config settings: {', '.join(sorted(unknown))} (supported: {supported})"
            )

        optimize = self.optimize if (value := values.get("optimize")) is None else _optimize(value)
        manylinux = self.manylinux if (value := values.get("manylinux")) is None else _manylinux(value)

        return dataclasses.replace(self, optimize=optimize, manylinux=manylinux)


def _python_source(value: object, root: pathlib.Path) -> pathlib.Path | None:
    """Resolve the python-source directory, which must be inside the project."""
    if value is None:
        return None

    path = (root / _expect(value, str, "python-source")).resolve()
    if not path.is_dir() or not path.is_relative_to(root):
        raise zypy.errors.ZypyError(f"python-source must be a directory inside the project, got {value!r}")

    return path


def _exclude(value: object) -> tuple[str, ...]:
    """Check that exclude is a list of glob patterns."""
    if value is None:
        return ()

    patterns = _expect(value, list, "exclude")
    if not all(isinstance(pattern, str) for pattern in patterns):
        raise zypy.errors.ZypyError("exclude must be a list of glob patterns")

    return tuple(str(pattern) for pattern in patterns)


def _abi3(value: object) -> tuple[int, int] | None:
    """Parse the oldest Python version for stable ABI wheels, such as "3.13"."""
    if value is None:
        return None

    match = re.fullmatch(r"(\d+)\.(\d+)", _expect(value, str, "abi3"))
    if not match or (int(match[1]), int(match[2])) < MINIMUM_ABI3 or int(match[1]) != MINIMUM_ABI3[0]:
        raise zypy.errors.ZypyError(f'abi3 must be a Python version of at least "3.13", got {value!r}')

    return int(match[1]), int(match[2])


def _optimize(value: object) -> Optimize:
    """Parse an optimize mode."""
    try:
        return Optimize(value)
    except ValueError:
        raise zypy.errors.ZypyError(f"optimize must be one of {', '.join(Optimize)}; got {value!r}") from None


def _manylinux(value: object) -> zypy.target.GlibcVersion | None:
    """Parse a glibc version such as "2_17", or "off" to use the build machine's version."""
    text = _expect(value, str, "manylinux")
    return None if text == "off" else zypy.target.GlibcVersion.parse(text)


def _expect[T](value: object, kind: type[T], key: str) -> T:
    """Check that the setting `key` has the type `kind`."""
    if not isinstance(value, kind):
        raise zypy.errors.ZypyError(f"{key} must be a {kind.__name__}, got {value!r}")

    return value
