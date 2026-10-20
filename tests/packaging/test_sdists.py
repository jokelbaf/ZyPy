import pathlib
import tarfile
import typing

import pytest

import helpers
import zypy.artifacts.sdist
import zypy.errors
import zypy.project

DEMO_WITH_DEP: typing.Final = '.{ .name = .demo, .dependencies = .{ .dep = .{ .path = "../dep" } }, .paths = .{""} }'


def sdist_contents(project: zypy.project.Project, directory: pathlib.Path) -> dict[str, bytes]:
    """Build a source distribution and read its files."""
    with tarfile.open(zypy.artifacts.sdist.build_sdist(project, directory)) as sdist:
        return {
            member.name: file.read() for member in sdist.getmembers() if (file := sdist.extractfile(member)) is not None
        }


def test_sdist_vendors_path_dependencies(tmp_path: pathlib.Path) -> None:
    """Check that source distributions include and use external path dependencies."""
    helper = tmp_path / "helper"
    (helper / "src").mkdir(parents=True)
    (helper / "src" / "lib.zig").write_text("")
    (helper / "build.zig.zon").write_text('.{ .name = .helper, .paths = .{ "src", "build.zig.zon" } }')

    dep = tmp_path / "dep"
    (dep / "src").mkdir(parents=True)
    (dep / "src" / "root.zig").write_text("")
    (dep / "unlisted.txt").write_text("not in .paths")
    (dep / "build.zig.zon").write_text(
        '.{ .name = .dep, .dependencies = .{ .helper = .{ .path = "../helper" } }, '
        '.paths = .{ "src", "build.zig.zon" } }'
    )

    root = helpers.write_project(tmp_path / "project")
    (root / "local").mkdir()
    (root / "local" / "build.zig.zon").write_text('.{ .name = .local, .paths = .{""} }')
    (root / "build.zig.zon").write_text(
        "\n".join(
            [
                ".{",
                "    .name = .demo,",
                '    // .path = "../commented-out"',
                '    .url_like = "has .path = \\"../in-a-string\\" inside",',
                "    .dependencies = .{",
                '        .dep = .{ .path = "../dep" },',
                '        .local = .{ .path = "./local" },',
                "    },",
                '    .paths = .{""},',
                "}",
            ]
        )
    )

    files = sdist_contents(zypy.project.Project.load(root), tmp_path)
    zon = files["demo-1.0/build.zig.zon"].decode()
    dep_zon = files["demo-1.0/zig-deps/dep/build.zig.zon"].decode()

    assert {"demo-1.0/zig-deps/dep/src/root.zig", "demo-1.0/zig-deps/helper/src/lib.zig"} <= files.keys()
    assert "demo-1.0/zig-deps/dep/unlisted.txt" not in files
    assert '.dep = .{ .path = "zig-deps/dep" }' in zon
    assert '.local = .{ .path = "local" }' in zon
    assert '// .path = "../commented-out"' in zon
    assert 'has .path = \\"../in-a-string\\" inside' in zon
    assert '.helper = .{ .path = "../helper" }' in dep_zon


def test_sdist_vendors_dependencies_of_local_packages(tmp_path: pathlib.Path) -> None:
    """Check that local packages include their external dependencies with updated manifest paths."""
    helpers.write_package(
        tmp_path / "external", '.{ .name = .external, .paths = .{ "build.zig.zon", "lib.zig" } }', "lib.zig"
    )
    root = helpers.write_project(tmp_path / "project")
    helpers.write_package(
        root / "local",
        '.{ .name = .local, .dependencies = .{ .external = .{ .path = "../../external" } }, .paths = .{""} }',
    )
    helpers.write_package(
        root, '.{ .name = .demo, .dependencies = .{ .local = .{ .path = "local" } }, .paths = .{""} }'
    )

    files = sdist_contents(zypy.project.Project.load(root), tmp_path)
    assert "demo-1.0/zig-deps/external/lib.zig" in files
    assert b'.path = "../zig-deps/external"' in files["demo-1.0/local/build.zig.zon"]


def test_sdist_copies_nested_packages_once(tmp_path: pathlib.Path) -> None:
    """Check that nested dependencies are copied once and their manifest paths are updated."""
    helpers.write_package(tmp_path / "deps" / "other", '.{ .name = .other, .paths = .{""} }', "other.zig")
    parent = helpers.write_package(
        tmp_path / "parent", '.{ .name = .parent, .dependencies = .{ .child = .{ .path = "child" } }, .paths = .{""} }'
    )
    helpers.write_package(
        parent / "child",
        '.{ .name = .child, .dependencies = .{ .other = .{ .path = "../../deps/other" } }, .paths = .{""} }',
        "payload.zig",
    )
    root = helpers.write_project(tmp_path / "project")
    helpers.write_package(
        root, '.{ .name = .demo, .dependencies = .{ .parent = .{ .path = "../parent" } }, .paths = .{""} }'
    )

    files = sdist_contents(zypy.project.Project.load(root), tmp_path)
    assert "demo-1.0/zig-deps/parent/child/payload.zig" in files
    assert "demo-1.0/zig-deps/other/other.zig" in files
    assert not [name for name in files if name.startswith("demo-1.0/zig-deps/child")]
    assert b'.path = "../../other"' in files["demo-1.0/zig-deps/parent/child/build.zig.zon"]
    assert b'.path = "zig-deps/parent"' in files["demo-1.0/build.zig.zon"]


def test_sdist_keeps_prebuilt_files_of_dependencies(tmp_path: pathlib.Path) -> None:
    """Check that source distributions preserve prebuilt libraries in dependency .paths."""
    dep = helpers.write_package(tmp_path / "dep", '.{ .name = .dep, .paths = .{ "build.zig.zon", "native" } }')
    (dep / "native").mkdir()
    (dep / "native" / "librequired.a").write_bytes(b"archive")

    root = helpers.write_project(tmp_path / "project")
    helpers.write_package(root, DEMO_WITH_DEP, "prebuilt.a", "stale.so")

    files = sdist_contents(zypy.project.Project.load(root), tmp_path)
    assert files["demo-1.0/zig-deps/dep/native/librequired.a"] == b"archive"
    assert "demo-1.0/prebuilt.a" in files
    assert "demo-1.0/stale.so" not in files


def test_sdist_copies_beside_project_files(tmp_path: pathlib.Path) -> None:
    """Check that dependency copies do not overwrite project files."""
    dep = helpers.write_package(tmp_path / "dep", '.{ .name = .dep, .paths = .{ "build.zig.zon", "data.txt" } }')
    (dep / "data.txt").write_text("dependency")

    root = helpers.write_project(tmp_path / "project")
    (root / "zig-deps" / "dep").mkdir(parents=True)
    (root / "zig-deps" / "dep" / "data.txt").write_text("project")
    helpers.write_package(root, DEMO_WITH_DEP)

    files = sdist_contents(zypy.project.Project.load(root), tmp_path)
    assert files["demo-1.0/zig-deps/dep/data.txt"] == b"project"
    assert files["demo-1.0/zig-deps/dep_/data.txt"] == b"dependency"
    assert b'.path = "zig-deps/dep_"' in files["demo-1.0/build.zig.zon"]


def test_sdist_copies_beside_a_project_file_named_like_their_directory(tmp_path: pathlib.Path) -> None:
    """Check that dependency copies avoid an existing file named zig-deps."""
    helpers.write_package(tmp_path / "dep", '.{ .name = .dep, .paths = .{"build.zig.zon"} }')
    root = helpers.write_project(tmp_path / "project")
    (root / "zig-deps").write_text("mine")
    helpers.write_package(root, DEMO_WITH_DEP)

    with tarfile.open(zypy.artifacts.sdist.build_sdist(zypy.project.Project.load(root), tmp_path)) as sdist:
        sdist.extractall(tmp_path / "extracted", filter="data")

    extracted = tmp_path / "extracted" / "demo-1.0"
    assert (extracted / "zig-deps").read_text() == "mine"
    assert (extracted / "zig-deps_" / "dep" / "build.zig.zon").is_file()
    assert '.path = "zig-deps_/dep"' in (extracted / "build.zig.zon").read_text()


def test_sdist_refuses_links_to_directories_in_dependencies(tmp_path: pathlib.Path) -> None:
    """Check that dependency file links are followed and directory links are rejected."""
    dep = helpers.write_package(tmp_path / "dep", '.{ .name = .dep, .paths = .{ "build.zig.zon", "src" } }')
    (dep / "src").mkdir()
    (dep / "src" / "root.zig").write_text("// root")
    (dep / "src" / "alias.zig").symlink_to("root.zig")

    root = helpers.write_project(tmp_path / "project")
    helpers.write_package(root, DEMO_WITH_DEP)
    project = zypy.project.Project.load(root)
    assert sdist_contents(project, tmp_path)["demo-1.0/zig-deps/dep/src/alias.zig"] == b"// root"

    (dep / "src" / "loop").symlink_to(".")
    with pytest.raises(zypy.errors.ZypyError, match=r"src/loop is a link to a directory, which sdists can't hold"):
        zypy.artifacts.sdist.build_sdist(project, tmp_path)


def test_sdist_ignores_paths_in_comments(tmp_path: pathlib.Path) -> None:
    """Check that manifest comments do not affect package file selection."""
    manifest = """// .paths = .{ "ghost.zig" }
.{
    .name = .dep,
    .paths = .{
        "build.zig.zon",
        // "secret.zig",
        "real.zig",
    },
}
"""
    helpers.write_package(tmp_path / "dep", manifest, "ghost.zig", "secret.zig", "real.zig")
    root = helpers.write_project(tmp_path / "project")
    helpers.write_package(root, DEMO_WITH_DEP)

    files = sdist_contents(zypy.project.Project.load(root), tmp_path)
    assert sorted(name for name in files if "zig-deps" in name) == [
        "demo-1.0/zig-deps/dep/build.zig.zon",
        "demo-1.0/zig-deps/dep/real.zig",
    ]


def test_sdist_leaves_out_its_output(tmp_path: pathlib.Path) -> None:
    """Check that source distributions exclude output archives and temporary files."""
    root = helpers.write_project(tmp_path / "p")
    (root / "main.zig").write_text("")
    project = zypy.project.Project.load(root)
    expected = ["demo-1.0/PKG-INFO", "demo-1.0/main.zig", "demo-1.0/pyproject.toml"]

    for _ in range(2):
        files = sdist_contents(project, root)

    assert sorted(files) == expected

    (root / "demo-1.0.tar.gz").unlink()
    (root / "artifacts").mkdir()
    for _ in range(2):
        files = sdist_contents(project, root / "artifacts")

    assert sorted(files) == expected
    assert sorted(path.name for path in (root / "artifacts").iterdir()) == ["demo-1.0.tar.gz"]


def test_sdist_excludes(tmp_path: pathlib.Path) -> None:
    """Check that source distributions skip outputs, caches, and excluded paths."""
    root = helpers.write_project(tmp_path / "p", "[tool.zypy]\nexclude = ['notes/*', '*.log']")
    for name in ("src/a.zig", "notes/todo.md", "debug.log", "zig-out/x", ".venv/y", "src/__pycache__/z.pyc", "m.so"):
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        (root / name).write_text("")

    with tarfile.open(zypy.artifacts.sdist.build_sdist(zypy.project.Project.load(root), tmp_path)) as sdist:
        assert sorted(sdist.getnames()) == ["demo-1.0/PKG-INFO", "demo-1.0/pyproject.toml", "demo-1.0/src/a.zig"]
