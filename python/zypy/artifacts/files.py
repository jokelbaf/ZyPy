import collections.abc
import fnmatch
import pathlib
import typing

import zypy.errors

EXCLUDED_DIRS: typing.Final = frozenset(
    {
        ".git",
        ".hg",
        ".jj",
        ".svn",
        ".zig-cache",
        "zig-cache",
        "zig-out",
        "zig-pkg",
        ".venv",
        "venv",
        "__pycache__",
        "dist",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        ".nox",
        ".tox",
        ".idea",
        ".vscode",
    }
)

BYTECODE_SUFFIXES: typing.Final = frozenset({".pyc", ".pyo"})
OUTPUT_SUFFIXES: typing.Final = BYTECODE_SUFFIXES | {".so", ".pyd", ".dylib", ".dll"}


def walk(
    root: pathlib.Path,
    exclude: collections.abc.Sequence[str] = (),
    skip: collections.abc.Collection[pathlib.Path] = (),
) -> collections.abc.Iterator[tuple[str, pathlib.Path]]:
    """Yield sorted project file paths, excluding caches, build outputs, symlinks, and excluded paths."""

    def keep(path: pathlib.Path) -> bool:
        """Check that `path` isn't skipped or excluded."""
        return path not in skip and not _matches(path, root, exclude)

    def keep_file(path: pathlib.Path) -> bool:
        """Check that `path` is a source file of the project."""
        return path.suffix not in OUTPUT_SUFFIXES and not path.is_symlink() and keep(path)

    return _walk(root, keep, keep_file)


def walk_package(directory: pathlib.Path) -> collections.abc.Iterator[tuple[str, pathlib.Path]]:
    """Yield sorted files from a Zig package directory, preserving prebuilt libraries.

    Follow file links and reject directory links. Skip caches and Python bytecode.
    """

    def keep_file(path: pathlib.Path) -> bool:
        """Accept package files, skipping bytecode and rejecting directory links."""
        if path.is_dir():
            raise zypy.errors.ZypyError(f"{path} is a link to a directory, which sdists can't hold")

        return path.suffix not in BYTECODE_SUFFIXES

    return _walk(directory, lambda _: True, keep_file)


def _walk(
    root: pathlib.Path,
    keep_directory: collections.abc.Callable[[pathlib.Path], bool],
    keep_file: collections.abc.Callable[[pathlib.Path], bool],
) -> collections.abc.Iterator[tuple[str, pathlib.Path]]:
    """Yield the files under `root` that `keep_file` accepts, in directories that `keep_directory` accepts."""
    for directory, dirs, files in root.walk():
        dirs[:] = sorted(name for name in dirs if name not in EXCLUDED_DIRS and keep_directory(directory / name))

        for name in sorted(files):
            path = directory / name
            if keep_file(path):
                yield path.relative_to(root).as_posix(), path


def _matches(path: pathlib.Path, root: pathlib.Path, patterns: collections.abc.Sequence[str]) -> bool:
    """Check whether `path` or its name matches one of the glob patterns."""
    relative = path.relative_to(root).as_posix()
    return any(
        fnmatch.fnmatchcase(relative, pattern) or fnmatch.fnmatchcase(path.name, pattern) for pattern in patterns
    )
