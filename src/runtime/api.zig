const c = @import("python");
const options = @import("zypy_options");

/// Whether the extension uses only the limited C API, so that it loads in later Python versions too.
pub const limited = options.limited_api != null;

/// Whether the headers are for free-threaded Python.
pub const free_threaded = @hasDecl(c, "Py_GIL_DISABLED");

const use_functions = limited or free_threaded;

/// Check whether the configured limited API includes `version`, such as `0x030E0000` for Python 3.14.
pub fn hasLimited(comptime version: u32) bool {
    const api = options.limited_api orelse return true;
    return api >= version;
}

pub fn tupleSize(tuple: *c.PyObject) usize {
    return @intCast(if (use_functions) c.PyTuple_Size(tuple) else c.PyTuple_GET_SIZE(tuple));
}

pub fn listSize(list: *c.PyObject) usize {
    return @intCast(if (use_functions) c.PyList_Size(list) else c.PyList_GET_SIZE(list));
}

/// Set item `index` in a new list, taking ownership of the reference to `item`.
pub fn fillList(list: *c.PyObject, index: usize, item: *c.PyObject) void {
    if (use_functions) {
        _ = c.PyList_SetItem(list, @intCast(index), item);
    } else {
        c.PyList_SET_ITEM(list, @intCast(index), item);
    }
}

pub fn bytesData(bytes: *c.PyObject) [*]u8 {
    return if (use_functions) c.PyBytes_AsString(bytes) else c.PyBytes_AS_STRING(bytes);
}

pub fn bytesSize(bytes: *c.PyObject) usize {
    return @intCast(if (use_functions) c.PyBytes_Size(bytes) else c.PyBytes_GET_SIZE(bytes));
}

/// Get the type of `obj`.
pub fn typeOf(obj: *c.PyObject) *c.PyTypeObject {
    return c.Py_TYPE(obj) orelse unreachable;
}

/// Check whether the type of `obj` has a flag such as `Py_TPFLAGS_LIST_SUBCLASS`, as `PyList_Check` does.
pub fn hasTypeFlag(obj: *c.PyObject, flag: c_ulong) bool {
    const flags = if (use_functions) c.PyType_GetFlags(typeOf(obj)) else typeOf(obj).tp_flags;
    return flags & flag != 0;
}

pub fn isStr(obj: *c.PyObject) bool {
    return hasTypeFlag(obj, c.Py_TPFLAGS_UNICODE_SUBCLASS);
}

pub fn isTuple(obj: *c.PyObject) bool {
    return hasTypeFlag(obj, c.Py_TPFLAGS_TUPLE_SUBCLASS);
}

pub fn isList(obj: *c.PyObject) bool {
    return hasTypeFlag(obj, c.Py_TPFLAGS_LIST_SUBCLASS);
}

pub fn isDict(obj: *c.PyObject) bool {
    return hasTypeFlag(obj, c.Py_TPFLAGS_DICT_SUBCLASS);
}

pub fn isBytes(obj: *c.PyObject) bool {
    return hasTypeFlag(obj, c.Py_TPFLAGS_BYTES_SUBCLASS);
}

pub fn isException(obj: *c.PyObject) bool {
    return hasTypeFlag(obj, c.Py_TPFLAGS_BASE_EXC_SUBCLASS);
}

pub fn isType(obj: *c.PyObject) bool {
    return hasTypeFlag(obj, c.Py_TPFLAGS_TYPE_SUBCLASS);
}

/// Get a slot of a type object, such as `tp_free` (slot `Py_tp_free`), as type `T`.
pub fn typeSlot(comptime T: type, tp: *c.PyTypeObject, comptime field: []const u8, comptime slot: c_int) T {
    if (limited) return @ptrCast(@alignCast(c.PyType_GetSlot(tp, slot)));
    return @field(tp.*, field);
}

/// Remove `key` from `dict`. Return 1 if found, 0 if missing, or -1 on error.
/// If `result` is provided, store a new reference to the removed value there.
pub fn dictPop(dict: *c.PyObject, key: *c.PyObject, result: ?*[*c]c.PyObject) c_int {
    if (!limited) return c.PyDict_Pop(dict, key, result);

    if (result) |out| out.* = null;
    // The dict type's own pop skips overrides in subclasses, as PyDict_Pop does.
    const pop = c.PyObject_GetAttrString(@ptrCast(@alignCast(&c.PyDict_Type)), "pop") orelse return -1;
    defer c.Py_DecRef(pop);
    // A new object as the default tells a missing key apart from any stored value.
    const missing = c.PyObject_CallNoArgs(@ptrCast(@alignCast(&c.PyBaseObject_Type))) orelse return -1;
    defer c.Py_DecRef(missing);

    var args = [_][*c]c.PyObject{ dict, key, missing };
    const value = c.PyObject_Vectorcall(pop, &args, args.len, null) orelse return -1;
    if (value == missing) {
        c.Py_DecRef(value);
        return 0;
    }

    if (result) |out| out.* = value else c.Py_DecRef(value);
    return 1;
}

/// The `None` object, borrowed.
pub fn none() *c.PyObject {
    return if (limited) c.Py_GetConstantBorrowed(c.Py_CONSTANT_NONE) else c.Py_None();
}

/// The `NotImplemented` object, borrowed.
pub fn notImplemented() *c.PyObject {
    return if (limited) c.Py_GetConstantBorrowed(c.Py_CONSTANT_NOT_IMPLEMENTED) else @ptrCast(c.Py_NotImplemented());
}

/// Get the current interpreter ID. IDs are never reused; the main interpreter uses 0.
pub fn interpreter() i64 {
    return c.PyInterpreterState_GetID(c.PyInterpreterState_Get());
}
