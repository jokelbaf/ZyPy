import enum
import gc
import types

import hypothesis.strategies
import pytest

import library.fuzzing.calls
import library.fuzzing.instances
import library.fuzzing.stubs
import library.fuzzing.values

pytestmark = pytest.mark.filterwarnings("ignore::pytest.PytestUnraisableExceptionWarning")


def test_classes(
    ext: types.ModuleType, signatures: dict[str, library.fuzzing.stubs.Signature], subtests: pytest.Subtests
) -> None:
    """Check that fuzzed class operations raise Python exceptions rather than crashing."""
    for cls in classes(ext):
        with subtests.test(cls.__name__):
            fuzz_class(ext, cls, signatures)

    gc.collect()


def fuzz_class(ext: types.ModuleType, cls: type, signatures: dict[str, library.fuzzing.stubs.Signature]) -> None:
    """Fuzz construction, methods, and protocols for `cls`."""
    values = library.fuzzing.values.Values(ext=ext, small=True)
    anything = library.fuzzing.values.Values(ext=ext).anything()
    operands = hypothesis.strategies.tuples(anything, anything, anything)
    methods = hypothesis.strategies.sampled_from(members(cls))

    def check(data: hypothesis.strategies.DataObject) -> None:
        """Create one instance and use it."""
        constructor = data.draw(values.arguments(signatures.get(f"{cls.__name__}.__init__")))
        instance = create(ext, cls, constructor)
        if instance is None:
            return

        method = data.draw(methods)
        member = library.fuzzing.calls.attempt(getattr, instance, method)
        if callable(member):
            data.draw(values.arguments(signatures.get(f"{cls.__name__}.{method}"))).apply(member)

        library.fuzzing.instances.exercise(instance, data.draw(operands))

    library.fuzzing.calls.fuzz(hypothesis.strategies.data(), check)


def create(ext: types.ModuleType, cls: type, constructor: library.fuzzing.calls.Arguments) -> object:
    """Create an instance with the generated arguments, falling back to known valid arguments."""
    instance = constructor.apply(cls)
    return library.fuzzing.instances.make(ext, cls) if instance is None else instance


def classes(ext: types.ModuleType) -> list[type]:
    """List classes to fuzz, excluding exceptions and enums."""
    found = [
        value
        for value in vars(ext).values()
        if isinstance(value, type) and not issubclass(value, (BaseException, enum.Enum))
    ]

    return sorted(found, key=lambda cls: cls.__name__)


def members(cls: type) -> list[str]:
    """List methods, fields, and properties, excluding special methods other than __del__."""
    names = sorted(name for name in vars(cls) if not name.startswith("__") or name == "__del__")
    return names or ["__class__"]
