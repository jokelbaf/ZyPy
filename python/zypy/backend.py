import collections.abc
import pathlib

import zypy.artifacts.metadata
import zypy.artifacts.sdist
import zypy.build
import zypy.interpreter
import zypy.project
import zypy.settings

type ConfigSettings = collections.abc.Mapping[str, object] | None


def build_wheel(
    wheel_directory: str,
    config_settings: ConfigSettings = None,
    metadata_directory: str | None = None,
) -> str:
    """Build a wheel into `wheel_directory` (PEP 517), reusing prepared metadata if provided."""
    project = zypy.project.Project.load(".", config_settings)
    python = zypy.interpreter.Interpreter.current()
    metadata = _metadata(project, metadata_directory)
    return zypy.build.build_wheel(project, pathlib.Path(wheel_directory), python, metadata=metadata).name


def build_editable(
    wheel_directory: str,
    config_settings: ConfigSettings = None,
    metadata_directory: str | None = None,
) -> str:
    """Build an editable wheel (PEP 660), using debug mode unless `optimize` is set."""
    project = zypy.project.Project.load(".", config_settings)
    python = zypy.interpreter.Interpreter.current()
    optimize = project.settings.optimize if "optimize" in (config_settings or {}) else zypy.settings.Optimize.DEBUG
    metadata = _metadata(project, metadata_directory)
    return zypy.build.build_editable(project, pathlib.Path(wheel_directory), python, optimize, metadata=metadata).name


def build_sdist(sdist_directory: str, config_settings: ConfigSettings = None) -> str:
    """Build an sdist into `sdist_directory` (PEP 517)."""
    project = zypy.project.Project.load(".", config_settings)
    return zypy.artifacts.sdist.build_sdist(project, pathlib.Path(sdist_directory)).name


def prepare_metadata_for_build_wheel(metadata_directory: str, config_settings: ConfigSettings = None) -> str:
    """Write .dist-info metadata without building the extension."""
    project = zypy.project.Project.load(".", config_settings)
    dist_info = pathlib.Path(metadata_directory) / project.dist_info

    for name, data in zypy.artifacts.metadata.dist_info_files(project).items():
        path = dist_info / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    return dist_info.name


prepare_metadata_for_build_editable = prepare_metadata_for_build_wheel


def _metadata(project: zypy.project.Project, metadata_directory: str | None) -> dict[str, bytes] | None:
    """Read prepared metadata for the wheel to include unchanged."""
    if metadata_directory is None:
        return None

    return zypy.artifacts.metadata.prepared_files(project, pathlib.Path(metadata_directory))
