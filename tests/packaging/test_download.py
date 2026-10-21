import collections.abc
import gzip
import hashlib
import http.server
import io
import os
import pathlib
import socket
import subprocess
import tarfile
import threading

import pytest

import helpers
import zypy.zig


def archive() -> bytes:
    """Create a small python-build-standalone archive for download tests."""
    data = b"print('hello')\n"
    info = tarfile.TarInfo("python/lib/hello.py")
    info.size = len(data)

    buffer = io.BytesIO()
    with (
        gzip.GzipFile(fileobj=buffer, mode="wb", mtime=0) as compressed,
        tarfile.open(fileobj=compressed, mode="w") as tar,
    ):
        tar.addfile(info, io.BytesIO(data))

    return buffer.getvalue()


class Handler(http.server.BaseHTTPRequestHandler):
    """An HTTP handler serving /python.tar.gz and returning 403 for other paths."""

    def do_GET(self) -> None:
        """Send the archive or an error page."""
        found = self.path == "/python.tar.gz"
        body = archive() if found else b"forbidden"

        self.send_response(200 if found else 403)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@pytest.fixture(scope="module")
def downloader(tmp_path_factory: pytest.TempPathFactory) -> pathlib.Path:
    """Build the program that downloads Python for zypy.bundledPython."""
    program = tmp_path_factory.mktemp("downloader") / "download"
    helpers.run(*zypy.zig.command(), "build-exe", helpers.REPO / "build" / "download.zig", f"-femit-bin={program}")
    return program


@pytest.fixture
def server() -> collections.abc.Iterator[str]:
    """Yield the local download server's base URL."""
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as running:
        thread = threading.Thread(target=running.serve_forever)
        thread.start()
        yield f"http://127.0.0.1:{running.server_port}"

        running.shutdown()
        thread.join()


def download(program: pathlib.Path, url: str, sha256: str, directory: pathlib.Path) -> subprocess.CompletedProcess[str]:
    """Run the downloader with a cache in `directory` and proxy settings disabled."""
    environment = {name: value for name, value in os.environ.items() if not name.lower().endswith("_proxy")}
    environment["ZIG_GLOBAL_CACHE_DIR"] = str(directory / "cache")
    command = [program, url, sha256, directory / "output"]
    return subprocess.run(command, env=environment, capture_output=True, text=True, check=False)


def cached_files(directory: pathlib.Path) -> list[str]:
    """List the files in the downloader's cache."""
    return sorted(path.name for path in (directory / "cache").rglob("*") if path.is_file())


def test_downloads(downloader: pathlib.Path, server: str, tmp_path: pathlib.Path) -> None:
    """Check download verification, caching, and unpacking without the top-level directory."""
    sha256 = hashlib.sha256(archive()).hexdigest()
    result = download(downloader, f"{server}/python.tar.gz", sha256, tmp_path)

    assert result.returncode == 0, result.stderr
    assert (tmp_path / "output" / "lib" / "hello.py").read_text() == "print('hello')\n"
    assert cached_files(tmp_path) == [f"{sha256}.tar.gz"]


def test_failed_downloads_leave_no_files(downloader: pathlib.Path, server: str, tmp_path: pathlib.Path) -> None:
    """Check that failed downloads remove their partial archive from the cache."""
    with socket.socket() as unused:
        unused.bind(("127.0.0.1", 0))
        refused = f"http://127.0.0.1:{unused.getsockname()[1]}/python.tar.gz"

    for url, message in ((f"{server}/missing.tar.gz", "HTTP 403"), (refused, "ConnectionRefused")):
        result = download(downloader, url, "0" * 64, tmp_path)

        assert result.returncode == 1
        assert f"can't download {url}: {message}" in result.stderr

    wrong = download(downloader, f"{server}/python.tar.gz", "0" * 64, tmp_path)
    assert wrong.returncode == 1
    assert "doesn't have the SHA-256" in wrong.stderr

    assert cached_files(tmp_path) == []
