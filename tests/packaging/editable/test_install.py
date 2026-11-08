import hashlib
import pathlib
import sys
import threading

import pytest

import zypy.artifacts.files
import zypy.editable
import zypy.errors


def staged_build(prefix: pathlib.Path, *names: str) -> pathlib.Path:
    """Create build output files containing their own names."""
    for name in names:
        path = prefix / "python" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(name)

    return prefix


def test_editable_installs_take_turns(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check that concurrent installs run one at a time and record their output."""
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


def test_editable_copies_where_links_fail(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check that editable copies are updated, cleaned up, and excluded from package sources."""
    root = tmp_path / "project"
    source = root / "src"
    source.mkdir(parents=True)
    monkeypatch.setattr(pathlib.Path, "symlink_to", refuse_link)

    zypy.editable.install(staged_build(tmp_path / "first", "pkg/_core.so", "pkg/_core.pyi"), root, source)
    copy = source / "pkg" / "_core.pyi"
    assert not copy.is_symlink()
    assert copy.read_text() == "pkg/_core.pyi"
    assert zypy.editable.copies(root) == {copy, source / "pkg" / "_core.so"}

    manifest = zypy.editable.Manifest.read(root / "zig-out" / "python")
    assert manifest.links == {"src/pkg/_core.so", "src/pkg/_core.pyi"}
    assert manifest.copies["src/pkg/_core.pyi"] == hashlib.sha256(b"pkg/_core.pyi").hexdigest()

    (source / "pkg" / "__init__.py").write_text("")
    assert [name for name, _ in zypy.artifacts.files.walk(source, skip=zypy.editable.copies(root))] == [
        "pkg/__init__.py"
    ]

    second = staged_build(tmp_path / "second", "pkg/_core.so")
    (second / "python" / "pkg" / "_core.so").write_text("rebuilt")
    zypy.editable.install(second, root, source)
    assert (source / "pkg" / "_core.so").read_text() == "rebuilt"
    assert not copy.exists()
    assert zypy.editable.copies(root) == {source / "pkg" / "_core.so"}


def test_editable_keeps_changed_copies(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check that rebuilds preserve edited copies."""
    root = tmp_path / "project"
    source = root / "src"
    source.mkdir(parents=True)
    monkeypatch.setattr(pathlib.Path, "symlink_to", refuse_link)
    zypy.editable.install(staged_build(tmp_path / "first", "_core.pyi"), root, source)

    (source / "_core.pyi").write_text("mine")
    assert zypy.editable.copies(root) == set()

    with pytest.raises(zypy.errors.ZypyError, match="has the same path as a file zig build installs"):
        zypy.editable.install(staged_build(tmp_path / "second", "_core.pyi"), root, source)

    assert (source / "_core.pyi").read_text() == "mine"


@pytest.mark.skipif(sys.platform != "win32", reason="Windows can't replace loaded extensions")
def test_editable_explains_loaded_extensions(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check the rebuild error for a loaded Windows extension."""

    def refuse_replace(path: pathlib.Path, destination: pathlib.Path) -> None:
        """Simulate a loaded extension blocking replacement."""
        raise PermissionError(13, "Access is denied", str(destination), None, str(path))

    monkeypatch.setattr(zypy.editable, "_replace", refuse_replace)

    with pytest.raises(zypy.errors.ZypyError, match="stop any Python process using the extension and try again"):
        zypy.editable.install(staged_build(tmp_path / "build", "_core.pyd"), tmp_path / "project", None)


def refuse_link(path: pathlib.Path, target: pathlib.Path) -> None:
    """Simulate Windows denying permission to create a symbolic link."""
    raise OSError(1314, "A required privilege is not held by the client", str(path), None, str(target))
