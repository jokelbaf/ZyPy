import os
import pathlib
import platform
import shutil
import sys
import sysconfig

import pytest

import helpers
import zypy.description
import zypy.errors
import zypy.interpreter
import zypy.target
import zypy.zig


@pytest.mark.parametrize(
    ("python", "zig", "tags"),
    [
        (helpers.fake_interpreter(), "x86_64-linux-gnu.2.17", ("manylinux_2_17_x86_64", "manylinux2014_x86_64")),
        (helpers.fake_interpreter("linux-i686"), "x86-linux-gnu.2.17", ("manylinux_2_17_i686", "manylinux2014_i686")),
        (
            helpers.fake_interpreter("linux-armv7l"),
            "arm-linux-gnueabihf.2.17",
            ("manylinux_2_17_armv7l", "manylinux2014_armv7l"),
        ),
        (
            helpers.fake_interpreter("linux-s390x"),
            "s390x-linux-gnu.2.17",
            ("manylinux_2_17_s390x", "manylinux2014_s390x"),
        ),
        (helpers.fake_interpreter("linux-ppc64le"), "powerpc64le-linux-gnu.2.19", ("manylinux_2_19_ppc64le",)),
        (helpers.fake_interpreter("linux-riscv64"), "riscv64-linux-gnu.2.27", ("manylinux_2_27_riscv64",)),
        (helpers.fake_interpreter(libc="musl"), "x86_64-linux-musl", ("musllinux_1_2_x86_64",)),
        (helpers.fake_interpreter("linux-armv7l", libc="musl"), "arm-linux-musleabihf", ("musllinux_1_2_armv7l",)),
        (helpers.fake_interpreter("macosx-14.0-arm64", libc=""), "aarch64-macos.14.0", ("macosx_14_0_arm64",)),
        (helpers.fake_interpreter("macosx-10.13-x86_64", libc=""), "x86_64-macos.11.0", ("macosx_11_0_x86_64",)),
    ],
)
def test_targets(python: zypy.interpreter.Interpreter, zig: str, tags: tuple[str, ...]) -> None:
    """Check Zig targets and compatibility baselines for manylinux, musl, and macOS."""
    assert zypy.target.Target.of(python, zypy.target.GlibcVersion(2, 17)) == zypy.target.Target(zig, tags)


def test_newer_glibc_and_native_targets() -> None:
    """Check explicit glibc compatibility versions and native Linux targets."""
    newer = zypy.target.Target.of(helpers.fake_interpreter("linux-aarch64"), zypy.target.GlibcVersion(2, 28))
    assert newer == zypy.target.Target("aarch64-linux-gnu.2.28", ("manylinux_2_28_aarch64",))

    native = zypy.target.Target.of(helpers.fake_interpreter(), None)
    assert native == zypy.target.Target(None, ("linux_x86_64",))


def test_macos_deployment_targets(monkeypatch: pytest.MonkeyPatch) -> None:
    """Check that macOS deployment targets cannot be older than the interpreter requires."""
    python = helpers.fake_interpreter("macosx-11.0-arm64", libc="")

    monkeypatch.setenv("MACOSX_DEPLOYMENT_TARGET", "12")
    assert zypy.target.Target.of(python, None).platform_tags == ("macosx_12_0_arm64",)

    monkeypatch.setenv("MACOSX_DEPLOYMENT_TARGET", "14.2")
    assert zypy.target.Target.of(python, None) == zypy.target.Target("aarch64-macos.14.0", ("macosx_14_0_arm64",))


@pytest.mark.parametrize(
    ("python", "message"),
    [
        (helpers.fake_interpreter("win-amd64"), "only on Linux and macOS"),
        (helpers.fake_interpreter("linux-sparc64"), "does not support sparc64"),
        (helpers.fake_interpreter(libc=""), "needs Linux with glibc or musl"),
        (helpers.fake_interpreter("macosx-14.0-ppc", libc=""), "does not support macOS on ppc"),
        (helpers.fake_interpreter("macosx-12-arm64", libc=""), "isn't a macOS version"),
    ],
)
def test_unsupported_targets(
    monkeypatch: pytest.MonkeyPatch, python: zypy.interpreter.Interpreter, message: str
) -> None:
    """Check errors for platforms that ZyPy can't build for."""
    monkeypatch.setenv("MACOSX_DEPLOYMENT_TARGET", "twelve")

    with pytest.raises(zypy.errors.ZypyError, match=message):
        zypy.target.Target.of(python, zypy.target.GlibcVersion(2, 17))


def test_describe_platforms(monkeypatch: pytest.MonkeyPatch) -> None:
    """Check architecture detection for universal2 builds and musl detection."""
    monkeypatch.setattr(sysconfig, "get_platform", lambda: "macosx-10.13-universal2")
    monkeypatch.setattr(platform, "machine", lambda: "arm64")
    assert zypy.description.describe()["platform"] == "macosx-10.13-arm64"

    monkeypatch.setattr(platform, "libc_ver", lambda: ("", ""))
    monkeypatch.setattr(sysconfig, "get_config_var", {"SOABI": "cpython-313-x86_64-linux-musl"}.get)
    assert zypy.description.describe()["libc"] == "musl"


def test_glibc_versions() -> None:
    """Check manylinux version parsing and the minimum supported glibc version."""
    assert zypy.target.GlibcVersion.parse("2_28") == (2, 28)
    assert str(zypy.target.GlibcVersion(2, 17)) == "2_17"

    for bad in ("2_5", "2.17", "x"):
        with pytest.raises(zypy.errors.ZypyError, match="manylinux must be a glibc version"):
            zypy.target.GlibcVersion.parse(bad)


def test_unsupported_interpreters() -> None:
    """Check CPython 3.13+ support, including free-threaded builds."""
    for python, message in [
        (helpers.fake_interpreter(implementation="pypy"), "needs CPython"),
        (helpers.fake_interpreter(version=(3, 12)), "needs Python 3.13"),
    ]:
        with pytest.raises(zypy.errors.ZypyError, match=message):
            python.check()

    assert helpers.fake_interpreter(soabi="cpython-313d-x86_64-linux-gnu").abi_tag == "cp313d"

    free_threaded = helpers.fake_interpreter(soabi="cpython-314t-x86_64-linux-gnu", version=(3, 14), gil_disabled=True)
    free_threaded.check()
    assert free_threaded.abi_tag == "cp314t"


def test_describe_other_interpreters() -> None:
    """Check that an interpreter reports the same details when queried from another process."""
    assert zypy.interpreter.Interpreter.at(sys.executable) == zypy.interpreter.Interpreter.current()

    with pytest.raises(zypy.errors.ZypyError, match="can't run Python"):
        zypy.interpreter.Interpreter.at("/nonexistent/python")


def test_zig_not_found(monkeypatch: pytest.MonkeyPatch) -> None:
    """Check error messages when Zig cannot run."""
    zypy.zig.command.cache_clear()
    monkeypatch.setenv("ZYPY_ZIG", str(shutil.which("false")))
    try:
        with pytest.raises(zypy.errors.ZypyError, match="can't run Zig"):
            zypy.zig.command()
    finally:
        zypy.zig.command.cache_clear()


@pytest.mark.skipif(not os.environ.get("ZYPY_DOCKER_TESTS"), reason="set ZYPY_DOCKER_TESTS=1 to run tests in Docker")
def test_musllinux_wheel(tmp_path: pathlib.Path) -> None:
    """Check musllinux tags and linking against Alpine Linux's system musl."""
    project = helpers.copy_example("hello", tmp_path, standalone=True)
    script = (
        "python -m venv /tmp/venv && /tmp/venv/bin/pip install -q /work && cd /work/examples/hello && "
        "/tmp/venv/bin/python -m zypy build -o /tmp/dist && /tmp/venv/bin/pip install -q /tmp/dist/*.whl && "
        "ls /tmp/dist && /tmp/venv/bin/python -c 'import hello; print(hello.add(2, 3))'"
    )
    docker = ["docker", "run", "--rm", "--user", f"{os.getuid()}:{os.getgid()}", "-e", "HOME=/tmp"]

    out = helpers.run(*docker, "-v", f"{project.parent.parent}:/work", "python:3.13-alpine", "sh", "-c", script)
    assert out.splitlines() == [f"hello-0.1.0-cp313-cp313-musllinux_1_2_{helpers.ARCHITECTURE}.whl", "5"]
