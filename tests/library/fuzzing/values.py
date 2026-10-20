import ast
import builtins
import dataclasses
import enum
import types
import typing

import hypothesis.strategies

import helpers
import library.fuzzing.buffers
import library.fuzzing.calls
import library.fuzzing.hostile
import library.fuzzing.instances
import library.fuzzing.stubs

type Strategy[T] = hypothesis.strategies.SearchStrategy[T]

EDGES: typing.Final = tuple(
    sign * (2**bits + offset)
    for sign in (1, -1)
    for bits in (7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 1000)
    for offset in (-1, 0, 1)
)

NAMES: typing.Final = ("red", "low", "north", "first", "last", "x", "count", "__dict__")

KEYS: typing.Final = ("name", "age", "value", "data", "owner", "weight", "admin")


@dataclasses.dataclass(frozen=True, slots=True, kw_only=True)
class Values:
    """Strategies for typed, arbitrary, and deliberately invalid test arguments."""

    ext: types.ModuleType
    small: bool = False

    def arguments(self, signature: library.fuzzing.stubs.Signature | None) -> Strategy[library.fuzzing.calls.Arguments]:
        """Generate typed arguments, typed arguments with one invalid value, or arbitrary arguments."""
        anything = hypothesis.strategies.lists(self.anything(), max_size=4)
        if signature is None:
            return anything.map(lambda positional: library.fuzzing.calls.Arguments(positional, {}))

        typed = hypothesis.strategies.tuples(*map(self.of_type, signature.positional)).map(list)
        spoiled = hypothesis.strategies.builds(spoil, typed, self.anything(), hypothesis.strategies.integers(0, 3))
        keywords = hypothesis.strategies.fixed_dictionaries(
            {}, optional={name: self.of_type(annotation) for name, annotation in signature.keywords.items()}
        )

        positional = hypothesis.strategies.one_of(typed, spoiled, anything)
        return hypothesis.strategies.builds(library.fuzzing.calls.Arguments, positional, keywords)

    def anything(self) -> Strategy[object]:
        """Make scalars and containers of them, including containers that empty themselves during conversion."""
        return hypothesis.strategies.recursive(self.scalars(), containers, max_leaves=8)

    def scalars(self) -> Strategy[object]:
        """Generate scalars, boundary values, subclasses, and objects whose methods fail."""
        return hypothesis.strategies.one_of(
            hypothesis.strategies.none(),
            hypothesis.strategies.booleans(),
            self.integers(),
            self.integers().map(library.fuzzing.hostile.Integer),
            hypothesis.strategies.floats(),
            hypothesis.strategies.floats().map(library.fuzzing.hostile.Float),
            strings(),
            hypothesis.strategies.text(max_size=8).map(library.fuzzing.hostile.Text),
            hypothesis.strategies.sampled_from(NAMES),
            hypothesis.strategies.binary(max_size=16),
            hypothesis.strategies.binary(max_size=8).map(library.fuzzing.hostile.Data),
            library.fuzzing.buffers.buffers(),
            hypothesis.strategies.sampled_from(self.members_and_callables()),
            library.fuzzing.buffers.fresh(
                library.fuzzing.hostile.Hostile,
                library.fuzzing.hostile.HugeLength,
                object,
                helpers.failing_numbers,
                lambda: object.__new__(self.ext.Wide),
                lambda: iter(range(3)),
            ),
        )

    def members_and_callables(self) -> list[object]:
        """List enum members and callbacks for use as test arguments."""
        return [
            library.fuzzing.hostile.Color.red,
            library.fuzzing.hostile.Color.low,
            self.ext.Level.low,
            self.ext.Direction.north,
            self.ext.Wide.m255,
            int,
            list,
            print,
            len,
        ]

    def integers(self) -> Strategy[int]:
        """Generate integers near Zig type limits, or small integers when requested."""
        if self.small:
            return hypothesis.strategies.integers(-3, 50)

        return hypothesis.strategies.one_of(hypothesis.strategies.integers(), hypothesis.strategies.sampled_from(EDGES))

    def of_type(self, annotation: ast.expr | None) -> Strategy[object]:
        """Generate values for a stub annotation, or arbitrary values if no annotation is given."""
        if annotation is None:
            return self.anything()

        if (builtin := self.builtin(ast.unparse(annotation))) is not None:
            return builtin

        match annotation:
            case ast.BinOp(left=left, op=ast.BitOr(), right=right):
                return hypothesis.strategies.one_of(self.of_type(left), self.of_type(right))
            case ast.Name(id=name) if isinstance(cls := getattr(self.ext, name, None), type):
                return self.instances(cls)
            case ast.Subscript(value=base, slice=index):
                return self.generic(ast.unparse(base), index)
            case _:
                return self.anything()

    def builtin(self, name: str) -> Strategy[object] | None:
        """Generate values for a supported built-in type, or return None."""
        strategies: dict[str, Strategy[object]] = {
            "int": self.integers(),
            "float": hypothesis.strategies.one_of(hypothesis.strategies.floats(), hypothesis.strategies.integers()),
            "str": strings(),
            "bytes": hypothesis.strategies.binary(max_size=16),
            "bool": hypothesis.strategies.booleans(),
            "memoryview": library.fuzzing.buffers.buffers(),
            "collections.abc.Buffer": library.fuzzing.buffers.buffers(),
            "BaseException": hypothesis.strategies.builds(ValueError, strings()),
            "None": hypothesis.strategies.none(),
        }

        return strategies.get(name)

    def generic(self, base: str, index: ast.expr) -> Strategy[object]:
        """Make values of the generic type `base[index]`, such as `list[int]`."""
        strategy: Strategy[object]
        match base, index:
            case "typing.Literal", ast.Tuple(elts=elements):
                literals = [element.value for element in elements if isinstance(element, ast.Constant)]
                strategy = hypothesis.strategies.one_of(hypothesis.strategies.sampled_from(literals), strings())
            case "typing.Literal", ast.Constant(value=literal):
                strategy = hypothesis.strategies.one_of(hypothesis.strategies.just(literal), strings())
            case "type", ast.Name(id=name):
                strategy = hypothesis.strategies.sampled_from([getattr(self.ext, name), self.ext.Square, int, object])
            case "tuple", ast.Tuple(elts=[element, ast.Constant(value=builtins.Ellipsis)]):
                strategy = hypothesis.strategies.lists(self.of_type(element), max_size=4).map(tuple)
            case "tuple", ast.Tuple(elts=elements):
                strategy = hypothesis.strategies.tuples(*map(self.of_type, elements))
            case "collections.abc.Iterable", _:
                items = hypothesis.strategies.lists(self.of_type(index), max_size=4)
                strategy = hypothesis.strategies.one_of(
                    items, items.map(tuple), items.map(iter), items.map(library.fuzzing.hostile.Items)
                )
            case "collections.abc.Mapping" | "dict", _:
                keys = hypothesis.strategies.sampled_from(KEYS)
                strategy = hypothesis.strategies.dictionaries(keys, self.anything(), max_size=6)
            case "list", _:
                strategy = hypothesis.strategies.lists(self.of_type(index), max_size=4)
            case "set" | "frozenset", _:
                strategy = hypothesis.strategies.frozensets(hypothesis.strategies.integers(), max_size=4)
            case _:
                strategy = self.anything()

        return strategy

    def instances(self, cls: type) -> Strategy[object]:
        """Create test class instances or select enum class members."""
        if issubclass(cls, enum.Enum):
            return hypothesis.strategies.sampled_from(list(cls))

        return hypothesis.strategies.builds(lambda: library.fuzzing.instances.make(self.ext, cls))


def containers(items: Strategy[object]) -> Strategy[object]:
    """Generate containers of `items`, including subclasses and containers that empty themselves."""
    lists = hypothesis.strategies.lists(items, max_size=4)
    keys = hypothesis.strategies.sampled_from([*KEYS, 1])

    return hypothesis.strategies.one_of(
        lists,
        lists.map(tuple),
        lists.map(library.fuzzing.hostile.Items),
        lists.map(library.fuzzing.hostile.Row),
        hypothesis.strategies.dictionaries(keys, items, max_size=4),
        hypothesis.strategies.dictionaries(hypothesis.strategies.text(max_size=3), items, max_size=3).map(
            library.fuzzing.hostile.Table
        ),
        hypothesis.strategies.frozensets(hypothesis.strategies.integers(-5, 5), max_size=4),
        hypothesis.strategies.sets(hypothesis.strategies.text(max_size=2), max_size=4),
        hypothesis.strategies.builds(library.fuzzing.hostile.emptying_list, items),
        hypothesis.strategies.builds(library.fuzzing.hostile.emptying_dict, items),
        hypothesis.strategies.builds(library.fuzzing.hostile.emptying_set),
    )


def strings() -> Strategy[str]:
    """Generate strings, including lone surrogates."""
    return hypothesis.strategies.one_of(
        hypothesis.strategies.text(max_size=12),
        hypothesis.strategies.text(hypothesis.strategies.characters(categories=["Cs", "Ll"]), max_size=4),
    )


def spoil(arguments: list[object], value: object, position: int) -> list[object]:
    """Replace an argument at `position`, wrapping the index to fit."""
    spoiled = list(arguments)
    if spoiled:
        spoiled[position % len(spoiled)] = value

    return spoiled
