import os
import pathlib
import signal
import subprocess
import sys
import typing

import pytest

import zypy.editable

KILL: typing.Final = getattr(signal, "SIGKILL", signal.SIGTERM)

STAGE: typing.Final = f"""
import os
import pathlib
import sys

import zypy.editable

with zypy.editable.staging(pathlib.Path(sys.argv[1])) as directory:
    (directory / "partial.so").write_text("")
    print(directory.name, flush=True)
    if sys.argv[2] == "kill":
        os.kill(os.getpid(), {int(KILL)})
    sys.stdin.read()
"""


def test_editable_removes_abandoned_staging(tmp_path: pathlib.Path) -> None:
    """Check that editable builds remove abandoned temporary directories and preserve active ones."""
    output = tmp_path / "zig-out"
    killed = subprocess.run([sys.executable, "-c", STAGE, output, "kill"], capture_output=True, text=True, check=False)
    assert killed.returncode == (KILL if sys.platform == "win32" else -KILL)
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
        directory = path.parent if path.name == zypy.editable.LOCK_FILE else path
        opened.append(directory)
        if len(opened) == 1:
            directory.rmdir()

        return open_file(path, flags)

    monkeypatch.setattr(os, "open", removed_first)
    with zypy.editable.staging(tmp_path / "zig-out") as directory:
        monkeypatch.undo()
        assert opened == [opened[0], directory]

    assert list((tmp_path / "zig-out").iterdir()) == []
