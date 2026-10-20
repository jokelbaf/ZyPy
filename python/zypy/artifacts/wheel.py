import base64
import collections.abc
import contextlib
import csv
import hashlib
import io
import os
import pathlib
import time
import typing
import zipfile

import zypy
import zypy.artifacts.archive
import zypy.project

type ZipDate = tuple[int, int, int, int, int, int]

ZIP_EPOCH: typing.Final[ZipDate] = (1980, 1, 1, 0, 0, 0)


class WheelWriter:
    """A wheel writer that records file hashes and sizes."""

    def __init__(self, archive: zipfile.ZipFile, project: zypy.project.Project, date: ZipDate) -> None:
        """Write into `archive`, giving every file the date `date`."""
        self.project = project
        self._zip = archive
        self._date = date
        self._records: list[tuple[str, str, str]] = []

    def write(self, name: str, data: bytes, *, executable: bool = False) -> None:
        """Add a file, and record its hash and size."""
        self._zip.writestr(self._info(name, executable=executable), data)
        self._record(name, hashlib.sha256(data).digest(), len(data))

    def write_file(self, name: str, path: pathlib.Path) -> None:
        """Copy a file into the wheel, preserving executable permission."""
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as source:
            info = self._info(name, executable=os.access(path, os.X_OK))
            info.file_size = os.fstat(source.fileno()).st_size
            with self._zip.open(info, "w") as target:
                while chunk := source.read(zypy.artifacts.archive.CHUNK_SIZE):
                    target.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)

        self._record(name, digest.digest(), size)

    def write_metadata(self, tags: collections.abc.Iterable[str], files: collections.abc.Mapping[str, bytes]) -> None:
        """Add .dist-info metadata and WHEEL."""
        for name, data in files.items():
            self.write(f"{self.project.dist_info}/{name}", data)

        lines = ["Wheel-Version: 1.0", f"Generator: ZyPy {zypy.__version__}", "Root-Is-Purelib: false"]
        lines += [f"Tag: {tag}" for tag in tags]
        self.write(f"{self.project.dist_info}/WHEEL", "\n".join(lines).encode() + b"\n")

    def write_record(self) -> None:
        """Write RECORD with file hashes and sizes."""
        record = f"{self.project.dist_info}/RECORD"
        out = io.StringIO()

        writer = csv.writer(out, lineterminator="\n")
        writer.writerows(self._records)
        writer.writerow((record, "", ""))

        self._zip.writestr(self._info(record, executable=False), out.getvalue().encode())

    def _info(self, name: str, *, executable: bool) -> zipfile.ZipInfo:
        """Describe a file in the zip, with a fixed date for reproducible wheels."""
        info = zipfile.ZipInfo(name, self._date)
        info.external_attr = (0o100755 if executable else 0o100644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        return info

    def _record(self, name: str, digest: bytes, size: int) -> None:
        """Remember a file's SHA-256 digest and size for RECORD."""
        encoded = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
        self._records.append((name, f"sha256={encoded}", str(size)))


@contextlib.contextmanager
def create(path: pathlib.Path, project: zypy.project.Project) -> collections.abc.Generator[WheelWriter]:
    """Write a complete wheel to `path`, preserving any existing file if writing fails."""
    date = _zip_date()
    with (
        zypy.artifacts.archive.replace(path) as file,
        zipfile.ZipFile(file, "w", compression=zipfile.ZIP_DEFLATED) as archive,
    ):
        wheel = WheelWriter(archive, project, date)
        yield wheel
        wheel.write_record()


def _zip_date() -> ZipDate:
    """Get SOURCE_DATE_EPOCH or the earliest date supported by ZIP."""
    epoch = zypy.artifacts.archive.source_date_epoch()
    if epoch is None:
        return ZIP_EPOCH

    date = time.gmtime(epoch)
    return max((date.tm_year, date.tm_mon, date.tm_mday, date.tm_hour, date.tm_min, date.tm_sec), ZIP_EPOCH)
