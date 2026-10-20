import argparse
import collections.abc
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

import zypy
import zypy.artifacts.sdist
import zypy.build
import zypy.errors
import zypy.interpreter
import zypy.new
import zypy.project
import zypy.settings


def main(argv: collections.abc.Sequence[str] | None = None) -> int:
    """Run the zypy command and return its exit code."""
    args = _parser().parse_args(argv)

    try:
        match args.command:
            case "new":
                _new(args.path, args.name, args.zypy)
            case "develop":
                _develop(args.python, args.optimize)
            case "build":
                _build(args.python, args.out, optimize=args.optimize, manylinux=args.manylinux, sdist=args.sdist)
    except zypy.errors.ZypyError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    return 0


def _parser() -> argparse.ArgumentParser:
    """Define the command-line arguments and help text."""
    parser = argparse.ArgumentParser(prog="zypy", description="Write Python extensions in Zig.")
    parser.add_argument("--version", action="version", version=f"zypy {zypy.__version__}")
    commands = parser.add_subparsers(dest="command", required=True)

    new = commands.add_parser("new", help="create a project")
    new.add_argument("path", type=pathlib.Path)
    new.add_argument("--name", help="project name (default: the directory's name)")
    new.add_argument("--zypy", metavar="PATH_OR_URL", help="path or URL for ZyPy's Zig package")

    develop = commands.add_parser("develop", help="build and install the project in editable mode")
    develop.add_argument(
        "--optimize",
        type=zypy.settings.Optimize,
        choices=list(zypy.settings.Optimize),
        default=zypy.settings.Optimize.DEBUG,
        help="Zig optimize mode (default: debug)",
    )
    develop.add_argument(
        "-i", "--python", type=pathlib.Path, help="the venv's Python (default: $VIRTUAL_ENV, then .venv)"
    )

    build = commands.add_parser("build", help="build wheels and optionally a source distribution")
    build.add_argument(
        "-i",
        "--python",
        type=pathlib.Path,
        action="append",
        help="Python to build a wheel for; repeat it for several (default: virtual environment, then current Python)",
    )
    build.add_argument("-o", "--out", type=pathlib.Path, default=pathlib.Path("dist"), help="output directory")
    build.add_argument("--sdist", action="store_true", help="also build a source distribution (sdist)")
    build.add_argument(
        "--optimize",
        type=zypy.settings.Optimize,
        choices=list(zypy.settings.Optimize),
        help="override the optimize setting in [tool.zypy]",
    )
    build.add_argument("--manylinux", help='oldest glibc to support, e.g. "2_28", or "off"')

    return parser


def _new(path: pathlib.Path, name: str | None, source: str | None) -> None:
    """Create a project and print the next steps."""
    zypy.new.new_project(path, name, source)
    print(f"Created {path}. Next: cd {path} && uv sync", file=sys.stderr)


def _develop(python: pathlib.Path | None, optimize: zypy.settings.Optimize) -> None:
    """Build the current project and install it in editable mode in a virtual environment."""
    venv_python = python or _venv_python()
    if venv_python is None:
        raise zypy.errors.ZypyError(
            "no virtual environment found: activate one, create .venv (uv venv), or pass --python"
        )

    project = zypy.project.Project.load()
    interpreter = zypy.interpreter.Interpreter.at(venv_python)

    with tempfile.TemporaryDirectory(prefix="zypy-") as directory:
        wheel = zypy.build.build_editable(project, pathlib.Path(directory), interpreter, optimize)
        _install(venv_python, wheel, project.metadata.canonical_name)

    print(f"Installed {project.metadata.name} into {venv_python} ({optimize} build, editable)", file=sys.stderr)


def _build(
    pythons: list[pathlib.Path] | None,
    out: pathlib.Path,
    *,
    optimize: zypy.settings.Optimize | None,
    manylinux: str | None,
    sdist: bool,
) -> None:
    """Build wheels for the selected interpreters and optionally a source distribution.

    For abi3, build once with the first selected interpreter.
    """
    overrides = {key: value for key, value in (("optimize", optimize), ("manylinux", manylinux)) if value is not None}
    project = zypy.project.Project.load(".", overrides)
    interpreters = [zypy.interpreter.Interpreter.at(python) for python in pythons or [_venv_python() or sys.executable]]
    if project.settings.abi3 is not None:
        interpreters = interpreters[:1]

    out.mkdir(parents=True, exist_ok=True)
    if sdist:
        print(zypy.artifacts.sdist.build_sdist(project, out), file=sys.stderr)

    for interpreter in interpreters:
        print(zypy.build.build_wheel(project, out, interpreter), file=sys.stderr)


def _venv_python() -> pathlib.Path | None:
    """Find Python in the active virtual environment or the project's .venv."""
    if venv := os.environ.get("VIRTUAL_ENV"):
        return pathlib.Path(venv) / "bin" / "python"

    if (local := pathlib.Path(".venv") / "bin" / "python").exists():
        return local.absolute()

    return None


def _install(python: pathlib.Path, wheel: pathlib.Path, name: str) -> None:
    """Install `wheel` into the environment of `python` using uv or pip."""
    if uv := shutil.which("uv"):
        command = [uv, "pip", "install", "--python", str(python), "--reinstall-package", name, str(wheel)]
    else:
        command = [str(python), "-m", "pip", "install", "--force-reinstall", "--no-deps", str(wheel)]

    if subprocess.run(command, check=False).returncode != 0:
        raise zypy.errors.ZypyError(f"installing the wheel failed ({' '.join(command)})")
