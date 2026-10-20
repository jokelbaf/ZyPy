const std = @import("std");
const c = @import("python");

const conversion = @import("conversion.zig");
const errors = @import("errors.zig");
const Dict = @import("types/Dict.zig");
const Object = @import("types/Object.zig");

/// Import a module, such as `py.import("json")` or `py.import("os.path")`.
/// The result is owned. Release it with `deinit` or return it to Python.
pub fn import(name: [:0]const u8) errors.Error!Object {
    return .own(c.PyImport_ImportModule(name.ptr));
}

/// Run Python statements in the namespace of `__main__`, as a script would.
pub fn run(code: [:0]const u8) errors.Error!void {
    const main = try mainModule();
    defer main.deinit();

    const result = try evaluate(c.PyModule_GetDict(main.ptr).?, code, c.Py_file_input);
    result.deinit();
}

/// Run Python statements with `globals` as their namespace. Names they define are added to `globals`.
pub fn runIn(globals: Dict, code: [:0]const u8) errors.Error!void {
    const result = try evaluate(globals.obj.ptr, code, c.Py_file_input);
    result.deinit();
}

/// Evaluate a Python expression in the namespace of `__main__` and convert its value to `T`.
/// References and views in the result are owned.
pub fn eval(comptime T: type, expression: [:0]const u8) errors.Error!T {
    const main = try mainModule();
    defer main.deinit();

    return conversion.take(T, try evaluate(c.PyModule_GetDict(main.ptr).?, expression, c.Py_eval_input));
}

/// Evaluate a Python expression with `globals` as its namespace and convert its value to `T`.
/// References and views in the result are owned.
pub fn evalIn(comptime T: type, globals: Dict, expression: [:0]const u8) errors.Error!T {
    return conversion.take(T, try evaluate(globals.obj.ptr, expression, c.Py_eval_input));
}

fn mainModule() errors.Error!Object {
    return .own(c.PyImport_AddModuleRef("__main__"));
}

fn evaluate(globals: *c.PyObject, code: [:0]const u8, start: c_int) errors.Error!Object {
    // Like Python's eval(), ignore spaces and tabs before an expression.
    const skip = if (start == c.Py_eval_input) std.mem.indexOfNone(u8, code, " \t") orelse code.len else 0;

    const compiled = try Object.own(c.Py_CompileString(code[skip..].ptr, "<string>", start));
    defer compiled.deinit();

    return .own(c.PyEval_EvalCode(compiled.ptr, globals, globals));
}
