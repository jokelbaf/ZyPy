import pathlib
import shutil
import tomllib

import pytest

import helpers
import zypy.artifacts.metadata
import zypy.cli
import zypy.errors
import zypy.new
import zypy.project
import zypy.settings
import zypy.target
import zypy.zon


@pytest.mark.parametrize(
    ("extra", "message"),
    [
        ("[tool.zypy]\noptimize = 'turbo'", "optimize must be one of"),
        ("[tool.zypy]\nmanylinux = '2_5'", "manylinux must be a glibc version"),
        ("[tool.zypy]\nmanylinux = 2", "manylinux must be a str"),
        ("[tool.zypy]\npython-source = 'missing'", "python-source must be a directory"),
        ("[tool.zypy]\nexclude = 'x'", "exclude must be a list"),
        ("[tool.zypy]\nexclude = [1]", "exclude must be a list of glob patterns"),
        ("[tool.zypy]\nmany-linux = '2_17'", "unknown [tool.zypy] settings: many-linux"),
        ("[tool]\nzypy = 1", "[tool.zypy] must be a table"),
        ("[tool.zypy]\nabi3 = '3.12'", "abi3 must be a Python version of at least"),
        ("[tool.zypy]\nabi3 = '4.0'", "abi3 must be a Python version of at least"),
        ("[tool.zypy]\nabi3 = 3.13", "abi3 must be a str"),
    ],
)
def test_bad_settings(tmp_path: pathlib.Path, extra: str, message: str) -> None:
    """Check that invalid settings produce clear errors."""
    with pytest.raises(zypy.errors.ZypyError, match=message.replace("[", r"\[")):
        zypy.project.Project.load(helpers.write_project(tmp_path, extra))


def test_bad_project_files(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check that invalid project files and metadata produce errors without tracebacks."""
    with pytest.raises(zypy.errors.ZypyError, match="isn't valid TOML"):
        zypy.project.Project.load(helpers.write_project(tmp_path / "toml", "[tool.zypy"))

    root = tmp_path / "version"
    root.mkdir()
    (root / "pyproject.toml").write_text('[project]\nname = "demo"\nversion = "x.y"\n')

    with pytest.raises(zypy.errors.ZypyError, match="invalid PEP 440 version"):
        zypy.project.Project.load(root)

    monkeypatch.chdir(root)
    assert zypy.cli.main(["build"]) == 1


def test_settings_and_overrides(tmp_path: pathlib.Path) -> None:
    """Check that config settings override [tool.zypy]."""
    root = helpers.write_project(tmp_path, "[tool.zypy]\noptimize = 'safe'\nmanylinux = '2_28'")
    settings = zypy.project.Project.load(root).settings
    assert settings.optimize == zypy.settings.Optimize.SAFE
    assert settings.manylinux == zypy.target.GlibcVersion(2, 28)

    assert zypy.project.Project.load(root, {"optimize": "small"}).settings.optimize == zypy.settings.Optimize.SMALL
    assert zypy.project.Project.load(root, {"manylinux": "off"}).settings.manylinux is None

    with pytest.raises(zypy.errors.ZypyError, match="unknown config settings: wat"):
        zypy.project.Project.load(root, {"wat": "1"})


def test_dynamic_version(tmp_path: pathlib.Path) -> None:
    """Check dynamic version metadata from build.zig.zon."""
    (tmp_path / "pyproject.toml").write_text('[project]\nname = "demo"\ndynamic = ["version"]\n')
    with pytest.raises(zypy.errors.ZypyError, match=r"build\.zig\.zon, but .* is missing"):
        zypy.project.Project.load(tmp_path)

    helpers.write_package(tmp_path, '.{ .name = .demo, .paths = .{""} }')
    with pytest.raises(zypy.errors.ZypyError, match=r"has no \.version"):
        zypy.project.Project.load(tmp_path)

    helpers.write_package(tmp_path, '.{ .name = .demo, .version = "one", .paths = .{""} }')
    with pytest.raises(zypy.errors.ZypyError, match="'one' isn't a valid Python version"):
        zypy.project.Project.load(tmp_path)

    helpers.write_package(tmp_path, '.{ .name = .demo, .version = "1.2.0-rc.1", .paths = .{""} }')
    project = zypy.project.Project.load(tmp_path)
    assert project.version == "1.2.0rc1"
    assert b"\nVersion: 1.2.0rc1\n" in zypy.artifacts.metadata.dist_info_files(project)["METADATA"]


def test_other_dynamic_fields(tmp_path: pathlib.Path) -> None:
    """Check that fields other than the version can't be dynamic."""
    root = helpers.write_project(tmp_path, project='dynamic = ["description"]')

    with pytest.raises(zypy.errors.ZypyError, match=r"only read the version dynamically .*, not description"):
        zypy.project.Project.load(root)


def test_entry_points_and_licenses(tmp_path: pathlib.Path) -> None:
    """Check that .dist-info contains entry points and license files."""
    root = helpers.write_project(
        tmp_path, project='license = "MIT"\nlicense-files = ["LICENSE"]\n[project.scripts]\ndemo = "demo:main"'
    )
    (root / "LICENSE").write_text("MIT License")

    files = zypy.artifacts.metadata.dist_info_files(zypy.project.Project.load(root))
    assert files["entry_points.txt"] == b"[console_scripts]\ndemo = demo:main\n\n"
    assert files["licenses/LICENSE"] == b"MIT License"
    assert b"License-Expression: MIT" in files["METADATA"]


def test_new_quotes_paths(tmp_path: pathlib.Path) -> None:
    """Check valid TOML and ZON output for checkout paths with quotes and backslashes."""
    checkout = tmp_path / 'zypy "checkout" \\ copy'
    checkout.mkdir()
    for name in ("build.zig.zon", "pyproject.toml"):
        shutil.copy(helpers.REPO / name, checkout / name)

    zypy.new.new_project(tmp_path / "demo", None, str(checkout))
    relative = '../zypy "checkout" \\ copy'

    pyproject = tomllib.loads((tmp_path / "demo" / "pyproject.toml").read_text())
    assert pyproject["tool"]["uv"]["sources"]["zypy"]["path"] == relative

    manifest = zypy.zon.Manifest.read(tmp_path / "demo" / "build.zig.zon")
    assert [string.value for string in manifest.path_dependencies] == [relative]


def test_new_uses_the_release(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Check that new projects use the matching ZyPy release when no local checkout is available."""
    fetched: list[str] = []

    def fetch(_directory: pathlib.Path, url: str) -> None:
        """Record the URL instead of downloading it."""
        fetched.append(url)

    monkeypatch.setattr(zypy.new, "_local_checkout", lambda: None)
    monkeypatch.setattr(zypy.new, "_fetch", fetch)

    zypy.new.new_project(tmp_path / "demo", None, None)
    assert fetched == [f"https://github.com/jokelbaf/ZyPy/archive/refs/tags/v{zypy.__version__}.tar.gz"]

    pyproject = tomllib.loads((tmp_path / "demo" / "pyproject.toml").read_text())
    assert "sources" not in pyproject["tool"]["uv"]
    assert pyproject["dependency-groups"]["dev"] == pyproject["build-system"]["requires"]


def test_new_checks_names(tmp_path: pathlib.Path) -> None:
    """Check that `zypy new` validates Python module names and generates valid Zig package names."""
    zypy.new.new_project(tmp_path / "comptime", None, str(helpers.REPO))
    assert zypy.zon.Manifest.read(tmp_path / "comptime" / "build.zig.zon").name == "comptime_zig"

    for name in ("async", "éclair", "1st", "-dash", "a b"):
        with pytest.raises(zypy.errors.ZypyError, match="pass --name"):
            zypy.new.new_project(tmp_path / "other", name, str(helpers.REPO))

    assert not (tmp_path / "other").exists()
