import pathlib
import shutil
import typing

import pytest

import helpers
import zypy.zig

CROSS_BUILD: typing.Final = """\
const std = @import("std");
const zypy = @import("zypy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = zypy.addExtension(b, .{
        .name = "cross",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .small,
        .python = zypy.bundledPython(b, target),
    });
}
"""

CPU_TYPES: typing.Final = {
    "aarch64-linux-gnu.2.17": 183,
    "arm-linux-gnueabihf.2.17": 40,
    "powerpc64le-linux-gnu.2.19": 21,
    "riscv64-linux-gnu.2.27": 243,
    "s390x-linux-gnu.2.17": 22,
    "x86_64-linux-musl": 62,
    "aarch64-linux-musl": 183,
    "x86_64-macos.11.0": 0x01000007,
    "aarch64-macos.11.0": 0x0100000C,
}


@pytest.fixture(scope="module")
def extension_project(tmp_path_factory: pytest.TempPathFactory) -> pathlib.Path:
    """Share the example project and its build tools across target platforms."""
    project = helpers.copy_example("hello", tmp_path_factory.mktemp("cross_extension"))
    (project / "build.zig").write_text(CROSS_BUILD)
    return project


@pytest.fixture(scope="module")
def library_project(extension_project: pathlib.Path) -> pathlib.Path:
    """Share the full test extension and its build tools across target platforms."""
    project = extension_project.with_name("library")
    shutil.copytree(extension_project, project, ignore=shutil.ignore_patterns(*helpers.BUILD_OUTPUTS))
    shutil.copytree(helpers.REPO / "tests" / "ext" / "src", project / "src", dirs_exist_ok=True)
    return project


def cross_compile(project: pathlib.Path, target: str, prefix: pathlib.Path) -> int:
    """Cross-compile an extension for `target` and return its CPU type."""
    helpers.run(*zypy.zig.command(), "build", f"-Dtarget={target}", "--prefix", prefix, cwd=project)

    data = next((prefix / "python").glob("*.so")).read_bytes()
    if data.startswith(b"\xcf\xfa\xed\xfe"):
        return int.from_bytes(data[4:8], "little")

    assert data.startswith(b"\x7fELF")
    return int.from_bytes(data[18:20], "little" if data[5] == 1 else "big")


@pytest.mark.parametrize("target", CPU_TYPES)
def test_cross_compiled_extensions(extension_project: pathlib.Path, tmp_path: pathlib.Path, target: str) -> None:
    """Check cross-compilation for each supported platform using its Python headers."""
    assert cross_compile(extension_project, target, tmp_path / "out") == CPU_TYPES[target]


@pytest.mark.parametrize("target", ["arm-linux-gnueabihf.2.17", "aarch64-macos.11.0"])
def test_cross_compiled_library(library_project: pathlib.Path, tmp_path: pathlib.Path, target: str) -> None:
    """Check that the full test extension builds for 32-bit ARM and macOS."""
    assert cross_compile(library_project, target, tmp_path / "out") == CPU_TYPES[target]
