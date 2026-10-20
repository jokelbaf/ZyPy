import os
import pathlib
import signal
import subprocess
import sys
import threading
import typing
import zipfile

import pytest

import helpers
import zypy.build
import zypy.editable
import zypy.errors
import zypy.interpreter
import zypy.project
import zypy.settings

STAGE: typing.Final = """
import os
import pathlib
import signal
import sys

import zypy.editable

with zypy.editable.staging(pathlib.Path(sys.argv[1])) as directory:
    (directory / "partial.so").write_text("")
    print(directory.name, flush=True)
    if sys.argv[2] == "kill":
        os.kill(os.getpid(), signal.SIGKILL)
    sys.stdin.read()
"""


def build_editable(project: zypy.project.Project, directory: pathlib.Path) -> pathlib.Path:
    """Build a debug editable wheel for the current interpreter."""
    python = zypy.interpreter.Interpreter.current()
    return zypy.build.build_editable(project, directory, python, zypy.settings.Optimize.DEBUG)


def edit_build(project: zypy.project.Project, old: str, new: str) -> None:
    """Replace text in a project's build.zig."""
    build_zig = project.root / "build.zig"
    text = build_zig.read_text()
    assert old in text

    build_zig.write_text(text.replace(old, new))


def staged_build(prefix: pathlib.Path, *names: str) -> pathlib.Path:
    """Create build output files containing their own names."""
    for name in names:
        path = prefix / "python" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(name)

    return prefix


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
    assert link.is_symlink()
    assert link.resolve().is_relative_to(project.root / "zig-out")

    build_editable(project, tmp_path)
    assert link.is_symlink()

    with zipfile.ZipFile(zypy.build.build_wheel(project, tmp_path, zypy.interpreter.Interpreter.current())) as wheel:
        assert sum(name.endswith(".so") for name in wheel.namelist()) == 1


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
    assert (package / "_core.pyi").is_symlink()

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


def test_editable_removes_abandoned_staging(tmp_path: pathlib.Path) -> None:
    """Check that editable builds remove abandoned temporary directories and preserve active ones."""
    output = tmp_path / "zig-out"
    killed = subprocess.run([sys.executable, "-c", STAGE, output, "kill"], capture_output=True, text=True, check=False)
    assert killed.returncode == -signal.SIGKILL
    assert (output / killed.stdout.strip() / "partial.so").is_file()

    with subprocess.Popen(
        [sys.executable, "-c", STAGE, output, "wait"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    ) as running:
        assert running.stdout is not None
        busy = output / running.stdout.readline().strip()

        with zypy.editable.staging(output) as directory:
            assert sorted(output.iterdir()) == sorted([busy, directory])
            assert (busy / "partial.so").is_file()

        running.communicate("")

    assert running.returncode == 0
    assert list(output.iterdir()) == []


def test_editable_staging_made_again_after_removal(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check recovery if another build removes a temporary directory before it is opened."""
    opened: list[pathlib.Path] = []
    open_file = os.open

    def removed_first(path: pathlib.Path, flags: int) -> int:
        """Remove the first directory before opening it to simulate concurrent build cleanup."""
        opened.append(path)
        if len(opened) == 1:
            path.rmdir()

        return open_file(path, flags)

    monkeypatch.setattr(os, "open", removed_first)
    with zypy.editable.staging(tmp_path / "zig-out") as directory:
        monkeypatch.undo()
        assert opened == [opened[0], directory]

    assert list((tmp_path / "zig-out").iterdir()) == []


def test_editable_installs_take_turns(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check that concurrent editable installs run in turn and record the installed files."""
    root = tmp_path / "project"
    output = root / "zig-out" / "python"
    zypy.editable.install(staged_build(tmp_path / "old", "old.so"), root, None)

    paused, resume = threading.Event(), threading.Event()
    remove_files = zypy.editable._remove_files

    def pause_once(directory: pathlib.Path, paths: set[pathlib.Path]) -> None:
        """Pause the first install before removing stale files."""
        if not paused.is_set():
            paused.set()
            resume.wait()

        remove_files(directory, paths)

    monkeypatch.setattr(zypy.editable, "_remove_files", pause_once)
    installs = [
        threading.Thread(target=zypy.editable.install, args=(staged_build(tmp_path / name, f"{name}.so"), root, None))
        for name in ("first", "second")
    ]

    installs[0].start()
    assert paused.wait(10)

    installs[1].start()
    installs[1].join(0.5)
    resume.set()

    for install in installs:
        install.join()

    assert sorted(path.name for path in output.iterdir()) == [".zypy-editable.json", "second.so"]
    assert zypy.editable.Manifest.read(output).files == {"second.so"}


def test_editable_checks_paths_first(tmp_path: pathlib.Path) -> None:
    """Check that path conflicts stop installation before changing existing files."""
    root = tmp_path / "project"
    source = root / "src"
    output = root / "zig-out" / "python"
    source.mkdir(parents=True)

    zypy.editable.install(staged_build(tmp_path / "first", "old.so"), root, source)
    (source / "blocked").write_text("mine")

    with pytest.raises(zypy.errors.ZypyError, match=r"blocked is a file, where zig build needs a directory for"):
        zypy.editable.install(staged_build(tmp_path / "second", "blocked/new.so"), root, source)

    assert (source / "old.so").read_text() == "old.so"
    assert (source / "blocked").read_text() == "mine"
    assert zypy.editable.Manifest.read(output).files == {"old.so"}

    (output / "package").write_text("mine")
    with pytest.raises(zypy.errors.ZypyError, match=r"package is a file, where zig build needs a directory for"):
        zypy.editable.install(staged_build(tmp_path / "third", "package/new.so"), root, None)

    assert (source / "old.so").read_text() == "old.so"
    assert sorted(path.name for path in output.iterdir()) == [".zypy-editable.json", "old.so", "package"]
