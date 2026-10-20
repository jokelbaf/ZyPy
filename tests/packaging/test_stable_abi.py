import pathlib
import sys
import typing
import zipfile

import pytest

import helpers
import zypy.build
import zypy.errors
import zypy.interpreter
import zypy.project
import zypy.settings
import zypy.zig

LIBRARY_TESTS: typing.Final = (
    "test_values.py",
    "test_enums.py",
    "test_containers.py",
    "test_buffers.py",
    "test_calling_python.py",
    "test_functions.py",
    "test_runtime.py",
    "test_ownership.py",
    "leaks",
    "classes",
    "test_modules.py",
)


def test_stable_abi_tags() -> None:
    """Check stable ABI wheel tags and the minimum Python version required to build them."""
    assert zypy.build.Abi.of(helpers.fake_interpreter(), None) == zypy.build.Abi("cp313", "cp313", None)
    assert zypy.build.Abi.of(helpers.fake_interpreter(version=(3, 14)), (3, 13)) == zypy.build.Abi(
        "cp313", "abi3", "3.13"
    )

    with pytest.raises(zypy.errors.ZypyError, match=r"need Python 3\.14 or later to build, got 3\.13"):
        zypy.build.Abi.of(helpers.fake_interpreter(), (3, 14))

    with pytest.raises(zypy.errors.ZypyError, match="free-threaded Python has no stable ABI"):
        zypy.build.Abi.of(helpers.fake_interpreter(gil_disabled=True), (3, 13))


@helpers.requires_uv
def test_stable_abi_wheel(tmp_path: pathlib.Path) -> None:
    """Check that an abi3 wheel imports in newer Python versions."""
    root = helpers.copy_example("hello", tmp_path)
    pyproject = root / "pyproject.toml"
    pyproject.write_text(pyproject.read_text() + '\n[tool.zypy]\nabi3 = "3.13"\n')

    project = zypy.project.Project.load(root)
    wheel = zypy.build.build_wheel(project, tmp_path, zypy.interpreter.Interpreter.current())
    assert wheel.name == f"hello-0.1.0-cp313-abi3-{helpers.MANYLINUX_TAGS}.whl"

    with zipfile.ZipFile(wheel) as archive:
        assert archive.namelist()[0] == "hello.abi3.so"

    venv = tmp_path / "venv"
    helpers.run("uv", "venv", "--python", "3.14+gil", venv)
    helpers.run("uv", "pip", "install", "--python", venv / "bin" / "python", wheel)

    out = helpers.run(venv / "bin" / "python", "-c", "import sys, hello; print(sys.version_info[:2], hello.add(2, 3))")
    assert out.strip() == "(3, 14) 5"


@helpers.requires_uv
def test_stable_abi_library(tmp_path: pathlib.Path) -> None:
    """Check the test extension on Python 3.14 using the Python 3.13 stable ABI."""
    installed = zypy.zig.build(
        helpers.REPO / "tests" / "ext",
        tmp_path,
        python=sys.executable,
        optimize=zypy.settings.Optimize.DEBUG,
        target=None,
        abi3="3.13",
    )

    tests = [f"tests/library/{name}" for name in LIBRARY_TESTS]
    command = ["uv", "run", "--isolated", "--python", "3.14+gil", "pytest", "-q", "-p", "no:cacheprovider"]
    helpers.run(*command, "--prebuilt-ext", installed, *tests, cwd=helpers.REPO)
