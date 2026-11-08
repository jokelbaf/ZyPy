import pathlib
import zipfile

import pytest

import helpers
import zypy.build
import zypy.editable
import zypy.errors
import zypy.interpreter
import zypy.project
import zypy.settings


def build_editable(project: zypy.project.Project, directory: pathlib.Path) -> pathlib.Path:
    """Build a debug editable wheel for the current interpreter."""
    python = zypy.interpreter.Interpreter.current()
    return zypy.build.build_editable(project, directory, python, zypy.settings.Optimize.DEBUG)


def is_editable_link(path: pathlib.Path, root: pathlib.Path) -> bool:
    """Check whether an editable build linked or copied `path`."""
    if path.is_symlink():
        return path.resolve().is_relative_to(root / "zig-out")

    return path in zypy.editable.copies(root)


def edit_build(project: zypy.project.Project, old: str, new: str) -> None:
    """Replace text in a project's build.zig."""
    build_zig = project.root / "build.zig"
    text = build_zig.read_text()
    assert old in text

    build_zig.write_text(text.replace(old, new))


def test_editable(tmp_path: pathlib.Path) -> None:
    """Check that editable wheels point to the project's zig-out/python directory."""
    project = zypy.project.Project.load(helpers.copy_example("hello", tmp_path))

    with zipfile.ZipFile(build_editable(project, tmp_path)) as wheel:
        assert wheel.read("_zypy_hello.pth").decode() == f"{project.root / 'zig-out' / 'python'}\n"

    assert (project.root / "zig-out" / "python" / f"hello{helpers.EXT_SUFFIX}").is_file()


def test_editable_mixed_links_extensions_into_sources(tmp_path: pathlib.Path) -> None:
    """Check that editable mixed projects link extensions into Python sources."""
    project = zypy.project.Project.load(helpers.copy_example("mixed", tmp_path))

    with zipfile.ZipFile(build_editable(project, tmp_path)) as wheel:
        assert wheel.read("_zypy_mixed.pth").decode() == f"{project.root / 'python'}\n"

    link = project.root / "python" / "mixed" / f"_core{helpers.EXT_SUFFIX}"
    assert is_editable_link(link, project.root)

    build_editable(project, tmp_path)
    assert is_editable_link(link, project.root)

    with zipfile.ZipFile(zypy.build.build_wheel(project, tmp_path, zypy.interpreter.Interpreter.current())) as wheel:
        assert sum(name.endswith(helpers.EXT_SUFFIX) for name in wheel.namelist()) == 1
        assert sum(name.endswith(".pyi") for name in wheel.namelist()) == 1


def test_editable_keeps_source_files(tmp_path: pathlib.Path) -> None:
    """Check that editable installs preserve existing source files."""
    project = zypy.project.Project.load(helpers.copy_example("mixed", tmp_path))
    in_the_way = project.root / "python" / "mixed" / f"_core{helpers.EXT_SUFFIX}"
    in_the_way.write_text("not a link")

    with pytest.raises(zypy.errors.ZypyError, match="has the same path as a file zig build installs"):
        build_editable(project, tmp_path)

    assert in_the_way.read_text() == "not a link"


def test_editable_removes_stale_outputs(tmp_path: pathlib.Path) -> None:
    """Check that editable builds remove only stale outputs recorded by earlier builds."""
    project = zypy.project.Project.load(helpers.copy_example("hello", tmp_path))
    output = project.root / "zig-out" / "python"
    abandoned = project.root / "zig-out" / ".zypy-killed" / "python"
    abandoned.mkdir(parents=True)
    (abandoned / f"hello{helpers.EXT_SUFFIX}").write_text("partial")

    build_editable(project, tmp_path)
    assert not abandoned.exists()

    (output / "notes.txt").write_text("mine")
    (project.root / "zig-out" / "bin").mkdir()
    (project.root / "zig-out" / "bin" / "tool").write_text("mine too")

    edit_build(project, '.name = "hello"', '.name = "greetings.hello"')
    build_editable(project, tmp_path)
    assert sorted(path.relative_to(output).as_posix() for path in output.rglob("*")) == [
        ".zypy-editable.json",
        "greetings",
        f"greetings/hello{helpers.EXT_SUFFIX}",
        "greetings/hello.pyi",
        "notes.txt",
    ]

    edit_build(project, '.name = "greetings.hello",', '.name = "renamed",\n        .stubs = false,')
    build_editable(project, tmp_path)
    assert sorted(path.name for path in output.iterdir()) == [
        ".zypy-editable.json",
        "notes.txt",
        f"renamed{helpers.EXT_SUFFIX}",
    ]
    assert (project.root / "zig-out" / "bin" / "tool").read_text() == "mine too"
    assert [path.name for path in (project.root / "zig-out").iterdir() if path.name.startswith(".zypy-")] == []

    (project.root / "src" / "root.zig").write_text("this isn't Zig")
    edit_build(project, '.name = "renamed",', '.name = "broken",')
    with pytest.raises(zypy.errors.ZypyError, match="zig build failed"):
        build_editable(project, tmp_path)

    assert (output / f"renamed{helpers.EXT_SUFFIX}").is_file()


def test_editable_mixed_removes_stale_links(tmp_path: pathlib.Path) -> None:
    """Check that editable builds remove stale package links while preserving other files."""
    project = zypy.project.Project.load(helpers.copy_example("mixed", tmp_path))
    package = project.root / "python" / "mixed"

    build_editable(project, tmp_path)
    (package / "notes.txt").write_text("mine")
    assert is_editable_link(package / "_core.pyi", project.root)

    edit_build(project, '.name = "mixed._core",', '.name = "mixed.fast._core",\n        .stubs = false,')
    build_editable(project, tmp_path)
    assert sorted(path.relative_to(package).as_posix() for path in package.rglob("*")) == [
        "__init__.py",
        "fast",
        f"fast/_core{helpers.EXT_SUFFIX}",
        "notes.txt",
        "py.typed",
    ]
    assert (package / "fast" / f"_core{helpers.EXT_SUFFIX}").resolve().is_file()

    edit_build(project, '.name = "mixed.fast._core",', '.name = "mixed._core",')
    build_editable(project, tmp_path)
    assert sorted(path.name for path in package.iterdir()) == [
        "__init__.py",
        f"_core{helpers.EXT_SUFFIX}",
        "notes.txt",
        "py.typed",
    ]

    pyproject = project.root / "pyproject.toml"
    pyproject.write_text(pyproject.read_text().replace('python-source = "python"', ""))
    build_editable(zypy.project.Project.load(project.root), tmp_path)
    assert sorted(path.name for path in package.iterdir()) == ["__init__.py", "notes.txt", "py.typed"]
