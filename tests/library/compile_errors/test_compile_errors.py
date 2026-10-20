import pathlib
import subprocess
import sys
import typing

import helpers
import library.compile_errors.cases
import zypy.zig

ROOT: typing.Final = pathlib.Path(__file__).with_name("root.zig")


def test_compile_errors(tmp_path: pathlib.Path) -> None:
    """Check that misused APIs produce helpful compile errors."""
    project = helpers.copy_example("hello", tmp_path)
    (project / "src" / "root.zig").write_text(root_source())

    command = [*zypy.zig.command(), "build", f"-Dpython={sys.executable}"]
    result = subprocess.run(command, cwd=project, capture_output=True, text=True, check=False)
    assert result.returncode != 0

    missing = [message for message in expected_messages() if message not in result.stderr]
    assert missing == [], result.stderr


def root_source() -> str:
    """Generate root.zig with a separate module for each invalid definition."""
    functions = [
        own_module(f"bad_function{index}", f".{{ .functions = .{{ .f = {definition} }} }}")
        for index, (definition, _) in enumerate(library.compile_errors.cases.BAD_FUNCTIONS)
    ]
    modules = [
        own_module(f"bad_module{index}", definition)
        for index, (definition, _) in enumerate(library.compile_errors.cases.BAD_MODULES)
    ]

    return "\n".join([ROOT.read_text(), *functions, *modules])


def own_module(name: str, definition: str) -> str:
    """Generate a module that reports its compile errors independently."""
    return f"const {name} = py.module({definition});\n\ncomptime {{\n    _ = &{name}.init;\n}}\n"


def expected_messages() -> list[str]:
    """List the expected compile errors for invalid API uses."""
    return [
        *library.compile_errors.cases.MISUSES,
        *(message for _, message in library.compile_errors.cases.BAD_FUNCTIONS),
        *(message for _, message in library.compile_errors.cases.BAD_MODULES),
    ]
