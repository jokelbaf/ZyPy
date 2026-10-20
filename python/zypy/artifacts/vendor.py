import collections
import collections.abc
import dataclasses
import pathlib
import posixpath
import typing

import zypy.artifacts.files
import zypy.errors
import zypy.zon

VENDOR_DIRECTORY: typing.Final = "zig-deps"

type Source = pathlib.Path | bytes


@dataclasses.dataclass(frozen=True, slots=True)
class Package:
    """A local Zig dependency, including dependencies of other packages."""

    directory: pathlib.Path
    manifest: zypy.zon.Manifest
    dependencies: tuple[tuple[zypy.zon.String, pathlib.Path], ...]

    @classmethod
    def read(cls, directory: pathlib.Path) -> typing.Self:
        """Read the package in `directory`, resolving its path dependencies."""
        manifest = zypy.zon.Manifest.read(directory / "build.zig.zon")
        dependencies: list[tuple[zypy.zon.String, pathlib.Path]] = []
        for string in manifest.path_dependencies:
            target = (directory / string.value).resolve()
            if not (target / "build.zig.zon").is_file():
                raise zypy.errors.ZypyError(f"path dependency {target} of {manifest.path} has no build.zig.zon")

            dependencies.append((string, target))

        return cls(directory, manifest, tuple(dependencies))

    def files(self) -> list[tuple[str, pathlib.Path]]:
        """List the files selected by `.paths` in build.zig.zon."""
        if self.manifest.paths is None:
            raise zypy.errors.ZypyError(f"{self.manifest.path} has no .paths")

        files: list[tuple[str, pathlib.Path]] = []
        for entry in self.manifest.paths:
            path = self.directory / entry
            if path.is_dir():
                files += [(_join(entry, relative), file) for relative, file in zypy.artifacts.files.walk_package(path)]
            elif path.is_file():
                files.append((entry, path))

        return files


def vendor(root: pathlib.Path, existing: collections.abc.Collection[str]) -> dict[str, Source]:
    """Prepare local dependencies for a source distribution, copying external packages into zig-deps/."""
    if not (root / "build.zig.zon").is_file():
        return {}

    packages = _discover(root)
    outside = {
        directory: package.files() for directory, package in packages.items() if not directory.is_relative_to(root)
    }
    places = _place(root, packages, outside, existing)

    files: dict[str, Source] = {}
    for directory, package_files in outside.items():
        files.update((_join(places[directory], name), path) for name, path in package_files)

    files.update(_manifests(packages, places))
    return files


def _manifests(packages: dict[pathlib.Path, Package], places: dict[pathlib.Path, str]) -> dict[str, Source]:
    """Rewrite dependency paths to match their locations in the source distribution."""
    manifests: dict[str, Source] = {}
    for package in packages.values():
        place = places[package.directory]
        paths = {
            string: posixpath.relpath(places[target] or ".", place or ".") for string, target in package.dependencies
        }
        if paths:
            manifests[_join(place, "build.zig.zon")] = package.manifest.rewrite(paths).encode()

    return manifests


def _discover(root: pathlib.Path) -> dict[pathlib.Path, Package]:
    """Find local packages, including dependencies of dependencies."""
    packages: dict[pathlib.Path, Package] = {}
    queued = {root}
    pending = collections.deque([root])
    while pending:
        directory = pending.popleft()
        package = packages[directory] = Package.read(directory)
        for _, target in package.dependencies:
            if target not in queued:
                queued.add(target)
                pending.append(target)

    return packages


def _place(
    root: pathlib.Path,
    packages: dict[pathlib.Path, Package],
    outside: dict[pathlib.Path, list[tuple[str, pathlib.Path]]],
    existing: collections.abc.Collection[str],
) -> dict[pathlib.Path, str]:
    """Choose package locations in the source distribution without overwriting project files."""
    taken = {*existing, *(str(parent) for name in existing for parent in pathlib.PurePosixPath(name).parents)}
    vendored = VENDOR_DIRECTORY
    while vendored in existing:
        vendored += "_"

    places: dict[pathlib.Path, str] = {}
    copies: dict[pathlib.Path, set[str]] = {}
    for directory in sorted(packages, key=lambda directory: len(directory.parts)):
        if directory == root:
            places[directory] = ""
        elif directory.is_relative_to(root):
            places[directory] = directory.relative_to(root).as_posix()
        elif parent := _containing_copy(directory, copies):
            places[directory] = _join(places[parent], directory.relative_to(parent).as_posix())
        else:
            places[directory] = _new_copy(packages[directory], vendored, taken | set(places.values()))
            copies[directory] = {name for name, _ in outside[directory]}

    return places


def _containing_copy(directory: pathlib.Path, copies: dict[pathlib.Path, set[str]]) -> pathlib.Path | None:
    """Find a copied package whose files include the package in `directory`."""
    for parent, names in copies.items():
        if directory.is_relative_to(parent) and f"{directory.relative_to(parent).as_posix()}/build.zig.zon" in names:
            return parent

    return None


def _new_copy(package: Package, vendored: str, taken: set[str]) -> str:
    """Choose an unused directory for `package` under `vendored`."""
    place = f"{vendored}/{package.manifest.name or package.directory.name}"
    while place in taken:
        place += "_"

    return place


def _join(directory: str, name: str) -> str:
    """Join source distribution paths, using an empty string for the root."""
    return posixpath.join(directory, name) if directory else name
