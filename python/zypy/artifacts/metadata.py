import collections.abc
import pathlib
import typing

import pyproject_metadata

import zypy.errors
import zypy.project

WHEEL_FILES: typing.Final = frozenset({"WHEEL", "RECORD"})


def dist_info_files(project: zypy.project.Project) -> dict[str, bytes]:
    """Get the files of the .dist-info directory, except WHEEL and RECORD."""
    metadata = project.metadata
    files = {"METADATA": bytes(metadata.as_rfc822())}

    if entry_points := _entry_points(metadata):
        files["entry_points.txt"] = entry_points.encode()

    for license_file in metadata.license_files or []:
        files[f"licenses/{license_file.as_posix()}"] = (project.root / license_file).read_bytes()

    return files


def prepared_files(project: zypy.project.Project, directory: pathlib.Path) -> dict[str, bytes]:
    """Read .dist-info metadata previously prepared in `directory` (PEP 517)."""
    if directory.name != project.dist_info:
        raise zypy.errors.ZypyError(
            f"the prepared metadata in {directory} isn't for {project.dist_info}: prepare the metadata again"
        )

    return {
        name: path.read_bytes()
        for path in sorted(directory.rglob("*"))
        if path.is_file() and (name := path.relative_to(directory).as_posix()) not in WHEEL_FILES
    }


def _entry_points(metadata: pyproject_metadata.StandardMetadata) -> str:
    """Format the entry points as entry_points.txt."""
    groups = {"console_scripts": metadata.scripts, "gui_scripts": metadata.gui_scripts, **metadata.entrypoints}
    return "".join(_entry_point_group(group, entries) for group, entries in groups.items() if entries)


def _entry_point_group(group: str, entries: collections.abc.Mapping[str, str]) -> str:
    """Format one section of entry_points.txt."""
    lines = "".join(f"{name} = {target}\n" for name, target in entries.items())
    return f"[{group}]\n{lines}\n"
