import dataclasses
import os
import re
import typing

import zypy.errors
import zypy.interpreter


class GlibcVersion(typing.NamedTuple):
    """A glibc version, such as the 2.17 in the manylinux_2_17 tag."""

    major: int
    minor: int

    @classmethod
    def parse(cls, value: str) -> typing.Self:
        """Parse a manylinux version like "2_17", raising ZypyError if it's malformed or too old."""
        match = re.fullmatch(r"(\d+)_(\d+)", value)
        if not match or (int(match[1]), int(match[2])) < MINIMUM_GLIBC:
            message = f'manylinux must be a glibc version of at least "{MINIMUM_GLIBC}" (e.g. "2_28"), or "off"'
            raise zypy.errors.ZypyError(f"{message}; got {value!r}")

        return cls(int(match[1]), int(match[2]))

    def __str__(self) -> str:
        """Format the version as a manylinux tag component, such as 2_17."""
        return f"{self.major}_{self.minor}"


MINIMUM_GLIBC: typing.Final = GlibcVersion(2, 17)

MUSLLINUX: typing.Final = "musllinux_1_2"

MINIMUM_MACOS: typing.Final = (11, 0)


class Architecture(typing.NamedTuple):
    """A Linux CPU architecture and its Zig target settings."""

    zig: str
    oldest_glibc: GlibcVersion = MINIMUM_GLIBC
    manylinux2014: bool = True
    float_abi: str = ""


ARCHITECTURES: typing.Final = {
    "x86_64": Architecture("x86_64"),
    "aarch64": Architecture("aarch64"),
    "i686": Architecture("x86"),
    "armv7l": Architecture("arm", float_abi="eabihf"),
    "armv8l": Architecture("arm", float_abi="eabihf", manylinux2014=False),
    "ppc64le": Architecture("powerpc64le", GlibcVersion(2, 19), manylinux2014=False),
    "s390x": Architecture("s390x"),
    "riscv64": Architecture("riscv64", GlibcVersion(2, 27), manylinux2014=False),
}

MACOS_ARCHITECTURES: typing.Final = {"arm64": "aarch64", "x86_64": "x86_64"}


@dataclasses.dataclass(frozen=True, slots=True)
class Target:
    """A Zig build target and the platform tags for its wheel."""

    zig: str | None
    platform_tags: tuple[str, ...]

    @classmethod
    def of(cls, python: zypy.interpreter.Interpreter, glibc: GlibcVersion | None) -> typing.Self:
        """Choose a build target and wheel tags for the interpreter platform.

        On Linux with glibc, use `glibc` as the minimum version, or the build machine's version if None.
        """
        system, _, rest = python.platform.partition("-")
        match system:
            case "linux":
                return cls._linux(python, rest, glibc)
            case "macosx":
                return cls._macos(rest)
            case _:
                raise zypy.errors.ZypyError(f"ZyPy builds wheels only on Linux and macOS, not {python.platform}")

    @classmethod
    def _linux(cls, python: zypy.interpreter.Interpreter, name: str, glibc: GlibcVersion | None) -> typing.Self:
        """Target Linux with glibc or musl on the architecture `name`, such as x86_64."""
        architecture = ARCHITECTURES.get(name)
        if architecture is None:
            raise zypy.errors.ZypyError(f"ZyPy does not support {name} yet (supported: {', '.join(ARCHITECTURES)})")

        match python.libc:
            case "musl":
                return cls(f"{architecture.zig}-linux-musl{architecture.float_abi}", (f"{MUSLLINUX}_{name}",))
            case "glibc":
                pass
            case _:
                raise zypy.errors.ZypyError(f"ZyPy needs Linux with glibc or musl ({python.executable})")

        if glibc is None:
            return cls(None, (f"linux_{name}",))

        glibc = max(glibc, architecture.oldest_glibc)
        tags = [f"manylinux_{glibc}_{name}"]
        if glibc == MINIMUM_GLIBC and architecture.manylinux2014:
            tags.append(f"manylinux2014_{name}")

        zig = f"{architecture.zig}-linux-gnu{architecture.float_abi}.{glibc.major}.{glibc.minor}"
        return cls(zig, tuple(tags))

    @classmethod
    def _macos(cls, rest: str) -> typing.Self:
        """Choose a macOS target, respecting MACOSX_DEPLOYMENT_TARGET and Zig's minimum supported version."""
        version, _, name = rest.partition("-")
        if (zig_architecture := MACOS_ARCHITECTURES.get(name)) is None:
            raise zypy.errors.ZypyError(f"ZyPy does not support macOS on {name}")

        major, _ = max(_macos_version(os.environ.get("MACOSX_DEPLOYMENT_TARGET") or version), MINIMUM_MACOS)
        return cls(f"{zig_architecture}-macos.{major}.0", (f"macosx_{major}_0_{name}",))

    @property
    def wheel_platform(self) -> str:
        """Platform tags joined with dots for the wheel file name."""
        return ".".join(self.platform_tags)


def _macos_version(text: str) -> tuple[int, int]:
    """Parse a macOS version such as 11.0 or 14."""
    match = re.fullmatch(r"(\d+)(?:\.(\d+))?", text)
    if match is None:
        raise zypy.errors.ZypyError(f"{text!r} isn't a macOS version such as 11.0")

    return int(match[1]), int(match[2] or 0)
