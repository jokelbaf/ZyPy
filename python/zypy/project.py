import collections.abc
import dataclasses
import os
import pathlib
import tomllib
import typing

import packaging.version
import pyproject_metadata

import zypy.errors
import zypy.settings
import zypy.zon


@dataclasses.dataclass(frozen=True, slots=True)
class Project:
    """Metadata and settings for a ZyPy project."""

    root: pathlib.Path
    metadata: pyproject_metadata.StandardMetadata
    settings: zypy.settings.Settings

    @classmethod
    def load(
        cls,
        root: str | os.PathLike[str] = ".",
        config_settings: collections.abc.Mapping[str, object] | None = None,
    ) -> typing.Self:
        """Read the pyproject.toml in `root`. Config settings override `[tool.zypy]`."""
        directory = pathlib.Path(root).resolve()
        pyproject = _read_pyproject(directory)

        try:
            metadata = pyproject_metadata.StandardMetadata.from_pyproject(pyproject, directory)
        except pyproject_metadata.ConfigurationError as error:
            raise zypy.errors.ZypyError(f"{directory / 'pyproject.toml'}: {error}") from error

        settings = zypy.settings.Settings.load(_tool_table(pyproject), directory)
        return cls(directory, _fill_dynamic(metadata, directory), settings.override(config_settings or {}))

    @property
    def name(self) -> str:
        """The name as used in file names, such as my_project."""
        return self.metadata.canonical_name.replace("-", "_")

    @property
    def version(self) -> str:
        """The version, such as 1.0.0."""
        return str(self.metadata.version)

    @property
    def dist_info(self) -> str:
        """The name of the wheel's .dist-info directory."""
        return f"{self.name}-{self.version}.dist-info"


def _read_pyproject(directory: pathlib.Path) -> dict[str, typing.Any]:
    """Parse the pyproject.toml in `directory`."""
    path = directory / "pyproject.toml"
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise zypy.errors.ZypyError(f"no pyproject.toml in {directory}") from None
    except tomllib.TOMLDecodeError as error:
        raise zypy.errors.ZypyError(f"{path} isn't valid TOML: {error}") from error


def _fill_dynamic(
    metadata: pyproject_metadata.StandardMetadata, directory: pathlib.Path
) -> pyproject_metadata.StandardMetadata:
    """Fill a dynamic version from build.zig.zon, rejecting other dynamic fields."""
    if unsupported := set(metadata.dynamic) - {"version"}:
        raise zypy.errors.ZypyError(
            f"ZyPy can only read the version dynamically (from build.zig.zon), not {', '.join(sorted(unsupported))}"
        )

    if "version" not in metadata.dynamic:
        return metadata

    return dataclasses.replace(metadata, version=_zig_version(directory))


def _zig_version(directory: pathlib.Path) -> packaging.version.Version:
    """Read the package version from the build.zig.zon in `directory`."""
    path = directory / "build.zig.zon"
    if not path.is_file():
        raise zypy.errors.ZypyError(
            f'dynamic = ["version"] reads the version from build.zig.zon, but {path} is missing'
        )

    version = zypy.zon.Manifest.read(path).version
    if version is None:
        raise zypy.errors.ZypyError(f'{path} has no .version, which dynamic = ["version"] needs')

    try:
        return packaging.version.Version(version)
    except packaging.version.InvalidVersion:
        raise zypy.errors.ZypyError(f"{path}: .version {version!r} isn't a valid Python version") from None


def _tool_table(pyproject: collections.abc.Mapping[str, typing.Any]) -> dict[str, object]:
    """Get the `[tool.zypy]` table, which may be missing."""
    tools = pyproject.get("tool", {})
    table = tools.get("zypy", {}) if isinstance(tools, dict) else None
    if not isinstance(table, dict):
        raise zypy.errors.ZypyError("[tool.zypy] must be a table")

    return typing.cast("dict[str, object]", table)
