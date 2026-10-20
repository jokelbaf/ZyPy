import os
import pathlib
import sys

import pytest

import helpers
import zypy.cli
import zypy.settings


def run_zypy(*args: str | os.PathLike[str], cwd: pathlib.Path) -> str:
    """Run the zypy command in `cwd`."""
    return helpers.run(sys.executable, "-m", "zypy", *args, cwd=cwd)


@helpers.requires_uv
def test_new_build_develop(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check that a new project builds distributions and installs into its .venv."""
    monkeypatch.delenv("VIRTUAL_ENV", raising=False)

    run_zypy("new", "my-proj", "--zypy", helpers.REPO, cwd=tmp_path)
    project = tmp_path / "my-proj"
    assert sorted(path.name for path in project.iterdir()) == [
        ".gitignore",
        "build.zig",
        "build.zig.zon",
        "pyproject.toml",
        "src",
    ]
    assert "py.exportModule(module);" in (project / "src" / "root.zig").read_text()
    pyproject = (project / "pyproject.toml").read_text()
    assert 'zypy = { path = "../../../' in pyproject
    assert 'dev = ["zypy>=' in pyproject

    run_zypy("build", "--python", sys.executable, "--sdist", cwd=project)
    wheel = project / "dist" / f"my_proj-0.1.0-{helpers.PYTHON_TAG}-{helpers.PYTHON_TAG}-{helpers.MANYLINUX_TAGS}.whl"
    assert wheel.is_file()
    assert (project / "dist" / "my_proj-0.1.0.tar.gz").is_file()

    helpers.run("uv", "venv", "--python", sys.executable, cwd=project)
    run_zypy("develop", cwd=project)

    code = "import my_proj; print(my_proj.add(2, 3), my_proj.__file__)"
    result, path = helpers.run(project / ".venv" / "bin" / "python", "-c", code).split()
    assert result == "5"
    assert path.startswith(str(project / "zig-out"))


def test_new_refuses_non_empty_directories(tmp_path: pathlib.Path) -> None:
    """Check that `zypy new` preserves non-empty directories."""
    (tmp_path / "taken").mkdir()
    (tmp_path / "taken" / "file").write_text("")

    with pytest.raises(AssertionError, match="already exists and isn't empty"):
        run_zypy("new", "taken", "--zypy", helpers.REPO, cwd=tmp_path)


def test_develop_needs_a_venv(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check that `zypy develop` explains how to create a missing virtual environment."""
    monkeypatch.delenv("VIRTUAL_ENV", raising=False)
    project = helpers.copy_example("hello", tmp_path)

    with pytest.raises(AssertionError, match="no virtual environment found"):
        run_zypy("develop", cwd=project)


@helpers.requires_uv
def test_build_for_several_pythons(tmp_path: pathlib.Path) -> None:
    """Check that `zypy build` builds a wheel for each selected interpreter."""
    project = helpers.copy_example("hello", tmp_path)
    pythons = [helpers.run("uv", "python", "find", version).strip() for version in ("3.13+gil", "3.14+gil")]

    run_zypy("build", "-i", pythons[0], "-i", pythons[1], cwd=project)
    wheels = sorted(path.name for path in (project / "dist").glob("*.whl"))
    assert wheels == [f"hello-0.1.0-{tag}-{tag}-{helpers.MANYLINUX_TAGS}.whl" for tag in ("cp313", "cp314")]


def test_optimize_option() -> None:
    """Check optimize modes for `zypy build` and `zypy develop`, including the default debug build."""
    parser = zypy.cli._parser()
    assert parser.parse_args(["develop"]).optimize is zypy.settings.Optimize.DEBUG
    assert parser.parse_args(["develop", "--optimize", "fast"]).optimize is zypy.settings.Optimize.FAST
    assert parser.parse_args(["build", "--optimize", "small"]).optimize is zypy.settings.Optimize.SMALL
    assert parser.parse_args(["build"]).optimize is None
