import collections.abc
import importlib.resources
import keyword
import pathlib
import re
import secrets
import string
import subprocess
import typing
import unicodedata
import zlib

import zypy
import zypy.errors
import zypy.zig
import zypy.zon

ZIG_PACKAGE_URL: typing.Final = "https://github.com/jokelbaf/ZyPy/archive/refs/tags/v{version}.tar.gz"

PROJECT_NAME: typing.Final = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?")

ZIG_KEYWORDS: typing.Final = frozenset(
    [
        "addrspace",
        "align",
        "allowzero",
        "and",
        "anyframe",
        "anytype",
        "asm",
        "async",
        "await",
        "break",
        "callconv",
        "catch",
        "comptime",
        "const",
        "continue",
        "defer",
        "else",
        "enum",
        "errdefer",
        "error",
        "export",
        "extern",
        "fn",
        "for",
        "if",
        "inline",
        "linksection",
        "noalias",
        "noinline",
        "nosuspend",
        "opaque",
        "or",
        "orelse",
        "packed",
        "pub",
        "resume",
        "return",
        "struct",
        "suspend",
        "switch",
        "test",
        "threadlocal",
        "try",
        "union",
        "unreachable",
        "usingnamespace",
        "var",
        "volatile",
        "while",
    ]
)

TOML_ESCAPES: typing.Final = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t", "\b": "\\b", "\f": "\\f"}

TEMPLATES: typing.Final = {
    "pyproject.toml": "pyproject.toml.template",
    "build.zig": "build.zig.template",
    "build.zig.zon": "build.zig.zon.template",
    "src/root.zig": "root.zig.template",
    ".gitignore": "gitignore.template",
}


def new_project(path: pathlib.Path, name: str | None, source: str | None) -> None:
    """Create a ZyPy project in a new or empty directory."""
    directory = path.resolve()
    if directory.exists() and any(directory.iterdir()):
        raise zypy.errors.ZypyError(f"{directory} already exists and isn't empty")

    project_name = name or directory.name
    zypy_source = source or _local_checkout() or _published_url()
    checkout = None if "://" in zypy_source else _checkout_path(zypy_source, directory)
    values = _template_values(project_name, _module_name(project_name), checkout)

    (directory / "src").mkdir(parents=True, exist_ok=True)
    for relative, template in TEMPLATES.items():
        (directory / relative).write_text(_render(template, values), encoding="utf-8")

    if checkout is None:
        _fetch(directory, zypy_source)


def _module_name(name: str) -> str:
    """Validate a project name and convert it to a Python module name."""
    if not PROJECT_NAME.fullmatch(name):
        raise zypy.errors.ZypyError(
            f"{name!r} isn't a valid project name: use ASCII letters, digits, '.', '_' and '-', starting and ending "
            "with a letter or digit (pass --name)"
        )

    module = re.sub(r"[-.]+", "_", name).lower()
    if not module.isidentifier() or keyword.iskeyword(module):
        raise zypy.errors.ZypyError(f"can't make a Python module name out of {name!r}; pass --name")

    return module


def _package_name(module: str) -> str:
    """Create a Zig package name of at most 32 characters, avoiding Zig keywords."""
    package = module[:32]
    return f"{package[:28]}_zig" if package in ZIG_KEYWORDS else package


def _local_checkout() -> str | None:
    """Find the local ZyPy checkout used by this installation, if any."""
    checkout = pathlib.Path(__file__).resolve().parents[2]
    zon = checkout / "build.zig.zon"
    if zon.is_file() and zypy.zon.Manifest.read(zon).name == "zypy":
        return str(checkout)

    return None


def _published_url() -> str:
    """Get the Zig package release URL for the installed ZyPy version."""
    return ZIG_PACKAGE_URL.format(version=zypy.__version__)


def _checkout_path(source: str, project: pathlib.Path) -> str:
    """Check that `source` is a ZyPy checkout and return its path relative to the project."""
    checkout = pathlib.Path(source).resolve()
    if not (checkout / "build.zig.zon").is_file() or not (checkout / "pyproject.toml").is_file():
        raise zypy.errors.ZypyError(f"{checkout} is not a ZyPy checkout")

    return checkout.relative_to(project, walk_up=True).as_posix()


def _template_values(name: str, module: str, checkout: str | None) -> dict[str, str]:
    """Prepare template values, using a local ZyPy checkout or a published package."""
    package = _package_name(module)
    values = {
        "name": name,
        "module": module,
        "package": package,
        "fingerprint": _fingerprint(package),
        "requirement": f"zypy>={zypy.__version__},<{_next_minor()}",
        "dependencies": "",
        "uv_sources": "",
    }

    if checkout is not None:
        values["dependencies"] = f"        .zypy = .{{ .path = {zypy.zon.quote(checkout)} }},\n"
        values["uv_sources"] = f"\n\n[tool.uv.sources]\nzypy = {{ path = {_toml_string(checkout)} }}"

    return values


def _toml_string(text: str) -> str:
    """Write `text` as a TOML basic string."""
    escaped = "".join(map(_toml_escape, text))
    return f'"{escaped}"'


def _toml_escape(char: str) -> str:
    """Write a character as it appears inside a TOML basic string."""
    if escape := TOML_ESCAPES.get(char):
        return escape

    if unicodedata.category(char) == "Cc":
        return f"\\u{ord(char):04x}"

    return char


def _render(template: str, values: collections.abc.Mapping[str, str]) -> str:
    """Fill in a file from the templates directory."""
    text = (importlib.resources.files(zypy) / "templates" / template).read_text(encoding="utf-8")
    return string.Template(text).substitute(values)


def _fingerprint(package: str) -> str:
    """Generate a Zig package fingerprint for `name`."""
    return f"0x{(zlib.crc32(package.encode()) << 32) | (secrets.randbelow(0xFFFF_FFFE - 1) + 1):016x}"


def _next_minor() -> str:
    """Get the next ZyPy minor version as the upper bound for the build requirement."""
    major, minor, *_ = zypy.__version__.split(".")
    return f"{major}.{int(minor) + 1}"


def _fetch(directory: pathlib.Path, url: str) -> None:
    """Add ZyPy's Zig package from `url` to the project's build.zig.zon."""
    if subprocess.run([*zypy.zig.command(), "fetch", "--save=zypy", url], cwd=directory, check=False).returncode != 0:
        raise zypy.errors.ZypyError(f"zig fetch {url} failed")
