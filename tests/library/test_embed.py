import os
import pathlib
import subprocess
import sys
import typing

import pytest

import helpers
import zypy.zig

EMBED_TESTS: typing.Final = helpers.REPO / "tests" / "embed"


@pytest.mark.parametrize("python", [f"-Dpython={sys.executable}", f"-Dpython={helpers.BASE_PYTHON}", "-Dbundle-python"])
def test_embed(tmp_path: pathlib.Path, python: str) -> None:
    """Check embedding and Zig thread imports with virtual, base, and bundled Python installations."""
    project = helpers.copy_example("embed", tmp_path)
    command = [*zypy.zig.command(), "build", "run", python, "--", "one", "--two"]
    environment = {name: value for name, value in os.environ.items() if not name.startswith(("PYTHON", "VIRTUAL_ENV"))}
    result = subprocess.run(command, cwd=project, env=environment, capture_output=True, text=True, check=False)

    assert result.returncode == 0, result.stderr
    assert result.stderr == 'json.dumps: {"name": "Ann", "scores": [9.5, 7.0]}\npy.eval: 42\n'
    assert result.stdout == (
        "sys.argv: ['one', '--two']\ndemo.add: 5\ndemo.Greeter: Hello, Ann!\nfrom a Zig thread: Hello, Bo!\n"
    )


def test_interpreter_settings(tmp_path: pathlib.Path) -> None:
    """Check interpreter home, arguments, search paths, and optional site import."""
    helpers.run(*zypy.zig.command(), "build", "--prefix", tmp_path, f"-Dpython={sys.executable}", cwd=EMBED_TESTS)

    result = helpers.run(tmp_path / "bin" / f"settings{helpers.EXE}", sys.base_prefix, "script.py", "-x")
    assert result.splitlines() == [sys.base_prefix, "['/zypy/first', '/zypy/second']", "False", "['script.py', '-x']"]


def test_bundled_python(tmp_path: pathlib.Path) -> None:
    """Check that a bundled program uses its own Python from any working directory."""
    helpers.run(*zypy.zig.command(), "build", "-Dbundle", "--prefix", tmp_path / "install", cwd=EMBED_TESTS)

    app = tmp_path / "moved" / "app"
    app.parent.mkdir()
    (tmp_path / "install").rename(app)

    environment = {name: value for name, value in os.environ.items() if not name.startswith(("PYTHON", "VIRTUAL_ENV"))}
    program = app / "bin" / f"bundled{helpers.EXE}"
    result = subprocess.run([program], cwd=tmp_path, env=environment, capture_output=True, text=True, check=True)

    standard_library = app / "Lib" if helpers.WINDOWS else app / "lib" / "python3.14"
    assert result.stdout.splitlines() == [
        str(app),
        str(program),
        "3.14",
        str(standard_library / "json" / "__init__.py"),
        "42",
    ]


@pytest.mark.parametrize(
    ("target", "program", "header", "files"),
    [
        ("aarch64-linux-gnu", "bundled", b"\x7fELF", ("lib/libpython3.14.so.1.0", "lib/python3.14/os.py")),
        (
            "aarch64-macos",
            "bundled",
            b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01",
            ("lib/libpython3.14.dylib", "lib/python3.14/os.py"),
        ),
        (
            "x86_64-windows-gnu",
            "bundled.exe",
            b"MZ",
            ("bin/python314.dll", "bin/python3.dll", "bin/vcruntime140_1.dll", "Lib/os.py", "DLLs/_ctypes.pyd"),
        ),
        ("x86-windows-gnu", "bundled.exe", b"MZ", ("bin/python314.dll", "bin/vcruntime140.dll", "Lib/os.py")),
    ],
)
def test_bundled_python_cross_compiles(
    tmp_path: pathlib.Path, target: str, program: str, header: bytes, files: tuple[str, ...]
) -> None:
    """Check that cross-compiled programs include the bundled Python files."""
    helpers.run(*zypy.zig.command(), "build", "-Dbundle", f"-Dtarget={target}", "--prefix", tmp_path, cwd=EMBED_TESTS)

    assert (tmp_path / "bin" / program).read_bytes().startswith(header)
    assert [name for name in files if not (tmp_path / name).is_file()] == []


def test_bundled_python_lists_supported_targets(tmp_path: pathlib.Path) -> None:
    """Check that unsupported bundle targets report the supported platforms."""
    command = [*zypy.zig.command(), "build", "-Dbundle", "-Dtarget=x86-linux-gnu", "--prefix", tmp_path]
    result = subprocess.run(command, cwd=EMBED_TESTS, capture_output=True, text=True, check=False)

    assert result.returncode != 0
    assert "ZyPy has no Python to bundle for x86-linux-gnu (supported: x86_64-linux-gnu, " in result.stderr
    assert ", aarch64-macos, x86_64-windows, aarch64-windows, x86-windows)" in result.stderr
