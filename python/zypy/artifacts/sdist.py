import contextlib
import gzip
import io
import os
import pathlib
import tarfile
import time
import typing

import zypy.artifacts.archive
import zypy.artifacts.files
import zypy.artifacts.metadata
import zypy.artifacts.vendor
import zypy.project


def build_sdist(project: zypy.project.Project, directory: pathlib.Path) -> pathlib.Path:
    """Build a source distribution, including Zig path dependencies outside the project."""
    base = f"{project.name}-{project.version}"
    path = directory / f"{base}.tar.gz"

    files: dict[str, zypy.artifacts.vendor.Source] = dict(
        zypy.artifacts.files.walk(project.root, project.settings.exclude, _outputs(project, path))
    )
    files.update(zypy.artifacts.vendor.vendor(project.root, files.keys()))
    files["PKG-INFO"] = zypy.artifacts.metadata.dist_info_files(project)["METADATA"]

    with zypy.artifacts.archive.replace(path) as file:
        _write_tar(file, path.name, base, files)

    return path


def _outputs(project: zypy.project.Project, path: pathlib.Path) -> set[pathlib.Path]:
    """Get paths to exclude so the source distribution cannot include its own output."""
    output = path.resolve()
    return {output} if output.parent == project.root else {output, output.parent}


def _write_tar(file: typing.BinaryIO, filename: str, base: str, files: dict[str, zypy.artifacts.vendor.Source]) -> None:
    """Write files under `base` in a gzip-compressed tar archive."""
    epoch = zypy.artifacts.archive.source_date_epoch()

    with (
        gzip.GzipFile(filename, mode="wb", mtime=epoch or 0, fileobj=file) as archive,
        tarfile.open(fileobj=archive, mode="w", format=tarfile.PAX_FORMAT) as tar,
    ):
        for name in sorted(files):
            _add(tar, f"{base}/{name}", files[name], epoch)


def _add(tar: tarfile.TarFile, name: str, source: zypy.artifacts.vendor.Source, epoch: int | None) -> None:
    """Add a file on disk, or bytes, to `tar`."""
    info = tarfile.TarInfo(name)

    with contextlib.ExitStack() as stack:
        match source:
            case bytes():
                data: typing.BinaryIO = io.BytesIO(source)
                info.size, info.mode, info.mtime = len(source), 0o644, int(time.time())
            case pathlib.Path():
                data = stack.enter_context(source.open("rb"))
                status = os.fstat(data.fileno())
                info.size, info.mtime = status.st_size, int(status.st_mtime)
                info.mode = 0o755 if os.access(source, os.X_OK) else 0o644
            case _:
                typing.assert_never(source)

        if epoch is not None:
            info.mtime = epoch

        tar.addfile(info, data)
