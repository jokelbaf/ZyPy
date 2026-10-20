import types

import pytest

import library.fuzzing.stubs


@pytest.fixture(scope="session")
def signatures(ext: types.ModuleType) -> dict[str, library.fuzzing.stubs.Signature]:
    """Read the signatures of tests/ext's functions and methods from its type stub."""
    return library.fuzzing.stubs.read(ext)
