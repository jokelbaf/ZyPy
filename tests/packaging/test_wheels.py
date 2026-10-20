import base64
import csv
import hashlib
import io
import os
import pathlib
import sys
import tarfile
import typing
import zipfile

import pytest

import helpers
import zypy.artifacts.sdist
import zypy.artifacts.wheel
import zypy.backend
import zypy.build
import zypy.errors
import zypy.interpreter
import zypy.project

HELLO_STUB: typing.Final = '''\
"""A Python module written in Zig."""

import collections.abc
import typing

def add(arg0: int, arg1: int, /) -> int:
    """Add two numbers."""

def greet(name: str, greeting: str = 'Hello') -> str:
    """Greet someone by name."""

def sum(arg0: collections.abc.Iterable[float], /) -> float:
    """Sum any iterable of numbers."""

def count_words(arg0: collections.abc.Iterable[object], /) -> dict[typing.Any, typing.Any]:
    """Count how often each word occurs."""
'''


def check_record(wheel: zipfile.ZipFile) -> None:
    """Check that RECORD lists every file in the wheel, with the right hash and size."""
    record_name = next(name for name in wheel.namelist() if name.endswith(".dist-info/RECORD"))
    rows = {row[0]: row[1:] for row in csv.reader(io.StringIO(wheel.read(record_name).decode()))}
    assert set(rows) == set(wheel.namelist())
    assert rows.pop(record_name) == ["", ""]

    for name, (digest, size) in rows.items():
        data = wheel.read(name)
        expected = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        assert digest == f"sha256={expected}", name
        assert size == str(len(data)), name


@helpers.requires_uv
def test_uv_build(tmp_path: pathlib.Path) -> None:
    """Check that `uv build` builds a wheel from an unpacked source distribution."""
    project = helpers.copy_example("hello", tmp_path)
    helpers.run("uv", "build", "--python", sys.executable, "--out-dir", tmp_path / "dist", cwd=project)

    wheel_name = f"hello-0.1.0-{helpers.PYTHON_TAG}-{helpers.PYTHON_TAG}-{helpers.MANYLINUX_TAGS}.whl"
    assert sorted(path.name for path in (tmp_path / "dist").glob("[!.]*")) == [wheel_name, "hello-0.1.0.tar.gz"]

    with zipfile.ZipFile(tmp_path / "dist" / wheel_name) as wheel:
        names = wheel.namelist()
        assert names[:2] == [f"hello{helpers.EXT_SUFFIX}", "hello.pyi"]
        assert names[2:] == [f"hello-0.1.0.dist-info/{name}" for name in ("METADATA", "WHEEL", "RECORD")]
        assert wheel.read("hello.pyi").decode() == HELLO_STUB
        check_record(wheel)

        wheel_info = wheel.read("hello-0.1.0.dist-info/WHEEL").decode()
        assert f"Tag: {helpers.PYTHON_TAG}-{helpers.PYTHON_TAG}-manylinux_2_17_{helpers.ARCHITECTURE}" in wheel_info

    with tarfile.open(tmp_path / "dist" / "hello-0.1.0.tar.gz") as sdist:
        names = sdist.getnames()
        assert "hello-0.1.0/PKG-INFO" in names
        assert "hello-0.1.0/zig-deps/zypy/src/root.zig" in names
        assert "hello-0.1.0/zig-deps/zypy/build/Python.zig" in names
        assert not any("zig-out" in name or ".zig-cache" in name or "/examples/" in name for name in names)

        zon = sdist.extractfile("hello-0.1.0/build.zig.zon")
        assert zon is not None
        assert '.zypy = .{ .path = "zig-deps/zypy" }' in zon.read().decode()

    venv = tmp_path / "venv"
    helpers.run("uv", "venv", "--python", sys.executable, venv)
    helpers.run("uv", "pip", "install", "--python", venv / "bin" / "python", tmp_path / "dist" / wheel_name)

    out = helpers.run(venv / "bin" / "python", "-c", "import hello; print(hello.add(2, 3), hello.greet('ZyPy'))")
    assert out.splitlines()[0] == "5 Hello, ZyPy!"


@helpers.requires_uv
def test_wheel_is_manylinux(tmp_path: pathlib.Path) -> None:
    """Check that auditwheel accepts wheels as manylinux_2_17."""
    project = zypy.project.Project.load(helpers.copy_example("hello", tmp_path))
    wheel = zypy.build.build_wheel(project, tmp_path, zypy.interpreter.Interpreter.current())

    out = helpers.run("uvx", "auditwheel", "show", wheel)
    assert f'consistent with the following platform tag:\n"manylinux_2_17_{helpers.ARCHITECTURE}"' in out


def test_manylinux_off(tmp_path: pathlib.Path) -> None:
    """Check native platform tags when manylinux is disabled."""
    root = helpers.copy_example("hello", tmp_path)
    project = zypy.project.Project.load(root, {"manylinux": "off", "optimize": "debug"})

    wheel = zypy.build.build_wheel(project, tmp_path, zypy.interpreter.Interpreter.current())
    assert wheel.name == f"hello-0.1.0-{helpers.PYTHON_TAG}-{helpers.PYTHON_TAG}-linux_{helpers.ARCHITECTURE}.whl"


def test_mixed_wheel(tmp_path: pathlib.Path) -> None:
    """Check that a mixed-project wheel contains its Python package and extension."""
    project = zypy.project.Project.load(helpers.copy_example("mixed", tmp_path))
    wheel = zypy.build.build_wheel(project, tmp_path, zypy.interpreter.Interpreter.current())

    with zipfile.ZipFile(wheel) as archive:
        names = archive.namelist()
        check_record(archive)

    assert names[:4] == ["mixed/__init__.py", f"mixed/_core{helpers.EXT_SUFFIX}", "mixed/_core.pyi", "mixed/py.typed"]


def test_wheels_mark_packages_with_stubs_as_typed(tmp_path: pathlib.Path) -> None:
    """Check that wheels add missing py.typed markers to packages with type stubs."""
    project = helpers.copy_example("mixed", tmp_path)
    (project / "python" / "mixed" / "py.typed").unlink()

    wheel = zypy.build.build_wheel(zypy.project.Project.load(project), tmp_path, zypy.interpreter.Interpreter.current())
    with zipfile.ZipFile(wheel) as archive:
        stub = archive.read("mixed/_core.pyi").decode()
        assert archive.read("mixed/py.typed") == b""
        assert "def mean(arg0: collections.abc.Iterable[float], /) -> float:" in stub
        check_record(archive)


@pytest.mark.parametrize(("installed", "source"), [("pkg/_core.so", "pkg"), ("pkg", "pkg/module.py")])
def test_wheels_refuse_files_where_other_files_need_a_directory(
    tmp_path: pathlib.Path, installed: str, source: str
) -> None:
    """Check errors for file and directory path conflicts in wheels."""
    root = helpers.write_project(tmp_path / "project", '[tool.zypy]\npython-source = "python"')
    for path in (tmp_path / "installed" / installed, root / "python" / source):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("")

    with pytest.raises(
        zypy.errors.ZypyError, match=r"pkg has the same path in the wheel as a directory of other files"
    ):
        zypy.build._wheel_files(zypy.project.Project.load(root), tmp_path / "installed")


def test_prepare_metadata(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check that wheels reuse metadata prepared without building an extension."""
    root = helpers.copy_example("hello", tmp_path)
    monkeypatch.chdir(root)

    name = zypy.backend.prepare_metadata_for_build_wheel(str(tmp_path / "meta"))
    prepared = (tmp_path / "meta" / name / "METADATA").read_bytes()
    assert name == "hello-0.1.0.dist-info"
    assert b"Name: hello" in prepared

    pyproject = root / "pyproject.toml"
    pyproject.write_text(pyproject.read_text().replace("A ZyPy example", "A changed example"))
    (tmp_path / "wheels").mkdir()

    wheel_name = zypy.backend.build_wheel(str(tmp_path / "wheels"), metadata_directory=str(tmp_path / "meta" / name))
    with zipfile.ZipFile(tmp_path / "wheels" / wheel_name) as wheel:
        assert wheel.read(f"{name}/METADATA") == prepared
        check_record(wheel)

    pyproject.write_text(pyproject.read_text().replace('version = "0.1.0"', 'version = "0.2.0"'))
    with pytest.raises(zypy.errors.ZypyError, match=r"isn't for hello-0\.2\.0\.dist-info"):
        zypy.backend.build_wheel(str(tmp_path / "wheels"), metadata_directory=str(tmp_path / "meta" / name))


def test_failed_writes_keep_older_files(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check that failed archive writes preserve existing files and leave no partial output."""
    project = zypy.project.Project.load(helpers.write_project(tmp_path / "p"))
    out = tmp_path / "out"
    out.mkdir()
    wheel = out / "demo.whl"
    wheel.write_bytes(b"older")

    with pytest.raises(FileNotFoundError), zypy.artifacts.wheel.create(wheel, project) as writer:
        writer.write_file("missing", tmp_path / "missing")

    assert wheel.read_bytes() == b"older"

    monkeypatch.setenv("SOURCE_DATE_EPOCH", "soon")
    with pytest.raises(zypy.errors.ZypyError, match="SOURCE_DATE_EPOCH must be a number"):
        zypy.artifacts.sdist.build_sdist(project, out)

    for epoch in ("-1", str(2**32)):
        monkeypatch.setenv("SOURCE_DATE_EPOCH", epoch)
        with pytest.raises(zypy.errors.ZypyError, match="SOURCE_DATE_EPOCH must be from 0 to 4294967295"):
            zypy.artifacts.sdist.build_sdist(project, out)

    monkeypatch.setenv("SOURCE_DATE_EPOCH", "soon")
    with (
        pytest.raises(zypy.errors.ZypyError, match="SOURCE_DATE_EPOCH must be a number"),
        zypy.artifacts.wheel.create(wheel, project),
    ):
        pass

    assert wheel.read_bytes() == b"older"
    assert [path.name for path in out.iterdir()] == ["demo.whl"]


def test_reproducible_builds(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check reproducible wheels and source distributions with SOURCE_DATE_EPOCH."""
    project = zypy.project.Project.load(helpers.copy_example("hello", tmp_path))
    python = zypy.interpreter.Interpreter.current()

    first = zypy.build.build_wheel(project, tmp_path, python).read_bytes()
    os.utime(project.root / "src" / "root.zig")
    assert zypy.build.build_wheel(project, tmp_path, python).read_bytes() == first

    monkeypatch.setenv("SOURCE_DATE_EPOCH", "1700000000")
    first = zypy.artifacts.sdist.build_sdist(project, tmp_path).read_bytes()
    os.utime(project.root / "src" / "root.zig")
    assert zypy.artifacts.sdist.build_sdist(project, tmp_path).read_bytes() == first
