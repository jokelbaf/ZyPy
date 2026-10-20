import os
import pathlib
import subprocess
import sys
import typing

import pytest

import helpers
import zypy.zig

EMBED_TESTS: typing.Final = helpers.REPO / "tests" / "embed"


def test_embed(tmp_path: pathlib.Path) -> None:
    """Check embedded Python and Zig module imports, including from another thread."""
    project = helpers.copy_example("embed", tmp_path)
    helpers.run(*zypy.zig.command(), "build", f"-Dpython={sys.executable}", cwd=project)

    program = project / "zig-out" / "bin" / "embed"
    result = subprocess.run([program, "one", "--two"], capture_output=True, text=True, check=True)

    assert result.stderr == 'json.dumps: {"name": "Ann", "scores": [9.5, 7.0]}\npy.eval: 42\n'
    assert result.stdout == (
        "sys.argv: ['one', '--two']\ndemo.add: 5\ndemo.Greeter: Hello, Ann!\nfrom a Zig thread: Hello, Bo!\n"
    )


def test_interpreter_settings(tmp_path: pathlib.Path) -> None:
    """Check interpreter home, arguments, search paths, and optional site import."""
    helpers.run(*zypy.zig.command(), "build", "--prefix", tmp_path, f"-Dpython={sys.executable}", cwd=EMBED_TESTS)

    result = helpers.run(tmp_path / "bin" / "settings", sys.base_prefix, "script.py", "-x")
    assert result.splitlines() == [sys.base_prefix, "['/zypy/first', '/zypy/second']", "False", "['script.py', '-x']"]


def test_bundled_python(tmp_path: pathlib.Path) -> None:
    """Check that a bundled program uses its own Python from any working directory."""
    helpers.run(*zypy.zig.command(), "build", "-Dbundle", "--prefix", tmp_path / "install", cwd=EMBED_TESTS)

    app = tmp_path / "moved" / "app"
    app.parent.mkdir()
    (tmp_path / "install").rename(app)

    environment = {name: value for name, value in os.environ.items() if not name.startswith(("PYTHON", "VIRTUAL_ENV"))}
    result = subprocess.run(
        [app / "bin" / "bundled"], cwd=tmp_path, env=environment, capture_output=True, text=True, check=True
    )

    assert result.stdout.splitlines() == [
        str(app),
        str(app / "bin" / "bundled"),
        "3.14",
        str(app / "lib" / "python3.14" / "json" / "__init__.py"),
        "42",
    ]


@pytest.mark.parametrize(
    ("target", "header", "library"),
    [
        ("aarch64-linux-gnu", b"\x7fELF", "libpython3.14.so.1.0"),
        ("aarch64-macos", b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01", "libpython3.14.dylib"),
    ],
)
def test_bundled_python_cross_compiles(tmp_path: pathlib.Path, target: str, header: bytes, library: str) -> None:
    """Check cross-compilation of programs that bundle Python."""
    helpers.run(*zypy.zig.command(), "build", "-Dbundle", f"-Dtarget={target}", "--prefix", tmp_path, cwd=EMBED_TESTS)

    assert (tmp_path / "bin" / "bundled").read_bytes().startswith(header)
    assert (tmp_path / "lib" / library).is_file()
    assert (tmp_path / "lib" / "python3.14" / "os.py").is_file()


def test_bundled_python_lists_supported_targets(tmp_path: pathlib.Path) -> None:
    """Check that unsupported bundle targets report the supported platforms."""
    command = [*zypy.zig.command(), "build", "-Dbundle", "-Dtarget=x86-linux-gnu", "--prefix", tmp_path]
    result = subprocess.run(command, cwd=EMBED_TESTS, capture_output=True, text=True, check=False)

    assert result.returncode != 0
    assert "ZyPy has no Python to bundle for x86-linux-gnu (supported: x86_64-linux-gnu, " in result.stderr
    assert ", x86_64-macos, aarch64-macos)" in result.stderr
