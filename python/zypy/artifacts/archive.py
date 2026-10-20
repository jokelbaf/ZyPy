import collections.abc
import contextlib
import os
import pathlib
import secrets
import typing

import zypy.errors

CHUNK_SIZE: typing.Final = 1 << 20
MAXIMUM_EPOCH: typing.Final = (1 << 32) - 1


@contextlib.contextmanager
def replace(path: pathlib.Path) -> collections.abc.Generator[typing.BinaryIO]:
    """Write `path` atomically, preserving the existing file on failure."""
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(4)}.tmp")
    try:
        with temporary.open("xb") as file:
            yield file

        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def source_date_epoch() -> int | None:
    """Get SOURCE_DATE_EPOCH, the timestamp for reproducible builds, if it's set."""
    value = os.environ.get("SOURCE_DATE_EPOCH")
    if not value:
        return None

    try:
        epoch = int(value)
    except ValueError:
        raise zypy.errors.ZypyError(f"SOURCE_DATE_EPOCH must be a number of seconds, got {value!r}") from None

    if not 0 <= epoch <= MAXIMUM_EPOCH:
        raise zypy.errors.ZypyError(f"SOURCE_DATE_EPOCH must be from 0 to {MAXIMUM_EPOCH}, got {value!r}")

    return epoch
