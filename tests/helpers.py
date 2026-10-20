import collections.abc
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import sysconfig
import typing

import pytest

import zypy.interpreter
import zypy.zon

REPO: typing.Final = pathlib.Path(__file__).resolve().parent.parent
EXAMPLES: typing.Final = REPO / "examples"

PYTHON_TAG: typing.Final = f"cp{sys.version_info.major}{sys.version_info.minor}"
EXT_SUFFIX: typing.Final[str] = sysconfig.get_config_var("EXT_SUFFIX")
ARCHITECTURE: typing.Final = platform.machine()
MANYLINUX_TAGS: typing.Final = f"manylinux_2_17_{ARCHITECTURE}.manylinux2014_{ARCHITECTURE}"
FREE_THREADED: typing.Final = bool(sysconfig.get_config_var("Py_GIL_DISABLED"))

ZYPY_FILES: typing.Final = (
    "build.zig",
    "build.zig.zon",
    "build",
    "src",
    "python",
    "pyproject.toml",
    "README.md",
    "LICENSE",
)
BUILD_OUTPUTS: typing.Final = (".venv", ".zig-cache", "zig-out", "zig-pkg", "dist", "*.so", "__pycache__")

requires_uv: typing.Final = pytest.mark.skipif(shutil.which("uv") is None, reason="needs uv")


class Item:
    """An object that weak references can track."""


def run(*args: str | os.PathLike[str], cwd: pathlib.Path | None = None) -> str:
    """Run a command and return stdout, including command output in any failure."""
    command = [os.fspath(arg) for arg in args]
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)
    assert result.returncode == 0, f"{' '.join(command)} failed:\n{result.stdout}\n{result.stderr}"
    return result.stdout


def copy_example(name: str, destination: pathlib.Path, *, standalone: bool = False) -> pathlib.Path:
    """Copy an example, sharing ZyPy's sources unless a standalone checkout is needed."""
    project = destination / "examples" / name
    shutil.copytree(EXAMPLES / name, project, ignore=shutil.ignore_patterns(*BUILD_OUTPUTS))

    if standalone:
        for item in ZYPY_FILES:
            source = REPO / item
            if source.is_dir():
                shutil.copytree(source, destination / item, ignore=shutil.ignore_patterns(*BUILD_OUTPUTS))
            else:
                shutil.copy2(source, destination / item)

        return project

    relative = pathlib.Path(os.path.relpath(REPO, project)).as_posix()
    manifest = zypy.zon.Manifest.read(project / "build.zig.zon")
    paths = {dependency: relative for dependency in manifest.path_dependencies if dependency.value == "../.."}
    manifest.path.write_text(manifest.rewrite(paths))

    pyproject = project / "pyproject.toml"
    if pyproject.is_file():
        pyproject.write_text(
            pyproject.read_text().replace('path = "../.."', f"path = {json.dumps(relative, ensure_ascii=False)}")
        )

    return project


def write_project(root: pathlib.Path, extra: str = "", project: str = "") -> pathlib.Path:
    """Write a minimal pyproject.toml with the given metadata and extra tables."""
    root.mkdir(parents=True, exist_ok=True)
    (root / "pyproject.toml").write_text(f'[project]\nname = "demo"\nversion = "1.0"\n{project}\n{extra}')
    return root


def write_package(directory: pathlib.Path, manifest: str, *files: str) -> pathlib.Path:
    """Write a Zig package manifest and create empty files."""
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "build.zig.zon").write_text(manifest)

    for name in files:
        (directory / name).write_text("")

    return directory


def fake_interpreter(
    platform: str = "linux-x86_64",
    *,
    implementation: str = "cpython",
    version: tuple[int, int] = (3, 13),
    soabi: str = "cpython-313-x86_64-linux-gnu",
    libc: str = "glibc",
    gil_disabled: bool = False,
) -> zypy.interpreter.Interpreter:
    """Make an interpreter description without running Python."""
    return zypy.interpreter.Interpreter(
        executable="python",
        implementation=implementation,
        version=version,
        soabi=soabi,
        platform=platform,
        libc=libc,
        gil_disabled=gil_disabled,
    )


def record(*args: object, **kwargs: object) -> tuple[tuple[object, ...], dict[str, object]]:
    """Return the arguments a function was called with."""
    return args, kwargs


def raiser(error: BaseException) -> collections.abc.Callable[[], None]:
    """Create a function that raises `error`."""

    def fail() -> None:
        """Raise the error."""
        raise error

    return fail


def failing_numbers() -> collections.abc.Iterator[int]:
    """Yield a number, then raise ValueError."""
    yield 1
    raise ValueError("broken generator")
