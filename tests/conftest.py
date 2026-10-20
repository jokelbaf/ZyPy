import collections.abc
import importlib
import os
import pathlib
import sys
import types

import pytest

import helpers
import zypy.settings
import zypy.zig


def pytest_addoption(parser: pytest.Parser) -> None:
    """Add options for testing alternative library builds."""
    parser.addoption("--abi3", help="build tests/ext for the stable ABI of this Python version, such as 3.13")
    parser.addoption("--prebuilt-ext", type=pathlib.Path, help="test this build of tests/ext instead of building it")


@pytest.fixture(scope="session", autouse=True)
def shared_zig_directories() -> collections.abc.Iterator[None]:
    """Share Zig dependency and build caches with copied test projects."""
    variables = {"ZIG_LOCAL_PKG_DIR": "zig-pkg", "ZIG_LOCAL_CACHE_DIR": ".zig-cache"}
    previous = {name: os.environ.get(name) for name in variables}

    for name, directory in variables.items():
        os.environ[name] = previous[name] or str(helpers.REPO / directory)

    yield

    for name, value in previous.items():
        if value is None:
            del os.environ[name]


@pytest.fixture(scope="session")
def ext(request: pytest.FixtureRequest, tmp_path_factory: pytest.TempPathFactory) -> types.ModuleType:
    """Build and import tests/ext in debug mode with Zig safety checks enabled."""
    installed = request.config.getoption("prebuilt_ext") or zypy.zig.build(
        helpers.REPO / "tests" / "ext",
        tmp_path_factory.mktemp("ext"),
        python=sys.executable,
        optimize=zypy.settings.Optimize.DEBUG,
        target=None,
        abi3=request.config.getoption("abi3"),
    )

    sys.path.insert(0, str(installed))
    return importlib.import_module("zypy_tests")
