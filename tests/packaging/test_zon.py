import pathlib
import typing

import pytest

import zypy.errors
import zypy.zon

MANIFEST: typing.Final = r""".{
    .name = .demo, // .name = .ghost,
    .@"version" = "1.0",
    .fingerprint = 0x1234,
    .description =
        \\multiline, with "quotes"
    ,
    .dependencies = .{
        .a = .{ .path = "dir \"a\"" },
        .b = .{ .url = "https://example.com", .hash = "x" },
    },
    .paths = .{ "build.zig.zon", "src" },
}"""


def test_zon_manifests(tmp_path: pathlib.Path) -> None:
    """Check manifest parsing of comments, escapes, quoted names, and error locations."""
    path = tmp_path / "build.zig.zon"
    manifest = zypy.zon.Manifest.parse(MANIFEST, path)
    assert manifest.name == "demo"
    assert manifest.paths == ("build.zig.zon", "src")
    assert [string.value for string in manifest.path_dependencies] == ['dir "a"']
    assert '.path = "../dir \\"a\\""' in manifest.rewrite({manifest.path_dependencies[0]: '../dir "a"'})

    with pytest.raises(zypy.errors.ZypyError, match=r"build\.zig\.zon:2:13: unexpected '}'"):
        zypy.zon.Manifest.parse(".{\n    .name = }", path)


def test_zon_strings(tmp_path: pathlib.Path) -> None:
    """Check UTF-8 escape decoding and round-trip quoting for ZON strings."""
    path = tmp_path / "build.zig.zon"
    escapes = zypy.zon.Manifest.parse(r'.{ .paths = .{ "caf\xc3\xa9.zig", "\u{e9}", "\t" } }', path)
    assert escapes.paths == ("café.zig", "é", "\t")
    assert zypy.zon.Manifest.parse(".{ .paths = .{} }", path).paths == ()

    with pytest.raises(zypy.errors.ZypyError, match=r"build\.zig\.zon:1:16: invalid string"):
        zypy.zon.Manifest.parse(r'.{ .paths = .{ "\xff" } }', path)

    text = 'a "quoted" \\ path\twith\nlines\x01 and é'
    assert zypy.zon.Manifest.parse(f".{{ .paths = .{{ {zypy.zon.quote(text)} }} }}", path).paths == (text,)


def test_zon_files_must_be_utf8(tmp_path: pathlib.Path) -> None:
    """Check the error for a manifest file that isn't UTF-8."""
    path = tmp_path / "build.zig.zon"
    path.write_bytes(b'.{ .name = .x, .paths = .{ "\xff" } }')

    with pytest.raises(zypy.errors.ZypyError, match="isn't UTF-8 text"):
        zypy.zon.Manifest.read(path)
