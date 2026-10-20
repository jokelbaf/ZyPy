import collections.abc
import dataclasses
import pathlib
import re
import typing
import unicodedata

import zypy.errors

TOKEN: typing.Final = re.compile(
    r"""
    (?P<space>\s+)
    | (?P<comment>//[^\n]*)
    | (?P<string>"(?:[^"\\\n]|\\.)*")
    | (?P<line>\\\\[^\n]*)
    | (?P<char>'(?:[^'\\\n]|\\.)*')
    | (?P<name>@"(?:[^"\\\n]|\\.)*"|[A-Za-z_][A-Za-z0-9_]*)
    | (?P<number>-?[0-9][0-9A-Za-z_]*(?:\.[0-9][0-9A-Za-z_]*)?(?:[eEpP][+-][0-9A-Za-z_]+)?)
    | (?P<symbol>[.{}=,])
    """,
    re.VERBOSE,
)

ESCAPE: typing.Final = re.compile(r"\\(?:x([0-9a-fA-F]{2})|u\{([0-9a-fA-F]+)\}|(.))")
SIMPLE_ESCAPES: typing.Final = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", "'": "'", '"': '"'}
QUOTE_ESCAPES: typing.Final = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t"}


@dataclasses.dataclass(frozen=True, slots=True)
class String:
    """A string literal and its position in the file."""

    value: str
    start: int
    end: int


@dataclasses.dataclass(frozen=True, slots=True)
class EnumLiteral:
    """An enum literal such as `.zypy`."""

    name: str


@dataclasses.dataclass(frozen=True, slots=True)
class Other:
    """A manifest value that packaging does not inspect."""

    text: str


type Value = String | EnumLiteral | Other | dict[str, Value] | list[Value]


@dataclasses.dataclass(frozen=True, slots=True)
class Manifest:
    """Package information read from build.zig.zon."""

    path: pathlib.Path
    text: str
    name: str | None
    version: str | None
    paths: tuple[str, ...] | None
    path_dependencies: tuple[String, ...]

    @classmethod
    def read(cls, path: pathlib.Path) -> typing.Self:
        """Read and parse the build.zig.zon at `path`."""
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError as error:
            raise zypy.errors.ZypyError(f"{path} isn't UTF-8 text: {error}") from None

        return cls.parse(text, path)

    @classmethod
    def parse(cls, text: str, path: pathlib.Path) -> typing.Self:
        """Parse `text`, the contents of the build.zig.zon at `path`."""
        root = _Parser(text, path).document()
        if not isinstance(root, dict):
            raise zypy.errors.ZypyError(f"{path} must contain a struct, such as .{{ .name = .demo }}")

        return cls(
            path=path,
            text=text,
            name=_name(root.get("name")),
            version=version.value if isinstance(version := root.get("version"), String) else None,
            paths=_strings(root["paths"], path) if "paths" in root else None,
            path_dependencies=_path_dependencies(root.get("dependencies")),
        )

    def rewrite(self, paths: collections.abc.Mapping[String, str]) -> str:
        """Return the manifest text with dependency paths replaced using `paths`."""
        text = self.text
        for string in sorted(paths, key=lambda string: string.start, reverse=True):
            text = text[: string.start] + quote(paths[string]) + text[string.end :]
        return text


def quote(text: str) -> str:
    """Write `text` as a Zig string literal."""
    escaped = "".join(map(_escape, text))
    return f'"{escaped}"'


def _escape(char: str) -> str:
    """Write a character as it appears inside a Zig string literal."""
    if escape := QUOTE_ESCAPES.get(char):
        return escape

    if unicodedata.category(char) == "Cc":
        return f"\\u{{{ord(char):x}}}"

    return char


@dataclasses.dataclass(frozen=True, slots=True)
class _Token:
    """A token of a ZON file."""

    kind: str
    text: str
    start: int
    end: int


class _Parser:
    """Read ZON values from text, skipping comments."""

    def __init__(self, text: str, path: pathlib.Path) -> None:
        """Split `text`, read from `path`, into tokens."""
        self.text = text
        self.path = path
        self.tokens = list(self._scan())
        self.position = 0

    def document(self) -> Value:
        """Parse the file as a single ZON value."""
        value = self._value()
        if self.position < len(self.tokens):
            raise self._error(self.tokens[self.position].start, "expected the end of the file")

        return value

    def _scan(self) -> collections.abc.Iterator[_Token]:
        """Yield the tokens of the text, without spaces and comments."""
        position = 0
        while position < len(self.text):
            match = TOKEN.match(self.text, position)
            if match is None or match.lastgroup is None:
                raise self._error(position, f"unexpected character {self.text[position]!r}")

            if match.lastgroup not in {"space", "comment"}:
                yield _Token(match.lastgroup, match[0], match.start(), match.end())

            position = match.end()

    def _value(self) -> Value:
        """Read the value that starts at the next token."""
        token = self._next()
        match token.kind:
            case "string":
                return String(self._decode(token.text[1:-1], token.start), token.start, token.end)
            case "line":
                lines = [token.text[2:]]
                while self._peek("line"):
                    lines.append(self._next().text[2:])
                return Other("\n".join(lines))
            case "char" | "number" | "name":
                return Other(token.text)
            case "symbol" if token.text == ".":
                if self._peek("symbol", "{"):
                    self._next()
                    return self._initializer()
                return EnumLiteral(self._identifier(self._expect("name")))
            case _:
                raise self._error(token.start, f"unexpected {token.text!r}")

    def _initializer(self) -> dict[str, Value] | list[Value]:
        """Parse struct fields or list items after the opening brace of `.{ ... }`."""
        fields: dict[str, Value] = {}
        items: list[Value] = []
        while not self._peek("symbol", "}"):
            if self._peek("symbol", ".") and self._peek("name", offset=1) and self._peek("symbol", "=", offset=2):
                self._next()
                name = self._identifier(self._next())
                self._next()
                fields[name] = self._value()
            else:
                items.append(self._value())

            if not self._peek("symbol", ","):
                break

            self._next()

        self._expect("symbol", "}")
        return items if items or not fields else fields

    def _peek(self, kind: str, text: str | None = None, *, offset: int = 0) -> bool:
        """Check a token at `offset` for the expected kind and optional text."""
        index = self.position + offset
        if index >= len(self.tokens):
            return False

        token = self.tokens[index]
        return token.kind == kind and (text is None or token.text == text)

    def _next(self) -> _Token:
        """Take the next token."""
        if self.position >= len(self.tokens):
            raise self._error(len(self.text), "unexpected end of the file")

        token = self.tokens[self.position]
        self.position += 1
        return token

    def _expect(self, kind: str, text: str | None = None) -> _Token:
        """Read the next token, requiring the expected kind and optional text."""
        if not self._peek(kind, text):
            raise self._error(self._offset(), f"expected {text or kind}")

        return self._next()

    def _offset(self) -> int:
        """Get where the next token starts, or the end of the text after the last one."""
        if self.position < len(self.tokens):
            return self.tokens[self.position].start

        return len(self.text)

    def _identifier(self, token: _Token) -> str:
        """Decode a name, including quoted names such as `@"..."`."""
        return self._decode(token.text[2:-1], token.start) if token.text.startswith("@") else token.text

    def _decode(self, text: str, position: int) -> str:
        """Decode Zig string escapes into UTF-8 bytes."""
        data = bytearray()
        end = 0
        try:
            for match in ESCAPE.finditer(text):
                data += text[end : match.start()].encode()
                if match[1]:
                    data.append(int(match[1], 16))
                elif match[2]:
                    data += chr(int(match[2], 16)).encode()
                else:
                    data += SIMPLE_ESCAPES.get(match[3], match[0]).encode()
                end = match.end()
            data += text[end:].encode()
            return data.decode()
        except (ValueError, OverflowError) as error:
            raise self._error(position, f"invalid string: {error}") from None

    def _error(self, position: int, message: str) -> zypy.errors.ZypyError:
        """Create a ZypyError with the line and column for `position`."""
        line = self.text.count("\n", 0, position) + 1
        column = position - self.text.rfind("\n", 0, position)
        return zypy.errors.ZypyError(f"{self.path}:{line}:{column}: {message}")


def _name(value: Value | None) -> str | None:
    """Read the package name from an enum literal or a legacy string value."""
    match value:
        case EnumLiteral(name=name) | String(value=name):
            return name
        case _:
            return None


def _path_dependencies(value: Value | None) -> tuple[String, ...]:
    """Get local dependency paths from `.dependencies`."""
    if not isinstance(value, dict):
        return ()

    return tuple(
        path
        for dependency in value.values()
        if isinstance(dependency, dict) and isinstance(path := dependency.get("path"), String)
    )


def _strings(value: Value, path: pathlib.Path) -> tuple[str, ...]:
    """Read `.paths` as a list of strings."""
    if value == {}:
        return ()
    if not isinstance(value, list) or not all(isinstance(item, String) for item in value):
        raise zypy.errors.ZypyError(f'{path}: .paths must list strings, such as .{{ "build.zig", "src" }}')

    return tuple(item.value for item in value if isinstance(item, String))
