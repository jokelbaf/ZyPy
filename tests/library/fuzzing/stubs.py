import ast
import pathlib
import types
import typing


class Signature(typing.NamedTuple):
    """Parameter annotations, excluding method receivers."""

    positional: list[ast.expr | None]
    keywords: dict[str, ast.expr | None]


def read(ext: types.ModuleType) -> dict[str, Signature]:
    """Read function and method signatures from the test extension's stubs."""
    assert ext.__file__ is not None
    stub = pathlib.Path(ext.__file__).parent / "zypy_tests" / "__init__.pyi"
    signatures: dict[str, Signature] = {}

    for node in ast.parse(stub.read_text()).body:
        if isinstance(node, ast.FunctionDef):
            signatures[node.name] = signature(node, receiver=False)
        elif isinstance(node, ast.ClassDef):
            for method in methods(node):
                signatures[f"{node.name}.{method.name}"] = signature(method, receiver=not is_static(method))

    return signatures


def methods(cls: ast.ClassDef) -> list[ast.FunctionDef]:
    """List the methods that a class declares."""
    return [member for member in cls.body if isinstance(member, ast.FunctionDef)]


def is_static(method: ast.FunctionDef) -> bool:
    """Check whether `method` is declared static."""
    return any(ast.unparse(decorator) == "staticmethod" for decorator in method.decorator_list)


def signature(function: ast.FunctionDef, *, receiver: bool) -> Signature:
    """Read parameter annotations, excluding any method receiver."""
    parameters = function.args
    positional = [parameter.annotation for parameter in [*parameters.posonlyargs, *parameters.args]]
    keywords = {parameter.arg: parameter.annotation for parameter in parameters.kwonlyargs}

    return Signature(positional[1:] if receiver else positional, keywords)
