const c = @import("python");

const errors = @import("../errors.zig");
const module = @import("../module.zig");
const Object = @import("../types/Object.zig");
const Str = @import("../types/Str.zig");

/// Initialize submodules of `parent` and register them as attributes and in `sys.modules`.
/// Remove newly registered submodules if setup fails.
pub fn add(comptime submodules: anytype, parent: *c.PyObject, name: Str) errors.Error!void {
    const submodule_names = @typeInfo(@TypeOf(submodules)).@"struct".field_names;
    if (submodule_names.len == 0) return;

    const machinery = try Object.own(c.PyImport_ImportModule("importlib.machinery"));
    defer machinery.deinit();
    const loaded: *c.PyObject = c.PyImport_GetModuleDict() orelse return error.PythonError;

    var children: [submodule_names.len]?*c.PyObject = @splat(null);
    defer for (children) |child| if (child) |ptr| c.Py_DecRef(ptr);
    errdefer {
        const exception = c.PyErr_GetRaisedException();
        defer c.PyErr_SetRaisedException(exception);
        inline for (submodule_names, children) |submodule_name, child| {
            if (child) |ptr| @field(submodules, submodule_name).unpublish(loaded, ptr);
        }
    }

    inline for (submodule_names, 0..) |submodule_name, i| {
        const Submodule = @field(submodules, submodule_name);
        const qualname = try module.qualified(name, submodule_name);
        defer qualname.deinit();

        const spec = try machinery.callMethod(Object, "ModuleSpec", .{ qualname, null });
        defer spec.deinit();

        const created = try Object.own(c.PyModule_FromDefAndSpec(&Submodule.def, spec.ptr));
        children[i] = created.ptr;

        try errors.check(c.PyModule_ExecDef(created.ptr, &Submodule.def));
        try created.setAttr("__spec__", spec);
        try errors.check(c.PyModule_AddObjectRef(parent, submodule_name, created.ptr));
        try errors.check(c.PyDict_SetItem(loaded, qualname.obj.ptr, created.ptr));
    }
}

/// Remove this module and its submodules from `sys.modules` after import failure.
/// Keep entries that another module has replaced.
pub fn unpublish(comptime submodules: anytype, loaded: *c.PyObject, module_obj: *c.PyObject) void {
    inline for (@typeInfo(@TypeOf(submodules)).@"struct".field_names) |submodule_name| {
        const Submodule = @field(submodules, submodule_name);
        var child: [*c]c.PyObject = null;
        if (c.PyObject_GetOptionalAttrString(module_obj, submodule_name, &child) > 0) {
            defer c.Py_DecRef(child);
            if (c.PyObject_TypeCheck(child, &c.PyModule_Type) != 0 and c.PyModule_GetDef(child) == &Submodule.def) {
                Submodule.unpublish(loaded, child);
            }
        }
    }
    removeEntry(loaded, module_obj);
    c.PyErr_Clear();
}

fn removeEntry(loaded: *c.PyObject, module_obj: *c.PyObject) void {
    const name = c.PyModule_GetNameObject(module_obj) orelse return;
    defer c.Py_DecRef(name);

    var entry: [*c]c.PyObject = null;
    if (c.PyDict_GetItemRef(loaded, name, &entry) <= 0) return;
    defer c.Py_DecRef(entry);

    if (entry == module_obj) _ = c.PyDict_DelItem(loaded, name);
}
