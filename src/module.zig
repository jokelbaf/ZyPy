const std = @import("std");
const c = @import("python");
const options = @import("zypy_options");

const class = @import("class.zig");
const conversion = @import("conversion.zig");
const enum_class = @import("enum_class.zig");
const errors = @import("errors.zig");
const function = @import("function.zig");
const checks = @import("module/checks.zig");
const submodules = @import("module/submodules.zig");
const api = @import("runtime/api.zig");
const borrowed = @import("runtime/borrowed.zig");
const gc = @import("runtime/gc.zig");
const names = @import("runtime/names.zig");
const ownership = @import("runtime/ownership.zig");
const syntax = @import("syntax.zig");
const Object = @import("types/Object.zig");
const Str = @import("types/Str.zig");

const Option = enum { doc, functions, errors, constants, exceptions, classes, enums, submodules, state, subinterpreters, free_threaded };

/// Define a Python module from a struct literal with optional fields:
///
/// - `.doc`: the docstring;
/// - `.functions`: Python names mapped to functions or `py.function(...)`;
/// - `.errors`: module-wide error mappings, such as `.{ .NotFound = .KeyError }`;
/// - `.constants`: Python names mapped to values;
/// - `.exceptions`: Python names mapped to `py.exceptionType` types;
/// - `.classes`: Python names mapped to structs that declare `py.class(...)`;
/// - `.enums`: Python names mapped to enums that declare `py.enumClass(...)`;
/// - `.submodules`: Python names mapped to other `py.module` types;
/// - `.state`: per-module data, passed to functions as `*State`;
/// - `.subinterpreters`: allow imports in subinterpreters with their own GIL;
/// - `.free_threaded`: run without the GIL on free-threaded Python, locking instances and module state during calls.
///
/// Set the module name when exporting with `py.exportModule` or embedding with `py.Interpreter`.
pub fn module(comptime definition: anytype) type {
    @setEvalBranchQuota(100_000);
    const Definition = @TypeOf(definition);
    if (@typeInfo(Definition) != .@"struct") {
        @compileError("py.module: the definition must be a struct literal, such as .{ .functions = .{ .add = add } }");
    }
    inline for (@typeInfo(Definition).@"struct".field_names) |field| {
        if (std.meta.stringToEnum(Option, field) == null) {
            @compileError("py.module: unknown option ." ++ field ++ " (expected .doc, .functions, .errors, " ++
                ".constants, .exceptions, .classes, .enums, .submodules, .state, .subinterpreters or .free_threaded)");
        }
    }

    const doc: ?[:0]const u8 = if (@hasField(Definition, "doc")) function.text("py.module: .doc", definition.doc) else null;
    const functions = if (@hasField(Definition, "functions")) definition.functions else .{};
    const module_errors = if (@hasField(Definition, "errors")) definition.errors else .{};
    const constants = if (@hasField(Definition, "constants")) definition.constants else .{};
    const exceptions = if (@hasField(Definition, "exceptions")) definition.exceptions else .{};
    const classes = if (@hasField(Definition, "classes")) definition.classes else .{};
    const enums = if (@hasField(Definition, "enums")) definition.enums else .{};
    const children = if (@hasField(Definition, "submodules")) definition.submodules else .{};
    const UserState = if (@hasField(Definition, "state")) definition.state else void;
    const subinterpreters: bool = if (@hasField(Definition, "subinterpreters")) definition.subinterpreters else false;
    const supports_free_threading: bool = if (@hasField(Definition, "free_threaded")) definition.free_threaded else false;

    comptime errors.checkMapping("py.module", module_errors, null);
    comptime checks.checkNames(definition);
    const exception_names = checks.names("exceptions", exceptions);
    const class_names = checks.names("classes", classes);
    const enum_names = checks.names("enums", enums);
    const constant_names = checks.names("constants", constants);
    comptime checks.checkExceptions(exceptions);
    comptime checks.checkClasses(classes);
    comptime checks.checkEnums(enums);
    comptime checks.checkSubmodules(children, supports_free_threading, isModule);
    comptime checks.checkState(UserState);
    const keyword_list = comptime keywordNames(functions, classes);
    const EnumMembers = comptime blk: {
        var types: [enum_names.len]type = undefined;
        for (enum_names, &types) |enum_name, *Members| Members.* = enum_class.Members(@field(enums, enum_name));
        break :blk @Tuple(&types);
    };

    return struct {
        const Module = @This();

        pub const error_table = module_errors;
        /// The module's `.state` type, or `void` if it has none.
        pub const State = UserState;
        pub const free_threaded = supports_free_threading;
        /// Whether calls run without the GIL, locking the instances and module state they use.
        pub const runs_without_gil = supports_free_threading and api.free_threaded;
        pub const zypy_module: Marker = .{};
        pub const keyword_names = keyword_list;
        pub const contents = .{
            .doc = doc,
            .functions = functions,
            .constants = constants,
            .exceptions = exceptions,
            .classes = classes,
            .enums = enums,
            .submodules = children,
        };

        const Storage = struct {
            objects: [exception_names.len + class_names.len]?*c.PyObject,
            enum_members: EnumMembers,
            state: State,
            live: bool,
            ready: bool,
            keywords: [keyword_list.len]?*c.PyObject,
            call_names: names.Cache,
        };

        var methods = methodTable(functions, Module);

        var slots = [_]c.PyModuleDef_Slot{
            .{ .slot = c.Py_mod_exec, .value = @ptrCast(@constCast(&exec)) },
            .{
                .slot = c.Py_mod_multiple_interpreters,
                .value = if (subinterpreters)
                    c.Py_MOD_PER_INTERPRETER_GIL_SUPPORTED
                else
                    c.Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED,
            },
            .{ .slot = c.Py_mod_gil, .value = if (supports_free_threading) c.Py_MOD_GIL_NOT_USED else c.Py_MOD_GIL_USED },
            .{ .slot = 0, .value = null },
        };

        /// The module definition, for embedding and submodules.
        pub var def = std.mem.zeroInit(c.PyModuleDef, .{
            .m_base = c.zypy_PyModuleDef_HEAD_INIT,
            .m_name = "ZyPy module",
            .m_doc = if (doc) |text| text.ptr else null,
            .m_size = @sizeOf(Storage),
            .m_methods = &methods,
            .m_slots = &slots,
            .m_traverse = &traverse,
            .m_clear = &clear,
            .m_free = &free,
        });

        /// The initialization function to use with `py.Interpreter.Module.init`.
        pub fn init() callconv(.c) [*c]c.PyObject {
            return c.PyModuleDef_Init(&def);
        }

        /// Get the state of `module_obj`, an instance of this module.
        pub fn stateOf(module_obj: *c.PyObject) errors.Error!*State {
            const storage = storageOf(module_obj) orelse return notReady();
            if (!storage.ready) return notReady();
            return &storage.state;
        }

        /// Get keyword names in `keyword_names` order. Entries are null after cleanup.
        pub fn internedKeywords(module_obj: *c.PyObject) ?*const [keyword_list.len]?*c.PyObject {
            const storage = storageOf(module_obj) orelse return null;
            return &storage.keywords;
        }

        /// Borrow the module defining `tp` or one of its bases. Return `null` if none is found.
        pub fn findModuleOfType(tp: *c.PyTypeObject) ?*c.PyObject {
            return c.PyType_GetModuleByDef(tp, &def) orelse {
                c.PyErr_Clear();
                return null;
            };
        }

        /// Remove this module and its submodules from `loaded` (`sys.modules`) after an import failure.
        pub fn unpublish(loaded: *c.PyObject, module_obj: *c.PyObject) void {
            submodules.unpublish(children, loaded, module_obj);
        }

        fn notReady() errors.Error {
            return errors.raise(.RuntimeError, "the module's state isn't initialized");
        }

        fn storageOf(module_obj: *c.PyObject) ?*Storage {
            return @ptrCast(@alignCast(c.PyModule_GetState(module_obj) orelse return null));
        }

        fn exec(module_obj: [*c]c.PyObject) callconv(.c) c_int {
            const frame = borrowed.enter(runs_without_gil);
            defer frame.leave();

            setUp(module_obj.?) catch return -1;
            return 0;
        }

        fn setUp(module_obj: *c.PyObject) errors.Error!void {
            const storage = storageOf(module_obj).?;
            storage.call_names = .{};
            names.register(&storage.call_names);
            inline for (keyword_list, 0..) |keyword, i| {
                storage.keywords[i] = c.PyUnicode_InternFromString(keyword) orelse return error.PythonError;
            }

            const name = try Str.own(c.PyModule_GetNameObject(module_obj));
            defer name.deinit();

            inline for (exception_names, 0..) |exception_name, i| {
                const Exception = @field(exceptions, exception_name);
                const qualname = try qualified(name, exception_name);
                defer qualname.deinit();

                const base = try errors.exceptionObject(Exception.base);
                defer base.deinit();

                const docstring = if (Exception.doc) |text| text.ptr else null;
                const created = c.PyErr_NewExceptionWithDoc((try qualname.utf8()).ptr, docstring, base.ptr, null) orelse
                    return error.PythonError;
                storage.objects[i] = created;

                try Exception.registry.add(created, module_obj, &def, "exception " ++ exception_name);
                try errors.check(c.PyModule_AddObjectRef(module_obj, exception_name, created));
            }

            inline for (class_names, exception_names.len..) |class_name, i| {
                const T = @field(classes, class_name);
                const qualname = try qualified(name, class_name);
                defer qualname.deinit();

                // The module checks that a base comes earlier in .classes, so its type exists already.
                const base = if (comptime baseIndex(classes, T)) |at| storage.objects[exception_names.len + at] else null;
                const created = try class.Type(T, Module, class_name).create(module_obj, (try qualname.utf8()).ptr, base);
                storage.objects[i] = created;

                try class.registry(T).add(created, module_obj, &def, "class " ++ class_name);
                try errors.check(c.PyModule_AddObjectRef(module_obj, class_name, created));
            }

            inline for (enum_names, 0..) |enum_name, i| {
                const members = &storage.enum_members[i];
                const created = try members.create(name, enum_name);
                defer created.deinit();

                try enum_class.registry(@field(enums, enum_name)).add(members, module_obj, &def, "enum " ++ enum_name);
                try errors.check(c.PyModule_AddObjectRef(module_obj, enum_name, created.ptr));
            }

            // Constants come after classes and enums, so that a constant can be an instance or a member.
            inline for (constant_names) |constant_name| {
                const value = try conversion.toPython(@field(constants, constant_name));
                defer value.deinit();

                try errors.check(c.PyModule_AddObjectRef(module_obj, constant_name, value.ptr));
            }

            if (State != void) storage.state = try initState(module_obj);
            storage.live = true;
            storage.ready = true;

            try submodules.add(children, module_obj, name);
        }

        fn initState(module_obj: *c.PyObject) errors.Error!State {
            if (comptime !@hasDecl(State, "init")) return .{};

            const Init = @TypeOf(State.init);
            const result = if (@typeInfo(Init).@"fn".param_types.len == 0) State.init() else State.init(.borrow(module_obj));
            if (@typeInfo(@TypeOf(result)) != .error_union) return result;
            return result catch |err| errors.raiseZigError(err, .{module_errors});
        }

        fn traverse(module_obj: [*c]c.PyObject, visitor: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
            const storage = storageOf(module_obj.?) orelse return 0;
            for (storage.objects) |object| {
                if (object) |ptr| {
                    const result = visitor.?(ptr, arg);
                    if (result != 0) return result;
                }
            }
            inline for (0..enum_names.len) |i| {
                if (storage.enum_members[i].tuple) |tuple| {
                    const result = visitor.?(tuple, arg);
                    if (result != 0) return result;
                }
            }
            if (storage.live) return gc.visit(&storage.state, visitor, arg);
            return 0;
        }

        fn clear(module_obj: [*c]c.PyObject) callconv(.c) c_int {
            const storage = storageOf(module_obj.?) orelse return 0;
            releaseObjects(module_obj.?, storage);
            storage.ready = false;
            if (storage.live) gc.clear(&storage.state);
            return 0;
        }

        fn free(ptr: ?*anyopaque) callconv(.c) void {
            const module_obj: *c.PyObject = @ptrCast(@alignCast(ptr.?));
            const storage = storageOf(module_obj) orelse return;
            releaseObjects(module_obj, storage);
            storage.ready = false;
            if (storage.live) {
                storage.live = false;
                ownership.release(&storage.state);
            }
        }

        fn releaseObjects(module_obj: *c.PyObject, storage: *Storage) void {
            names.unregister(&storage.call_names);
            storage.call_names.deinit();
            for (&storage.keywords) |*keyword| {
                const obj = keyword.* orelse continue;
                keyword.* = null;
                c.Py_DecRef(obj);
            }
            inline for (exception_names, 0..) |exception_name, i| {
                if (storage.objects[i]) |object| {
                    @field(exceptions, exception_name).registry.remove(module_obj);
                    storage.objects[i] = null;
                    c.Py_DecRef(object);
                }
            }
            inline for (class_names, exception_names.len..) |class_name, i| {
                if (storage.objects[i]) |object| {
                    class.registry(@field(classes, class_name)).remove(module_obj);
                    storage.objects[i] = null;
                    c.Py_DecRef(object);
                }
            }
            inline for (enum_names, 0..) |enum_name, i| {
                enum_class.registry(@field(enums, enum_name)).remove(module_obj);
                storage.enum_members[i].release();
            }
        }
    };
}

const Marker = struct {};

/// Check whether `T` is a type made by `py.module`.
pub fn isModule(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zypy_module") and @TypeOf(T.zypy_module) == Marker;
}

/// Export a module made by `py.module` as the extension being built, named in build.zig.
/// Call it from a `comptime` block in the root file. It does nothing in other builds.
pub fn exportModule(comptime Module: type) void {
    if (!isModule(Module)) @compileError("py.exportModule: expected a type made by py.module, got " ++ @typeName(Module));
    // The program that writes type stubs compiles the root file too, and has no Python to link against.
    if (@hasDecl(@import("root"), "zypy_stub_generator")) return;
    const name = options.extension orelse return;
    const short = name[if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| dot + 1 else 0..];
    @export(&Module.init, .{ .name = "PyInit_" ++ short });
}

fn keywordNames(comptime functions: anytype, comptime classes: anytype) []const [:0]const u8 {
    @setEvalBranchQuota(1_000_000);
    var all: []const [:0]const u8 = &.{};
    for (@typeInfo(@TypeOf(functions)).@"struct".field_names) |name| {
        all = all ++ function.keywordNames(name, @field(functions, name));
    }
    for (@typeInfo(@TypeOf(classes)).@"struct".field_names) |name| all = all ++ class.keywordNames(@field(classes, name));

    var unique: []const [:0]const u8 = &.{};
    for (all) |name| {
        if (!syntax.contains(unique, name)) unique = unique ++ .{name};
    }
    return unique;
}

fn baseIndex(comptime classes: anytype, comptime T: type) ?usize {
    const Base = class.Definition(T).Base orelse return null;
    for (@typeInfo(@TypeOf(classes)).@"struct".field_names, 0..) |name, i| {
        if (@field(classes, name) == Base) return i;
    }
    unreachable;
}

/// Get `<module name>.<name>` as an owned str.
pub fn qualified(module_name: Str, comptime name: [:0]const u8) errors.Error!Str {
    return Str.own(c.PyUnicode_FromFormat("%U." ++ name, module_name.obj.ptr));
}

fn methodTable(
    comptime functions: anytype,
    comptime Module: type,
) [@typeInfo(@TypeOf(functions)).@"struct".field_names.len + 1]c.PyMethodDef {
    const function_names = @typeInfo(@TypeOf(functions)).@"struct".field_names;

    var table: [function_names.len + 1]c.PyMethodDef = undefined;
    inline for (function_names, 0..) |name, i| {
        table[i] = function.methodDef(name, @field(functions, name), .{ .Module = Module });
    }
    table[function_names.len] = std.mem.zeroes(c.PyMethodDef);
    return table;
}
