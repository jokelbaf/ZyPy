import typing

MISUSES: typing.Final = (
    "ZyPy can't convert a new object to []const u8: a []const u8 would point into an object",
    "ZyPy can't convert a new object to ?struct { i64, []const u8 }",
    'expected a tuple of arguments, such as .{ 1, "x" }, got comptime_int',
    "expected a struct of keyword arguments, such as .{ .indent = 2 }",
    "unknown built-in exception .NoSuchError (expected a name such as .ValueError)",
    "py.Args can only be a parameter of an exported function",
    "py.allowThreads: parameter 1 is a",
    "py.FrozenSet can't change (use py.Set)",
    "(values without names can't become str)",
    "ZyPy can't convert a new object to root.structWithBytes__struct",
    "root.Resource has a deinit, so ZyPy can't hand out copies of it (take *const root.Resource instead)",
    "ZyPy can't convert *root.Pt (return root.Pt or py.Instance(root.Pt) instead)",
    "py.raise: expected an exception name such as .ValueError, or a type made by py.exceptionType, got i64",
    "py.Instance(i64) needs a class: declare pub const class = py.class(...) in it",
    "py.Class(i64) needs a class: declare pub const class = py.class(...) in it",
    "ZyPy can't convert a new object to *const root.Pt: the pointer would point into an object that is released",
    "zypy: to generate type stubs, declare the module as pub const module = py.module(...)",
    "ZyPy can't convert a mapping to root.nameLength__struct",
    "field 'name' would point into a value that the struct can't keep alive (use py.Bytes)",
    "root.Flagged has an owned field but no deinit: a value with an owned field owns what its fromPython returns",
    "expected a method name as a string literal or a py.Str, got [:0]const u8 (use py.Str.init for names",
)

BAD_FUNCTIONS: typing.Final = (
    (
        'py.function(pair, .{ .docs = "x" })',
        "py.function: unknown option .docs (expected .doc, .params, .defaults, .errors or .release_gil)",
    ),
    ("py.function(pair, .{ .doc = 5 })", "'f': .doc must be a string or null, not comptime_int"),
    ('py.function(pair, .{ .params = &.{"a"} })', "'f': .params names 1 parameter, but the function has 2 parameters"),
    ('py.function(pair, .{ .params = &.{ "a", "a" } })', "'f': .params has 'a' more than once"),
    ('py.function(pair, .{ .params = &.{ "a b", "c" } })', "'f': 'a b' isn't a valid Python parameter name"),
    ('py.function(pair, .{ .params = &.{ "class", "b" } })', "'f': 'class' is a Python keyword"),
    (
        'py.function(pair, .{ .params = &.{ "имя", "b" } })',
        "'f': 'имя' isn't a valid Python parameter name (use ASCII letters, digits and _)",
    ),
    ('py.function(pair, .{ .params = &.{ "/", "a", "b" } })', "'f': \"/\" must follow at least one parameter"),
    ('py.function(pair, .{ .params = &.{ "a", "b", "*" } })', "'f': \"*\" must be followed by a parameter name"),
    (
        'py.function(pair, .{ .params = &.{ "a", "b" }, .defaults = .{ .z = 1 } })',
        "'f': .defaults has 'z', which isn't in .params",
    ),
    ("py.function(pair, .{ .defaults = .{ .a = 1 } })", "'f': .defaults needs .params"),
    (
        'py.function(pair, .{ .params = &.{ "a", "b" }, .defaults = .{ .b = "x" } })',
        "'f': the default for 'b' must have type i64, not *const [1:0]u8",
    ),
    (
        'py.function(small, .{ .params = &.{"a"}, .defaults = .{ .a = 300 } })',
        "'f': the default for 'a' is out of range for u8",
    ),
    (
        'py.function(pair, .{ .params = &.{ "a", "b" }, .defaults = .{ .a = 1 } })',
        "'f': parameter 'b' follows 'a', which has a default, so it needs a default too",
    ),
    (
        "py.function(fallible, .{ .errors = .{ .Nope = .ValueError } })",
        "'f': .errors maps error.Nope, which the function never returns",
    ),
    (
        "py.function(pair, .{ .errors = .{ .Nope = .ValueError } })",
        "'f': .errors needs a function that returns an error union",
    ),
    (
        "py.function(fallible, .{ .errors = .{ .PythonError = .ValueError } })",
        "'f': .errors can't map error.PythonError",
    ),
    (
        "py.function(fallible, .{ .errors = .{ .Negative = .NoSuchError } })",
        "unknown built-in exception .NoSuchError",
    ),
    (
        "py.function(fallible, .{ .errors = .{ .Negative = .{ .ValueError, 5 } } })",
        "'f': .errors maps error.Negative to a message of type comptime_int (use a string literal)",
    ),
    ("py.function(isNone, .{ .release_gil = true })", "'f': .release_gil can't be used with parameter 1"),
    (
        'py.function(takesArgs, .{ .params = &.{ "a", "rest" } })',
        "'f': parameter 'rest' is a py.Args, so write it as \"*rest\"",
    ),
    (
        "py.function(useLease, .{})",
        "'f': parameter 1 holds a root.Lease, which has a deinit but no owned field, so the function could release it",
    ),
    (
        "py.function(oddItems, .{})",
        "ZyPy can't view buffers of u24 (use bool, f16, f32, f64, or an integer of 8, 16, 32 or 64 bits)",
    ),
    ('py.function(pair, .{ .doc = "a\\x00b" })', "'f': .doc can't contain zero bytes"),
    ('py.function(pair, .{ .doc = "\\xff" })', "'f': .doc must be UTF-8 text"),
)

BAD_MODULES: typing.Final = (
    (
        ".{ .exceptions = .{ .Bad = py.exceptionType(5) } }",
        "py.exceptionType: the options must be a struct literal, such as .{ .base = .ValueError }",
    ),
    (
        ".{ .classs = .{} }",
        (
            "py.module: unknown option .classs (expected .doc, .functions, .errors, .constants, .exceptions, "
            ".classes, .enums, .submodules, .state, .subinterpreters or .free_threaded)"
        ),
    ),
    (
        ".{ .classes = .{ .Plain = Plain } }",
        "py.module: .classes has 'Plain', which needs to be a struct with a pub const class = py.class(...)",
    ),
    (
        ".{ .classes = .{ .BadOption = BadOption } }",
        (
            "py.class: unknown option .docs (expected .doc, .base, .fields, .methods, .properties, .init, "
            ".subclassable, .weak_references or .dict)"
        ),
    ),
    (
        ".{ .classes = .{ .Getter = Getter } }",
        "'Getter': ZyPy doesn't support __getattribute__ (use __getattr__, which runs when the usual lookup finds",
    ),
    (".{ .classes = .{ .Awaitable = Awaitable } }", "'Awaitable': ZyPy doesn't support __await__ yet"),
    (
        ".{ .classes = .{ .Modular = Modular } }",
        "'Modular': the modulo parameter of __pow__ must be optional, such as ?i64, because a ** b passes none",
    ),
    (
        ".{ .classes = .{ .Setter = Setter } }",
        "'Setter': __setattr__ must return void, or bool to say whether it handled the attribute",
    ),
    (
        ".{ .classes = .{ .ShadowedDict = ShadowedDict } }",
        "'ShadowedDict': the class has .dict, so it can't have a field named '__dict__'",
    ),
    (
        ".{ .classes = .{ .Holder = Holder } }",
        "'Holder': field 'obj' holds Python objects, so declare it as py.Owned(py.Object), which keeps a reference",
    ),
    (".{ .classes = .{ .NoField = NoField } }", "'NoField': .fields has 'z', which isn't a field of root.NoField"),
    (
        ".{ .classes = .{ .SpecialField = SpecialField } }",
        "'SpecialField': '__len__' is the name of a special method, so it can't be a field",
    ),
    (
        ".{ .classes = .{ .DictMethod = DictMethod } }",
        "'DictMethod': the class has .dict, so it can't have a method named '__dict__'",
    ),
    (".{ .classes = .{ .Twice = Twice } }", "'Twice': 'size' is both a field and a method"),
    (
        ".{ .classes = .{ .Keyworded = Keyworded } }",
        "'Keyworded': .methods: 'class' is a Python keyword, so it can't be a method name",
    ),
    (
        ".{ .classes = .{ .Spaced = Spaced } }",
        "'Spaced': .properties: 'some thing' isn't a valid Python attribute name (use ASCII letters, digits and _)",
    ),
    (".{ .classes = .{ .Endless = Endless } }", "'Endless': __next__ must return an optional, such as ?i64"),
    (".{ .classes = .{ .BadDeinit = BadDeinit } }", "'BadDeinit': deinit must take only the instance"),
    (".{ .classes = .{ .ViewHolder = ViewHolder } }", "can only hold Python objects and plain values, not views"),
    (".{ .classes = .{ .SliceHolder = SliceHolder } }", "can't hold a []const u8, which would point into an object"),
    (".{ .classes = .{ .SliceArrayHolder = SliceArrayHolder } }", "py.Owned([1][]const u8) can't hold a []const u8"),
    (
        ".{ .classes = .{ .Target = Target, .RawHolder = RawHolder } }",
        (
            "'RawHolder': field 'target' points into an instance of root.Target without keeping it alive, "
            "so declare it as py.Owned(py.Instance(root.Target))"
        ),
    ),
    (
        ".{ .classes = .{ .Target = Target, .OwnedPointer = OwnedPointer } }",
        "'OwnedPointer': field 'target' points into an instance of root.Target without keeping it alive",
    ),
    (".{ .classes = .{ .SetterResult = SetterResult } }", "'SetterResult': __setitem__ must return void"),
    (
        ".{ .classes = .{ .PropertyResult = PropertyResult } }",
        "'PropertyResult': the setter of property 'value' must return void or an error union of it",
    ),
    (
        ".{ .exceptions = .{ .A = SameError, .B = SameError } }",
        "py.module: 'B' and 'A' are the same exception type",
    ),
    (
        ".{ .exceptions = .{ .Child = ChildError, .Base = BaseError } }",
        "py.module: list the base of 'Child' before it in .exceptions",
    ),
    (
        ".{ .functions = .{ .clash = pair }, .constants = .{ .clash = 1 } }",
        "py.module: 'clash' is in both .functions and .constants (a module has one value per name)",
    ),
    (
        '.{ .functions = .{ .@"not valid" = pair } }',
        "py.module: .functions: 'not valid' isn't a valid Python name (use ASCII letters, digits and _)",
    ),
    ('.{ .constants = .{ .@"import" = 1 } }', "py.module: .constants: 'import' is a Python keyword"),
    (
        ".{ .state = Counted, .functions = .{ .bump = py.function(bump, .{ .release_gil = true }) } }",
        (
            "'bump': .release_gil can't be used with a *root.Counted parameter: other threads can use the "
            "module's state while the GIL is released"
        ),
    ),
    (".{ .classes = .{ .Releaser = Releaser } }", "'Releaser': __release_buffer__ needs __buffer__"),
    (
        ".{ .classes = .{ .ClassRepr = ClassRepr } }",
        "'ClassRepr.__repr__' must take the instance first, such as self: *const root.ClassRepr",
    ),
    (
        ".{ .classes = .{ .Final = Final, .FromFinal = FromFinal } }",
        "'FromFinal': its base root.Final doesn't allow subclasses (set .subclassable = true in its py.class)",
    ),
    (
        ".{ .classes = .{ .Open = Open, .Misplaced = Misplaced } }",
        (
            "'Misplaced': root.Misplaced must hold its base in its first field, such as base: root.Open "
            "align(py.base_alignment)"
        ),
    ),
    (
        ".{ .classes = .{ .Open = Open, .Unaligned = Unaligned } }",
        (
            "'Unaligned': declare the base field as base: root.Open align(py.base_alignment), which keeps it at the "
            "start of root.Unaligned on every target (Zig orders fields by alignment)"
        ),
    ),
    (
        ".{ .classes = .{ .ValueBase = ValueBase } }",
        "py.class(root.ValueBase): .base must be a class, not a value of type comptime_int",
    ),
    (
        ".{ .classes = .{ .Orphan = Orphan } }",
        (
            "py.module: 'Orphan' inherits from root.Open, so list that class in .classes too, before 'Orphan' "
            "(a class and its base must be in the same module)"
        ),
    ),
    (
        ".{ .classes = .{ .Orphan = Orphan, .Open = Open } }",
        "py.module: list the base of 'Orphan' before it in .classes",
    ),
    (
        ".{ .enums = .{ .Plain = PlainEnum } }",
        "py.module: .enums: 'Plain' needs to be an enum with a pub const class = py.enumClass(...) declaration",
    ),
    (
        ".{ .enums = .{ .Reserved = Reserved } }",
        "py.module: .enums: 'Reserved': enum.Enum reserves the name 'mro'",
    ),
    (".{ .enums = .{ .Keyword = Keyword } }", "py.module: .enums: 'Keyword': 'lambda' is a Python keyword"),
    (".{ .enums = .{ .A = Shade, .B = Shade } }", "py.module: .enums lists root.Shade twice"),
    (
        ".{ .enums = .{ .Shade = Shade }, .constants = .{ .Shade = 1 } }",
        "py.module: 'Shade' is in both .constants and .enums (a module has one value per name)",
    ),
    (".{ .enums = .{ .BadEnum = BadEnumOption } }", "py.enumClass: unknown option .docs (expected .doc)"),
    (".{ .state = NeedsInit }", "py.module: root.NeedsInit needs an init function, or a default value for 'n'"),
    (".{ .state = ObjectState }", "py.module: .state: field 'obj' holds Python objects"),
    (
        ".{ .free_threaded = true, .submodules = .{ .plain = py.module(.{}) } }",
        "py.module: the module is .free_threaded, so submodule 'plain' must set .free_threaded = true too",
    ),
    (
        ".{ .free_threaded = true, .classes = .{ .Target = Target }, .functions = .{ .three = threeTargets } }",
        (
            "'three': a call in a .free_threaded module locks at most two objects (the instance it's called on, "
            "the module for its state, and instances passed by pointer), but this one needs 3"
        ),
    ),
)
