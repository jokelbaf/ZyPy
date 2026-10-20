import json
import pathlib

import helpers
import zypy.zig


def test_api_reference(tmp_path: pathlib.Path) -> None:
    """Check API reference generation and required doc comments."""
    pages = tmp_path / "pages"
    links = tmp_path / "links.json"
    helpers.run(*zypy.zig.command(), "run", "docs/apidoc.zig", "--", ".", pages, links, cwd=helpers.REPO)

    assert (pages / "index.md").is_file()
    assert json.loads(links.read_text())["py.List"] == "/api/objects/#pylist"


def test_api_reference_generator() -> None:
    """Check the API reference generator's behavior."""
    helpers.run(*zypy.zig.command(), "test", "docs/apidoc.zig", cwd=helpers.REPO)
