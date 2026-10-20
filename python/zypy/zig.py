import functools
import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys
import typing

import zypy.errors
import zypy.settings

ZIG_VERSION: typing.Final = "0.17"


@functools.cache
def command() -> tuple[str, ...]:
    """Find Zig using $ZYPY_ZIG, the ziglang package, or PATH, in that order."""
    zig = _find()

    version = _version(zig)
    if version != ZIG_VERSION and not version.startswith(f"{ZIG_VERSION}."):
        raise zypy.errors.ZypyError(f"ZyPy needs Zig {ZIG_VERSION}.x, but {' '.join(zig)} is {version}")

    return zig


def build(
    root: pathlib.Path,
    prefix: pathlib.Path,
    *,
    python: str,
    optimize: zypy.settings.Optimize,
    target: str | None,
    abi3: str | None = None,
) -> pathlib.Path:
    """Run `zig build install` in `root` and return the extension directory, `<prefix>/python`.

    Set `abi3`, such as "3.13", to target the stable ABI starting at that Python version.
    """
    args = [*command(), "build", "install", "--prefix", str(prefix), f"-Doptimize={optimize}", f"-Dpython={python}"]
    if target is not None:
        args.append(f"-Dtarget={target}")
    if abi3 is not None:
        args.append(f"-Dabi3={abi3}")

    print("zypy: running", " ".join(args), file=sys.stderr, flush=True)
    if subprocess.run(args, cwd=root, check=False).returncode != 0:
        raise zypy.errors.ZypyError("zig build failed")

    installed = prefix / "python"
    if not installed.is_dir() or not any(path.is_file() for path in installed.rglob("*")):
        raise zypy.errors.ZypyError(
            f"zig build installed nothing into {installed}: does build.zig call zypy.addExtension?"
        )

    return installed


def _find() -> tuple[str, ...]:
    """Locate a Zig command, without checking its version."""
    if override := os.environ.get("ZYPY_ZIG"):
        return (override,)

    if importlib.util.find_spec("ziglang"):
        return (sys.executable, "-m", "ziglang")

    if path := shutil.which("zig"):
        return (path,)

    raise zypy.errors.ZypyError("Zig not found: install the ziglang package, put zig on PATH, or set ZYPY_ZIG")


def _version(zig: tuple[str, ...]) -> str:
    """Ask Zig for its version."""
    try:
        result = subprocess.run([*zig, "version"], capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise zypy.errors.ZypyError(f"can't run Zig ({' '.join(zig)}): {error}") from error

    return result.stdout.strip()
