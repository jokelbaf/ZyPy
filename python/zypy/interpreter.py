import dataclasses
import json
import os
import re
import subprocess
import typing

import zypy.description
import zypy.errors

MINIMUM_VERSION: typing.Final = (3, 13)


@dataclasses.dataclass(frozen=True, slots=True)
class Interpreter:
    """A Python interpreter to build wheels for."""

    executable: str
    implementation: str
    version: tuple[int, int]
    soabi: str
    platform: str
    libc: str
    gil_disabled: bool

    @classmethod
    def current(cls) -> typing.Self:
        """Describe the running interpreter."""
        return cls.from_description(zypy.description.describe())

    @classmethod
    def at(cls, executable: str | os.PathLike[str]) -> typing.Self:
        """Describe another interpreter by running it."""
        command = [os.fspath(executable), "-I", zypy.description.__file__]

        try:
            result = subprocess.run(command, capture_output=True, text=True, check=True)
            description = json.loads(result.stdout)
        except (OSError, subprocess.CalledProcessError) as error:
            raise zypy.errors.ZypyError(f"can't run Python at {executable}: {error}") from error
        except json.JSONDecodeError as error:
            raise zypy.errors.ZypyError(f"can't read what Python at {executable} printed: {error}") from error

        return cls.from_description(description)

    @classmethod
    def from_description(cls, description: zypy.description.Description) -> typing.Self:
        """Create an interpreter description from `zypy.description.describe` output."""
        major, minor = description["version"]
        return cls(
            executable=description["executable"],
            implementation=description["implementation"],
            version=(major, minor),
            soabi=description["soabi"],
            platform=description["platform"],
            libc=description["libc"],
            gil_disabled=description["gil_disabled"],
        )

    @property
    def python_tag(self) -> str:
        """The wheel tag for the Python version, such as cp313."""
        major, minor = self.version
        return f"cp{major}{minor}"

    @property
    def abi_tag(self) -> str:
        """The wheel ABI tag, such as cp313, cp313t (free-threaded), or cp313d (debug)."""
        if match := re.match(r"cpython-(\d+[a-z]*)-", self.soabi):
            return f"cp{match[1]}"

        return self.python_tag + ("t" if self.gil_disabled else "")

    def check(self) -> None:
        """Raise ZypyError if ZyPy cannot build for this interpreter."""
        if self.implementation != "cpython":
            raise zypy.errors.ZypyError(f"ZyPy needs CPython, got {self.implementation} ({self.executable})")

        if self.version < MINIMUM_VERSION:
            version = ".".join(map(str, self.version))
            raise zypy.errors.ZypyError(f"ZyPy needs Python 3.13+, got {version} ({self.executable})")
