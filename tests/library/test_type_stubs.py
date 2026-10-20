import ast
import pathlib
import subprocess
import sys
import types
import typing

import pytest

STUB_LINES: typing.Final = (
    '"""ZyPy\'s test module"""',
    "import collections.abc\nimport enum\nimport typing\n\nfrom . import sub as sub\n",
    "ORIGIN: Point\nDEFAULT_LEVEL: Level\n",
    'class Level(enum.Enum):\n    """How much."""\n    low = 1\n    medium = 5\n    high = 10\n',
    "class Direction(enum.Enum):\n    north = 0\n",
    "def raise_level(arg0: Level, /) -> Level: ...\n",
    "def turn(direction: Direction = ...) -> Direction: ...\n",
    "    def __iadd__(self, other: int, /) -> typing.Self: ...\n",
    "    def __imul__(self, other: int, /) -> Number: ...\n",
    "    def __pow__(self, other: int, modulo: int | None = None, /) -> Number: ...\n",
    "    def __divmod__(self, other: int, /) -> tuple[int, int]: ...\n",
    "    def __getattr__(self, name: str, /) -> typing.Any: ...\n",
    "    def __setattr__(self, name: str, value: object, /) -> None: ...\n",
    "    def __get__(self, instance: object | None, owner: object | None = None, /) -> int: ...\n",
    "    def __set__(self, instance: object, value: int, /) -> None: ...\n",
    "    __dict__: dict[str, typing.Any]\n",
    "class StrictError(ParseError):\n",
    "@typing.final\nclass Point:\n",
    "    def __init__(self, x: float, y: float = 0.0) -> None: ...\n",
    "    def __eq__(self, other: object, /) -> bool: ...\n",
    "    @staticmethod\n    def origin() -> Point: ...\n",
    "    def __iter__(self) -> BagIterator: ...\n",
    "def greet(name: str, /, greeting: str = 'Hello', *, loud: bool = False) -> str:\n",
    "def collect(first: int, *rest: typing.Any, flag: bool = False, **options: typing.Any) -> ",
    "def buf_sum(arg0: collections.abc.Buffer, /) -> float: ...\n",
    'def next_color(color: typing.Literal["red", "green", "blue"] = \'blue\') -> ',
    'def quoted_tag(arg0: typing.Literal["plain", "say \\"hi\\""], /) -> typing.Literal["plain", "say \\"hi\\""]:',
    "    def __release_buffer__(self, buffer: memoryview, /) -> None: ...\n",
    "@typing.final\nclass Handle:\n    @property\n    def id(self) -> int: ...\n",
    "    @property\n    def coordinates(self) -> tuple[float, float]: ...\n",
    "class Square(Shape):\n",
    "    def area(self) -> float: ...\n    @typing.override\n    def describe(self) -> str: ...\n",
    "@typing.final\nclass Prism(Square):\n",
    '    @classmethod\n    def triangle(cls, name: str) -> Shape:\n        """Make a shape with three sides."""\n',
    "    @classmethod\n    def from_calls(cls) -> Counter: ...\n",
    "def build_shape(arg0: type[Shape], arg1: str, arg2: int, /) -> Shape: ...\n",
    "class Score(Number):\n    def __init__(self, arg0: int, /) -> None: ...\n",
    "    def __lt__(self, other: Number, /) -> bool: ...\n",
    "class Badge(Tag):\n    level: int\n    def __init__(self, arg0: str, /) -> None: ...\n\n",
    "class PlainMarker(Marker):\n    def __init__(self) -> None: ...\n\n",
    (
        "    def restart(_self, self: int) -> None: ...\n"
        "    @classmethod\n    def starting(_cls, cls: int) -> Countdown: ...\n"
    ),
    (
        "class DoubleCountdown(Countdown):\n    def __init__(self, arg0: int, /) -> None: ...\n"
        "    @typing.override\n    def __next__(self) -> int: ...\n\n"
    ),
)

SHADOWS_STUB: typing.Final = """\
\"\"\"Names that stubs must not confuse with built-in ones.\"\"\"

import builtins as builtins_
import collections.abc as collections_abc
import enum as enum_
import typing as typing_
import zypy_tests as zypy_tests_

int: builtins_.int
builtins: str

class Mode(enum_.Enum):
    on = 0
    off = 1

@typing_.final
class list:
    int: builtins_.int
    @builtins_.property
    def property(self) -> builtins_.float: ...
    def __init__(self, int: builtins_.int) -> None: ...
    def str(self) -> builtins_.str: ...
    def float(self) -> builtins_.float: ...

def typing(arg0: object, /) -> typing_.Any: ...

def enum(arg0: Mode, /) -> Mode: ...

def values() -> builtins_.list[typing_.Any]: ...

def collections(arg0: collections_abc.Iterable[builtins_.int], /) -> builtins_.int: ...

def zypy_tests(arg0: float, /) -> zypy_tests_.Point: ...
"""

TYPED_USAGE: typing.Final = """\
import zypy_tests
import zypy_tests.shadows
import zypy_tests.sub

point = zypy_tests.Point(1.0, 2.0)
length: float = point.norm() + point.length + zypy_tests.add(1, 2)
moved: zypy_tests.Point = point + point * 2.0 + -point
level: zypy_tests.Level = zypy_tests.raise_level(zypy_tests.Level.low)
number = zypy_tests.Number(2)
number += 3
power: zypy_tests.Number = number ** 2
items: list[int] = [item for item in zypy_tests.Bag([1, 2])]
answer: int = zypy_tests.sub.deep.ANSWER + zypy_tests.sub.triple(3)
far: float = zypy_tests.sub.point(1.0).norm()
greeting: str = zypy_tests.greet("Ann", loud=True)
square = zypy_tests.Square("square", 2.0)
shape: zypy_tests.Shape = square
volume: float = square.area() + zypy_tests.Prism(square).volume() + square.sides
triangle: zypy_tests.Shape = zypy_tests.Shape.triangle("triangle")
built: zypy_tests.Shape = zypy_tests.build_shape(zypy_tests.Square, "built", 4)
marked: str = zypy_tests.Marker() + zypy_tests.ReflectedMarker()
counted: list[int] = list(zypy_tests.DoubleCountdown(4)) + list(zypy_tests.Countdown.starting(cls=2))
zypy_tests.Countdown(1).restart(self=2)
hidden = zypy_tests.shadows.list(int=4)
shadowed: int = hidden.int + zypy_tests.shadows.collections([1, 2]) + zypy_tests.shadows.int
halves: float = hidden.property + hidden.float() + zypy_tests.shadows.zypy_tests(1.0).x
named: str = hidden.str() + zypy_tests.shadows.builtins
mode: zypy_tests.shadows.Mode = zypy_tests.shadows.enum(zypy_tests.shadows.Mode.on)
empty: list[object] = zypy_tests.shadows.values()
zypy_tests.add("one", 2)
"""


@pytest.fixture
def stubs(ext: types.ModuleType) -> pathlib.Path:
    """Get the directory of the test extension's type stubs."""
    assert ext.__file__ is not None
    return pathlib.Path(ext.__file__).parent / "zypy_tests"


def test_type_stubs(stubs: pathlib.Path) -> None:
    """Check the generated stubs for the module and its submodules."""
    stub = (stubs / "__init__.pyi").read_text()
    assert [line for line in STUB_LINES if line not in stub] == []

    assert "def point(arg0: float, /) -> zypy_tests.Point: ..." in (stubs / "sub" / "__init__.pyi").read_text()
    assert (stubs / "shadows.pyi").read_text() == SHADOWS_STUB


def test_type_stubs_are_valid_python(stubs: pathlib.Path) -> None:
    """Check that generated stubs are valid Python and preserve escaped docstrings."""
    stub = (stubs / "__init__.pyi").read_text()
    compile(stub, "__init__.pyi", "exec")

    tree = ast.parse(stub)
    quoted = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "quoted_doc")
    assert ast.get_docstring(quoted) == 'Say "hi".\n\nA backslash \\ and a final "'


def test_type_checkers_use_the_stubs(stubs: pathlib.Path, tmp_path: pathlib.Path) -> None:
    """Check that pyrefly uses the generated stubs to type-check extension calls."""
    installed = stubs.parent
    (tmp_path / "use.py").write_text(TYPED_USAGE)
    (tmp_path / "pyproject.toml").write_text(
        f'[tool.pyrefly]\npreset = "strict"\nsearch-path = ["{installed}"]\n'
        f'project-includes = ["use.py", "{installed}"]\n'
    )

    pyrefly = pathlib.Path(sys.executable).parent / "pyrefly"
    result = subprocess.run([pyrefly, "check"], cwd=tmp_path, capture_output=True, text=True, check=False)
    errors = [line for line in result.stdout.splitlines() if line.startswith("ERROR")]
    overrides = [line.split("`")[1] for line in errors if line.endswith("[bad-override]")]

    assert overrides == ["Positions.__getitem__", "Positions.__setitem__", "Labels.__getitem__"], result.stdout
    assert len(errors) == 4, result.stdout
    assert "`Literal['one']` is not assignable to parameter `arg0` with type `int`" in errors[0]
