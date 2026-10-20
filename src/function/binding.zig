const std = @import("std");
const c = @import("python");

const errors = @import("../errors.zig");
const api = @import("../runtime/api.zig");
const Dict = @import("../types/Dict.zig");
const Signature = @import("Signature.zig");

/// Bind arguments using `signature` and report errors with `label`.
/// `module_names` lists the module's keyword names.
pub fn Binding(comptime label: []const u8, comptime signature: Signature, comptime module_names: []const [:0]const u8) type {
    const arity = signature.params.len;

    return struct {
        /// Borrowed arguments by parameter, with `null` for omitted arguments.
        pub const Slots = [arity]?*c.PyObject;

        /// The arguments of a call, bound to the parameters.
        pub const Bound = struct {
            slots: Slots,
            extra: []const [*c]c.PyObject,
            /// Keyword arguments that name no parameter, for `**kwargs`, or `null` if there are none.
            kwargs: ?Dict,

            /// Release the `**kwargs` dict.
            pub fn deinit(self: Bound) void {
                if (self.kwargs) |dict| dict.deinit();
            }
        };

        /// Bind positional and keyword arguments to parameters.
        /// Raise `TypeError` for missing, extra, or duplicate arguments. `interned` may be `null`.
        pub fn bind(
            given: []const [*c]c.PyObject,
            keyword_values: []const [*c]c.PyObject,
            kwnames: ?*c.PyObject,
            interned: ?*const [module_names.len]?*c.PyObject,
        ) errors.Error!Bound {
            if (comptime !signature.named()) {
                const too_many = signature.var_positional == null and given.len > signature.positional;
                if (given.len < signature.required or too_many) return argumentCountError(given.len);
            }

            var bound: Bound = .{ .slots = @splat(null), .extra = &.{}, .kwargs = null };
            errdefer bound.deinit();
            const positional = @min(given.len, signature.positional);
            for (bound.slots[0..positional], given[0..positional]) |*slot, arg| slot.* = arg;
            bound.extra = given[positional..];

            if (kwnames) |names| try bindKeywords(&bound, names, keyword_values, interned);

            if (comptime signature.named()) {
                if (signature.var_positional == null and bound.extra.len > 0) return tooManyPositional(given.len, &bound.slots);
                try checkMissing(.positional, &bound.slots);
                try checkMissing(.keyword_only, &bound.slots);
            }
            return bound;
        }

        fn bindKeywords(
            bound: *Bound,
            names: *c.PyObject,
            values: []const [*c]c.PyObject,
            interned: ?*const [module_names.len]?*c.PyObject,
        ) errors.Error!void {
            for (values, 0..) |value, k| {
                const key: *c.PyObject = c.PyTuple_GetItem(names, @intCast(k)) orelse return error.PythonError;
                if (!api.isStr(key)) return errors.raise(.TypeError, label ++ "() keywords must be strings");

                const index = if (comptime signature.takesKeywordParams()) try keywordIndex(key, interned) else null;
                if (index) |i| {
                    if (bound.slots[i] != null) {
                        _ = c.PyErr_Format(c.PyExc_TypeError, label ++ "() got multiple values for argument '%S'", key);
                        return error.PythonError;
                    }
                    bound.slots[i] = value;
                    continue;
                }

                if (comptime signature.var_keyword == null) return unexpectedKeyword(names, key);
                const dict = bound.kwargs orelse try Dict.init();
                bound.kwargs = dict;
                try errors.check(c.PyDict_SetItem(dict.obj.ptr, key, value));
            }
        }

        fn keywordIndex(key: *c.PyObject, interned: ?*const [module_names.len]?*c.PyObject) errors.Error!?usize {
            if (interned) |names| {
                inline for (signature.params, 0..) |param, i| {
                    if (comptime param.isKeyword()) {
                        if (names[comptime moduleIndex(param.name.?)] == key) return i;
                    }
                }
            }

            var size: c.Py_ssize_t = undefined;
            const data = c.PyUnicode_AsUTF8AndSize(key, &size) orelse {
                // Strs with lone surrogates have no UTF-8 text, so they name no parameter.
                if (c.PyErr_ExceptionMatches(c.PyExc_UnicodeEncodeError) == 0) return error.PythonError;
                c.PyErr_Clear();
                return null;
            };
            const text = data[0..@intCast(size)];
            inline for (signature.params, 0..) |param, i| {
                if (comptime param.isKeyword()) {
                    if (std.mem.eql(u8, text, param.name.?)) return i;
                }
            }
            return null;
        }

        fn moduleIndex(comptime name: []const u8) usize {
            for (module_names, 0..) |known, i| {
                if (std.mem.eql(u8, known, name)) return i;
            }
            @compileError(label ++ ": '" ++ name ++ "' isn't among the module's keyword names");
        }

        fn unexpectedKeyword(names: *c.PyObject, key: *c.PyObject) errors.Error {
            var conflicts: [arity][]const u8 = undefined;
            var count: usize = 0;

            if (comptime signature.named()) inline for (signature.params[0..signature.positional_only]) |param| {
                if (hasName(names, param.name.?)) {
                    conflicts[count] = param.name.?;
                    count += 1;
                }
            };

            if (count > 0) {
                var buffer: [256]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&buffer);
                for (conflicts[0..count], 0..) |conflict, i| {
                    writer.print("{s}{s}", .{ if (i == 0) "" else ", ", conflict }) catch break;
                }
                return errors.raiseFmt(.TypeError, label ++
                    "() got some positional-only arguments passed as keyword arguments: '{s}'", .{writer.buffered()});
            }

            _ = c.PyErr_Format(c.PyExc_TypeError, label ++ "() got an unexpected keyword argument '%S'", key);
            return error.PythonError;
        }

        fn tooManyPositional(given: usize, slots: *const Slots) errors.Error {
            const takes = comptime if (signature.required < signature.positional)
                std.fmt.comptimePrint("from {d} to {d} positional arguments", .{ signature.required, signature.positional })
            else
                std.fmt.comptimePrint("{d} positional argument{s}", .{ signature.positional, plural(signature.positional) });

            var keyword_only: usize = 0;
            inline for (signature.params, 0..) |param, i| {
                if (param.kind == .keyword_only and slots[i] != null) keyword_only += 1;
            }

            if (keyword_only > 0) {
                return errors.raiseFmt(.TypeError, label ++ "() takes " ++ takes ++
                    " but {d} positional argument{s} (and {d} keyword-only argument{s}) were given", .{
                    given, plural(given), keyword_only, plural(keyword_only),
                });
            }
            return errors.raiseFmt(.TypeError, label ++ "() takes " ++ takes ++ " but {d} {s} given", .{
                given, if (given == 1) "was" else "were",
            });
        }

        fn checkMissing(comptime kind: enum { positional, keyword_only }, slots: *const Slots) errors.Error!void {
            var missing: [arity][]const u8 = undefined;
            var count: usize = 0;

            inline for (signature.params, 0..) |param, i| {
                const wanted = switch (kind) {
                    .positional => param.isPositional(),
                    .keyword_only => param.kind == .keyword_only,
                };
                if (wanted and param.default == .none and slots[i] == null) {
                    missing[count] = param.name.?;
                    count += 1;
                }
            }

            if (count == 0) return;

            var buffer: [256]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            for (missing[0..count], 0..) |param, i| {
                writer.print("{s}'{s}'", .{ separator(i, count), param }) catch break;
            }

            const kind_label = if (kind == .positional) "positional" else "keyword-only";
            return errors.raiseFmt(.TypeError, label ++ "() missing {d} required " ++ kind_label ++ " argument{s}: {s}", .{
                count, plural(count), writer.buffered(),
            });
        }

        fn argumentCountError(given: usize) errors.Error {
            const fixed = signature.var_positional == null and signature.required == signature.positional;
            if (fixed) {
                const takes = switch (signature.required) {
                    0 => "no arguments",
                    1 => "exactly one argument",
                    else => std.fmt.comptimePrint("{d} arguments", .{signature.required}),
                };
                return errors.raiseFmt(.TypeError, label ++ "() takes " ++ takes ++ " ({d} given)", .{given});
            }
            if (given < signature.required) {
                return errors.raiseFmt(.TypeError, label ++ "() takes at least " ++
                    comptime arguments(signature.required) ++ " ({d} given)", .{given});
            }
            return errors.raiseFmt(.TypeError, label ++ "() takes at most " ++
                comptime arguments(signature.positional) ++ " ({d} given)", .{given});
        }
    };
}

fn separator(index: usize, count: usize) []const u8 {
    if (index == 0) return "";
    if (count == 2) return " and ";
    if (index + 1 == count) return ", and ";
    return ", ";
}

fn hasName(names: *c.PyObject, wanted: [:0]const u8) bool {
    const count = api.tupleSize(names);
    for (0..count) |k| {
        if (c.PyUnicode_EqualToUTF8(c.PyTuple_GetItem(names, @intCast(k)), wanted) != 0) return true;
    }
    return false;
}

fn arguments(comptime count: usize) []const u8 {
    return std.fmt.comptimePrint("{d} argument{s}", .{ count, plural(count) });
}

fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}
