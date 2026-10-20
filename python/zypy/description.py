import json
import platform
import struct
import sys
import sysconfig
import typing

POINTER_SIZE_32_BIT: typing.Final = 4
PLATFORMS_32_BIT: typing.Final = {"linux-x86_64": "linux-i686", "linux-aarch64": "linux-armv8l"}


class Description(typing.TypedDict):
    """Details ZyPy needs about a Python interpreter."""

    executable: str
    implementation: str
    version: list[int]
    soabi: str
    platform: str
    libc: str
    gil_disabled: bool


def describe() -> Description:
    """Describe the running interpreter, using only the standard library."""
    return {
        "executable": sys.executable,
        "implementation": sys.implementation.name,
        "version": list(sys.version_info[:2]),
        "soabi": sysconfig.get_config_var("SOABI") or "",
        "platform": _platform(),
        "libc": _libc(),
        "gil_disabled": bool(sysconfig.get_config_var("Py_GIL_DISABLED")),
    }


def _platform() -> str:
    """Get the interpreter platform tag, such as linux-x86_64 or macosx-11.0-arm64."""
    name = sysconfig.get_platform()
    if name.endswith("-universal2"):
        return name[: -len("universal2")] + platform.machine()

    if struct.calcsize("P") == POINTER_SIZE_32_BIT:
        return PLATFORMS_32_BIT.get(name, name)

    return name


def _libc() -> str:
    """Get the C library: glibc or musl on Linux, or an empty string."""
    if platform.libc_ver()[0] == "glibc":
        return "glibc"

    if "-linux-musl" in (sysconfig.get_config_var("SOABI") or ""):
        return "musl"

    return ""


if __name__ == "__main__":
    print(json.dumps(describe()))
