import collections.abc
import dataclasses
import pathlib
import tempfile
import typing

import zypy.artifacts.files
import zypy.artifacts.metadata
import zypy.artifacts.wheel
import zypy.editable
import zypy.errors
import zypy.interpreter
import zypy.project
import zypy.settings
import zypy.target
import zypy.zig


@dataclasses.dataclass(frozen=True, slots=True)
class Abi:
    """Wheel compatibility tags and the optional stable ABI version."""

    python_tag: str
    abi_tag: str
    stable: str | None

    @classmethod
    def of(cls, python: zypy.interpreter.Interpreter, abi3: tuple[int, int] | None) -> typing.Self:
        """Choose interpreter-specific tags, or stable ABI tags starting at `abi3`."""
        if abi3 is None:
            return cls(python.python_tag, python.abi_tag, None)

        version = ".".join(map(str, abi3))
        if python.gil_disabled:
            raise zypy.errors.ZypyError(
                f"free-threaded Python has no stable ABI, so it can't build abi3 wheels ({python.executable})"
            )

        if python.version < abi3:
            found = ".".join(map(str, python.version))
            raise zypy.errors.ZypyError(
                f"abi3 wheels for Python {version}+ need Python {version} or later to build, got {found}"
            )

        return cls(f"cp{abi3[0]}{abi3[1]}", "abi3", version)


def build_wheel(
    project: zypy.project.Project,
    directory: pathlib.Path,
    python: zypy.interpreter.Interpreter,
    *,
    metadata: dict[str, bytes] | None = None,
) -> pathlib.Path:
    """Build a wheel for `python` in `directory`, using `metadata` if provided."""
    python.check()
    abi = Abi.of(python, project.settings.abi3)
    target = zypy.target.Target.of(python, project.settings.manylinux)

    with tempfile.TemporaryDirectory(prefix="zypy-") as prefix:
        installed = zypy.zig.build(
            project.root,
            pathlib.Path(prefix),
            python=python.executable,
            optimize=project.settings.optimize,
            target=target.zig,
            abi3=abi.stable,
        )
        files = _wheel_files(project, installed)
        markers = _type_markers(files)

        path = directory / _wheel_name(project, abi, target)
        with zypy.artifacts.wheel.create(path, project) as wheel:
            for name in sorted([*files, *markers]):
                if name in markers:
                    wheel.write(name, b"")
                else:
                    wheel.write_file(name, files[name])

            wheel.write_metadata(_tags(abi, target), metadata or zypy.artifacts.metadata.dist_info_files(project))

    return path


def build_editable(
    project: zypy.project.Project,
    directory: pathlib.Path,
    python: zypy.interpreter.Interpreter,
    optimize: zypy.settings.Optimize,
    *,
    metadata: dict[str, bytes] | None = None,
) -> pathlib.Path:
    """Build and install an editable wheel, replacing zig-out only after the build succeeds."""
    python.check()
    abi = Abi.of(python, project.settings.abi3)
    target = zypy.target.Target.of(python, None)

    with zypy.editable.staging(project.root / "zig-out") as staging:
        zypy.zig.build(project.root, staging, python=python.executable, optimize=optimize, target=None, abi3=abi.stable)
        path_entry = zypy.editable.install(staging, project.root, project.settings.python_source)

    path = directory / _wheel_name(project, abi, target)
    with zypy.artifacts.wheel.create(path, project) as wheel:
        wheel.write(f"_zypy_{project.name}.pth", f"{path_entry}\n".encode())
        wheel.write_metadata(_tags(abi, target), metadata or zypy.artifacts.metadata.dist_info_files(project))

    return path


def _wheel_files(project: zypy.project.Project, installed: pathlib.Path) -> dict[str, pathlib.Path]:
    """Collect built extensions and Python source files for the wheel."""
    files = dict(_installed_files(installed))
    if (source := project.settings.python_source) is None:
        return files

    for name, path in zypy.artifacts.files.walk(source):
        if name in files:
            raise zypy.errors.ZypyError(f"{source / name} has the same path in the wheel as a file zig build installs")

        files[name] = path

    directories = {str(parent) for name in files for parent in pathlib.PurePosixPath(name).parents}
    if conflicts := directories & files.keys():
        name = min(conflicts)
        raise zypy.errors.ZypyError(f"{files[name]} has the same path in the wheel as a directory of other files")

    return files


def _type_markers(files: collections.abc.Collection[str]) -> set[str]:
    """Get the missing py.typed markers of packages that contain type stubs (PEP 561)."""
    packages = {name.partition("/")[0] for name in files if name.endswith(".pyi") and "/" in name}
    return {marker for package in packages if (marker := f"{package}/py.typed") not in files}


def _installed_files(directory: pathlib.Path) -> list[tuple[str, pathlib.Path]]:
    """List installed files, including compiled outputs."""
    return sorted((path.relative_to(directory).as_posix(), path) for path in directory.rglob("*") if path.is_file())


def _tags(abi: Abi, target: zypy.target.Target) -> list[str]:
    """Get the wheel's tags, one per platform tag."""
    return [f"{abi.python_tag}-{abi.abi_tag}-{platform}" for platform in target.platform_tags]


def _wheel_name(project: zypy.project.Project, abi: Abi, target: zypy.target.Target) -> str:
    """Get the wheel's file name."""
    return f"{project.name}-{project.version}-{abi.python_tag}-{abi.abi_tag}-{target.wheel_platform}.whl"
