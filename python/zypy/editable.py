import collections.abc
import contextlib
import dataclasses
import hashlib
import json
import os
import pathlib
import shutil
import sys
import tempfile
import time
import typing

import zypy.artifacts.archive
import zypy.errors

if sys.platform == "win32":
    import msvcrt
else:
    import fcntl

MANIFEST: typing.Final = ".zypy-editable.json"
STAGING_PREFIX: typing.Final = ".zypy-"
LOCK_FILE: typing.Final = ".zypy.lock"
LOCK_INTERVAL: typing.Final = 0.05


@dataclasses.dataclass(frozen=True, slots=True)
class Manifest:
    """Files, links, copies, and directories managed by an editable install."""

    files: frozenset[str] = frozenset()
    links: frozenset[str] = frozenset()
    directories: frozenset[str] = frozenset()
    copies: collections.abc.Mapping[str, str] = dataclasses.field(default_factory=dict[str, str])

    @classmethod
    def read(cls, output: pathlib.Path) -> typing.Self:
        """Read the manifest in `output`, or return an empty one if it's missing or invalid."""
        try:
            data: object = json.loads((output / MANIFEST).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return cls()

        if not isinstance(data, dict):
            return cls()

        entries = typing.cast("dict[str, object]", data)
        paths = (_paths(entries, "files"), _paths(entries, "links"), _paths(entries, "directories"))
        return cls(*paths, _digests(entries, "copies"))

    def write(self, output: pathlib.Path) -> None:
        """Write the manifest into `output`, keeping the old one if writing fails."""
        data = {
            "files": sorted(self.files),
            "links": sorted(self.links),
            "directories": sorted(self.directories),
            "copies": dict(sorted(self.copies.items())),
        }
        with zypy.artifacts.archive.replace(output / MANIFEST) as file:
            file.write(f"{json.dumps(data, indent=2)}\n".encode())


@contextlib.contextmanager
def staging(output: pathlib.Path) -> collections.abc.Generator[pathlib.Path]:
    """Create a temporary build directory under `output` and remove it afterwards."""
    output.mkdir(exist_ok=True)
    _remove_abandoned(output)

    directory, descriptor = _locked_directory(output)
    try:
        yield directory
    finally:
        os.close(descriptor)
        shutil.rmtree(directory, ignore_errors=True)


def _locked_directory(output: pathlib.Path) -> tuple[pathlib.Path, int]:
    """Create and lock a temporary build directory."""
    while True:
        directory = pathlib.Path(tempfile.mkdtemp(prefix=STAGING_PREFIX, dir=output))
        try:
            descriptor = _open_lock(directory)
        except FileNotFoundError:
            continue

        try:
            if not _lock(descriptor, wait=True) or _is_open(directory, descriptor):
                return directory, descriptor
        except BaseException:
            os.close(descriptor)
            raise

        os.close(descriptor)


@contextlib.contextmanager
def _locked(directory: pathlib.Path) -> collections.abc.Generator[None]:
    """Lock `directory`, waiting while another build holds it."""
    descriptor = _open_lock(directory)
    try:
        _lock(descriptor, wait=True)
        yield
    finally:
        os.close(descriptor)


def _lock_path(directory: pathlib.Path) -> pathlib.Path:
    """Get the directory or file used to lock `directory`."""
    return directory / LOCK_FILE if sys.platform == "win32" else directory


if sys.platform == "win32":

    def _open_lock(directory: pathlib.Path) -> int:
        """Open or create the lock file in `directory`."""
        return os.open(_lock_path(directory), os.O_RDWR | os.O_CREAT | os.O_NOINHERIT)

    def _open_existing_lock(directory: pathlib.Path) -> int:
        """Open an existing lock file in `directory`."""
        return os.open(_lock_path(directory), os.O_RDWR | os.O_NOINHERIT)

    def _lock(descriptor: int, *, wait: bool) -> bool:
        """Lock the file open as `descriptor`. Return false if another build holds it."""
        while True:
            try:
                msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
            except OSError:
                if not wait:
                    return False

                time.sleep(LOCK_INTERVAL)
            else:
                return True

else:

    def _open_lock(directory: pathlib.Path) -> int:
        """Open `directory` to lock it."""
        return os.open(directory, os.O_RDONLY | os.O_DIRECTORY)

    def _open_existing_lock(directory: pathlib.Path) -> int:
        """Open `directory` for locking without following symbolic links."""
        return os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

    def _lock(descriptor: int, *, wait: bool) -> bool:
        """Lock the directory open as `descriptor`. Return false if another build holds it, or if locks fail."""
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX if wait else fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False

        return True


def _is_open(directory: pathlib.Path, descriptor: int) -> bool:
    """Check whether the open lock still belongs to `directory`."""
    try:
        return os.path.samestat(_lock_path(directory).lstat(), os.fstat(descriptor))
    except FileNotFoundError:
        return False


def _remove_abandoned(output: pathlib.Path) -> None:
    """Remove temporary directories left by builds that are no longer running."""
    for directory in output.glob(f"{STAGING_PREFIX}*"):
        if directory.is_symlink() or not directory.is_dir():
            continue

        try:
            descriptor = _open_existing_lock(directory)
        except FileNotFoundError:
            if sys.platform == "win32":
                shutil.rmtree(directory, ignore_errors=True)

            continue
        except OSError:
            continue

        abandoned = _lock(descriptor, wait=False)
        os.close(descriptor)
        if abandoned:
            shutil.rmtree(directory, ignore_errors=True)


def copies(root: pathlib.Path) -> set[pathlib.Path]:
    """Find unchanged copies from the project's last editable build."""
    manifest = Manifest.read(root / "zig-out" / "python")
    return {path for path, digest in _within_digests(root, manifest.copies).items() if _is_build_copy(path, digest)}


def install(build: pathlib.Path, root: pathlib.Path, source: pathlib.Path | None) -> pathlib.Path:
    """Install a completed build into zig-out and return its import directory.

    Link or copy extensions into `source` when provided. Remove stale build files and preserve unrelated files.
    """
    output = root / "zig-out"
    output.mkdir(parents=True, exist_ok=True)
    with _locked(output):
        try:
            return _install(build, root, source)
        except PermissionError as error:
            if sys.platform != "win32":
                raise

            raise zypy.errors.ZypyError(
                f"can't update {error.filename}: on Windows, stop any Python process using the extension and try again"
            ) from error


def _install(build: pathlib.Path, root: pathlib.Path, source: pathlib.Path | None) -> pathlib.Path:
    """Install a completed build, with zig-out locked."""
    output = root / "zig-out" / "python"
    previous = Manifest.read(output)
    built = _files(build / "python")
    moves = {path: root / "zig-out" / name for name, path in _files(build).items() if name != LOCK_FILE}
    links: dict[pathlib.Path, pathlib.Path] = {} if source is None else {source / name: output / name for name in built}
    current = frozenset(_relative(root, link) for link in links)
    stale_files = _within(output, previous.files - built.keys())
    previous_copies = _within_digests(root, previous.copies)

    def is_ours(link: pathlib.Path) -> bool:
        """Check whether an earlier editable build made `link`."""
        digest = previous_copies.get(link)
        return _is_build_link(link, output) or (digest is not None and _is_build_copy(link, digest))

    stale_links = {link for link in _within(root, previous.links - current) if is_ours(link)}

    _check_links(links, is_ours)
    _check_destinations(moves.values(), root / "zig-out", stale_files)
    if source is not None:
        _check_destinations(links, source, stale_links)

    _remove_files(output, stale_files)
    for path, destination in moves.items():
        _replace(path, destination)

    directories, copied = _update_links(root, links, stale_links, previous.directories)
    Manifest(frozenset(built), current, directories, copied).write(output)
    return output if source is None else source


def _files(directory: pathlib.Path) -> dict[str, pathlib.Path]:
    """Map relative POSIX paths to the files and links under `directory`."""
    paths = (path for path in directory.rglob("*") if path.is_symlink() or path.is_file())
    return {path.relative_to(directory).as_posix(): path for path in sorted(paths)}


def _replace(path: pathlib.Path, destination: pathlib.Path) -> None:
    """Move `path` to `destination`, replacing a file there."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    path.replace(destination)


def _check_links(
    links: collections.abc.Mapping[pathlib.Path, pathlib.Path], is_ours: collections.abc.Callable[[pathlib.Path], bool]
) -> None:
    """Reject link destinations occupied by files from outside the editable build."""
    for link, target in links.items():
        if (link.exists() or link.is_symlink()) and not is_ours(link):
            raise zypy.errors.ZypyError(f"{link} has the same path as a file zig build installs ({target})")


def _check_destinations(
    destinations: collections.abc.Iterable[pathlib.Path], base: pathlib.Path, removed: collections.abc.Set[pathlib.Path]
) -> None:
    """Check for path conflicts, ignoring files listed in `removed`."""
    for destination in destinations:
        if destination.is_dir() and not destination.is_symlink():
            raise zypy.errors.ZypyError(f"{destination} is a directory, where zig build installs a file")

        for parent in _parents(destination, base):
            if (parent.is_symlink() or parent.exists()) and not parent.is_dir() and parent not in removed:
                raise zypy.errors.ZypyError(f"{parent} is a file, where zig build needs a directory for {destination}")


def _parents(path: pathlib.Path, base: pathlib.Path) -> list[pathlib.Path]:
    """List parent directories of `path` within `base`, excluding `base` itself."""
    return [base / parent for parent in path.relative_to(base).parents][:-1]


def _remove_files(output: pathlib.Path, paths: collections.abc.Iterable[pathlib.Path]) -> None:
    """Remove stale build files and their empty parent directories within `output`."""
    for path in sorted(paths):
        if not (path.is_symlink() or path.is_file()):
            continue

        path.unlink()
        directory = path.parent
        while directory != output and not any(directory.iterdir()):
            directory.rmdir()
            directory = directory.parent


def _update_links(
    root: pathlib.Path,
    links: collections.abc.Mapping[pathlib.Path, pathlib.Path],
    stale: collections.abc.Iterable[pathlib.Path],
    directories: collections.abc.Iterable[str],
) -> tuple[frozenset[str], dict[str, str]]:
    """Update links or copies and return managed directories and copy hashes."""
    for link in sorted(stale):
        link.unlink()

    created = set(directories)
    copied: dict[str, str] = {}
    for link, target in links.items():
        created.update(_relative(root, parent) for parent in _missing_parents(link, root))
        link.parent.mkdir(parents=True, exist_ok=True)
        link.unlink(missing_ok=True)
        try:
            link.symlink_to(target)
        except OSError:
            shutil.copyfile(target, link)
            copied[_relative(root, link)] = _digest(link)

    needed = {_relative(root, parent) for link in links for parent in link.parents if parent.is_relative_to(root)}
    for name in sorted(created - needed, key=lambda name: name.count("/"), reverse=True):
        directory = _inside(root, name)
        if directory is not None and directory.is_dir() and not directory.is_symlink() and not any(directory.iterdir()):
            directory.rmdir()

    return frozenset(name for name in created & needed if (root / name).is_dir()), copied


def _missing_parents(path: pathlib.Path, root: pathlib.Path) -> list[pathlib.Path]:
    """List missing parent directories of `path` within `root`."""
    return [parent for parent in path.parents if parent.is_relative_to(root) and not parent.exists()]


def _relative(root: pathlib.Path, path: pathlib.Path) -> str:
    """Get the POSIX path of `path` relative to `root`."""
    return path.relative_to(root).as_posix()


def _is_build_link(link: pathlib.Path, output: pathlib.Path) -> bool:
    """Check whether `link` points into the editable build output."""
    return link.is_symlink() and link.resolve().is_relative_to(output.resolve())


def _is_build_copy(path: pathlib.Path, digest: str) -> bool:
    """Check whether `path` is an unchanged editable copy."""
    return not path.is_symlink() and path.is_file() and _digest(path) == digest


def _digest(path: pathlib.Path) -> str:
    """Get the SHA-256 of the file at `path`."""
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def _inside(base: pathlib.Path, name: str) -> pathlib.Path | None:
    """Resolve a manifest path inside `base`, or return `None` if it would escape."""
    relative = pathlib.PurePosixPath(name)
    if relative.is_absolute() or ".." in relative.parts:
        return None

    return base / relative


def _within(base: pathlib.Path, names: collections.abc.Iterable[str]) -> set[pathlib.Path]:
    """Resolve manifest paths inside `base`, ignoring entries that would escape it."""
    return {path for name in names if (path := _inside(base, name)) is not None}


def _within_digests(base: pathlib.Path, digests: collections.abc.Mapping[str, str]) -> dict[pathlib.Path, str]:
    """Resolve copied file paths within `base`, keeping their hashes."""
    return {path: digest for name, digest in digests.items() if (path := _inside(base, name)) is not None}


def _digests(data: collections.abc.Mapping[str, object], key: str) -> dict[str, str]:
    """Read copy paths and hashes from a manifest, ignoring invalid entries."""
    value = data.get(key)
    if not isinstance(value, dict):
        return {}

    items = typing.cast("dict[object, object]", value)
    return {name: digest for name, digest in items.items() if isinstance(name, str) and isinstance(digest, str)}


def _paths(data: collections.abc.Mapping[str, object], key: str) -> frozenset[str]:
    """Read a list of relative paths from a manifest, ignoring anything else."""
    value = data.get(key)
    if not isinstance(value, list):
        return frozenset()

    items = typing.cast("list[object]", value)
    return frozenset(item for item in items if isinstance(item, str))
