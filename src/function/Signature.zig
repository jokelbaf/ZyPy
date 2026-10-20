const std = @import("std");

const enum_class = @import("../enum_class.zig");
const syntax = @import("../syntax.zig");
const Args = @import("../types/Args.zig");
const Kwargs = @import("../types/Kwargs.zig");

const Signature = @This();

name: [:0]const u8,
params: []const Param,
/// Parameters filled by ZyPy, such as the method receiver.
hidden: []const Hidden,
/// Explicit `.params` entries, including markers, or `null` if omitted.
entries: ?[]const []const u8,
positional: usize,
required: usize,
positional_only: usize,
var_positional: ?usize,
var_keyword: ?usize,

pub const Kind = enum { positional_only, positional_or_keyword, keyword_only, var_positional, var_keyword };

pub const Default = enum {
    none,
    /// A trailing `?T` parameter, which gets `null`.
    null,
    /// A value from `.defaults`.
    value,
};

pub const Param = struct {
    /// The parameter name without leading stars, or `null` if `.params` is absent.
    name: ?[:0]const u8,
    kind: Kind,
    type: type,
    default: Default = .none,
    index: usize,

    /// Check whether the parameter can be passed by position.
    pub fn isPositional(self: Param) bool {
        return self.kind == .positional_only or self.kind == .positional_or_keyword;
    }

    /// Check whether the parameter can be passed by keyword.
    pub fn isKeyword(self: Param) bool {
        return self.kind == .positional_or_keyword or self.kind == .keyword_only;
    }
};

/// A Zig parameter that Python doesn't pass.
pub const Hidden = struct {
    pub const Role = enum {
        receiver,
        class,
        state,
    };

    role: Role,
    type: type,
    index: usize,
};

/// Build a Python signature. `hidden` identifies parameters supplied by ZyPy.
pub fn init(
    comptime name: [:0]const u8,
    comptime types: []const type,
    comptime entries: ?[]const []const u8,
    comptime defaults: anytype,
    comptime hidden: []const ?Hidden.Role,
) Signature {
    @setEvalBranchQuota(100_000);
    const context = "'" ++ name ++ "'";

    var visible = 0;
    for (hidden) |role| visible += @intFromBool(role == null);

    var params: [visible]Param = undefined;
    var filled: [types.len - visible]Hidden = undefined;
    var next_param = 0;
    for (types, hidden, 0..) |Type, role, i| {
        if (role) |r| {
            filled[i - next_param] = .{ .role = r, .type = Type, .index = i };
        } else {
            params[next_param] = .{ .name = null, .kind = .positional_only, .type = Type, .index = i };
            next_param += 1;
        }
    }

    if (entries) |names| {
        nameParams(context, &params, names);
    } else {
        kindsWithoutNames(context, &params);
    }

    if (@typeInfo(@TypeOf(defaults)).@"struct".field_names.len > 0) {
        if (entries == null) @compileError(context ++ ": .defaults needs .params, because defaults are given by name");
        explicitDefaults(context, &params, defaults);
    }
    implicitNulls(&params);

    var positional = 0;
    var required = 0;
    var positional_only = 0;
    var var_positional: ?usize = null;
    var var_keyword: ?usize = null;
    var defaulted: ?Param = null;

    for (params, 0..) |param, i| {
        switch (param.kind) {
            .positional_only, .positional_or_keyword => {
                positional += 1;
                if (param.kind == .positional_only) positional_only += 1;

                if (param.default != .none) {
                    defaulted = param;
                } else if (defaulted) |previous| {
                    @compileError(context ++ ": parameter '" ++ param.name.? ++ "' follows '" ++ previous.name.? ++
                        "', which has a default, so it needs a default too (or put it after \"*\")");
                } else {
                    required += 1;
                }
            },
            .keyword_only => {},
            .var_positional => var_positional = i,
            .var_keyword => var_keyword = i,
        }
    }

    const final = params;
    const final_hidden = filled;
    return .{
        .name = name,
        .params = &final,
        .hidden = &final_hidden,
        .entries = entries,
        .positional = positional,
        .required = required,
        .positional_only = positional_only,
        .var_positional = var_positional,
        .var_keyword = var_keyword,
    };
}

/// Check whether the parameters have names from `.params`.
pub fn named(self: Signature) bool {
    return self.entries != null;
}

/// Check whether the wrapper needs the `METH_KEYWORDS` calling convention.
pub fn keywords(self: Signature) bool {
    return self.named() or self.var_keyword != null;
}

/// Check whether any named parameter accepts a keyword argument, excluding `**kwargs`.
pub fn takesKeywordParams(self: Signature) bool {
    for (self.params) |param| {
        if (param.isKeyword()) return true;
    }
    return false;
}

/// The receiver that appears before the arguments in a text signature.
pub const Receiver = enum {
    none,
    instance,
    class,
};

/// Build the docstring header CPython uses for `__text_signature__`.
/// Use the Python `name` without a class prefix. Return `null` if `.params` is absent.
pub fn header(
    comptime self: Signature,
    comptime name: []const u8,
    comptime defaults: anytype,
    comptime receiver: Receiver,
) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const entries = self.entries orelse return null;

    var text: []const u8 = name ++ "(";
    if (receiver != .none) {
        text = text ++ "$" ++ self.receiverName(if (receiver == .instance) "self" else "type");
        // The receiver is positional-only, which a "/" in .params already says.
        if (!syntax.contains(entries, "/")) text = text ++ ", /";
    }
    var index = 0;
    for (entries, 0..) |entry, position| {
        if (position > 0 or receiver != .none) text = text ++ ", ";
        text = text ++ entry;
        if (isMarker(entry)) continue;

        const param = self.params[index];
        index += 1;
        if (self.renderDefault(param, defaults)) |value| text = text ++ "=" ++ value;
    }
    return text ++ ")\n--\n\n";
}

/// Choose a unique receiver name by adding leading underscores when it conflicts with a parameter.
pub fn receiverName(comptime self: Signature, comptime name: []const u8) []const u8 {
    for (self.params) |param| {
        const taken = param.name orelse continue;
        if (std.mem.eql(u8, taken, name)) return self.receiverName("_" ++ name);
    }
    return name;
}

/// Render a parameter default as Python code, `...` for complex values, or `null` if absent.
pub fn renderDefault(comptime self: Signature, comptime param: Param, comptime defaults: anytype) ?[]const u8 {
    return switch (param.default) {
        .none => null,
        .null => "None",
        .value => render(param.type, @field(defaults, param.name.?), self.defaultContext(param)),
    };
}

/// Identify a parameter default in compile errors, such as "'greet': the default for 'loud'".
pub fn defaultContext(comptime self: Signature, comptime param: Param) []const u8 {
    return "'" ++ self.name ++ "': the default for '" ++ param.name.? ++ "'";
}

/// Check whether `T` can use a Zig default value without creating Python objects or views.
pub fn isPlain(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .void => true,
        .@"enum" => !std.meta.hasFn(T, "fromPython"),
        .optional => |info| isPlain(info.child),
        .pointer => T == []const u8,
        .@"struct" => |info| !std.meta.hasFn(T, "fromPython") and allPlain(info.field_types),
        else => false,
    };
}

fn allPlain(comptime types: []const type) bool {
    for (types) |Type| {
        if (!isPlain(Type)) return false;
    }
    return true;
}

/// Convert a default value to `T`, reporting incompatible types or out-of-range values.
pub fn coerce(comptime T: type, comptime value: anytype, comptime what: []const u8) T {
    const V = @TypeOf(value);
    if (V == T) return value;

    const fits = switch (@typeInfo(T)) {
        .optional => |info| return if (V == @TypeOf(null)) null else coerce(info.child, value, what),
        .int => V == comptime_int or @typeInfo(V) == .int,
        .float => V == comptime_float or V == comptime_int or @typeInfo(V) == .float,
        .bool => V == bool,
        .@"enum" => V == @EnumLiteral(),
        else => true,
    };
    if (!fits) @compileError(what ++ " must have type " ++ @typeName(T) ++ ", not " ++ @typeName(V));

    switch (@typeInfo(T)) {
        .int => return std.math.cast(T, value) orelse @compileError(what ++ " is out of range for " ++ @typeName(T)),
        .@"enum" => {
            if (!@hasField(T, @tagName(value))) {
                @compileError(what ++ " ." ++ @tagName(value) ++ " isn't a tag of " ++ @typeName(T));
            }
            return @field(T, @tagName(value));
        },
        else => return value,
    }
}

/// Read `.params` from a tuple, array, or slice.
pub fn list(comptime context: []const u8, comptime params: anytype) []const []const u8 {
    const P = @TypeOf(params);
    if (@typeInfo(P) == .@"struct" and @typeInfo(P).@"struct".is_tuple) return list(context, &params);
    if (!isStringList(P)) @compileError(context ++ ": .params must list names, such as &.{ \"name\", \"/\", \"greeting\" }");
    return params;
}

fn isStringList(comptime P: type) bool {
    const items = listItems(P) orelse return false;
    for (items) |Item| {
        if (!isText(Item)) return false;
    }
    return true;
}

fn listItems(comptime P: type) ?[]const type {
    const pointer = switch (@typeInfo(P)) {
        .pointer => |info| info,
        else => return null,
    };
    switch (@typeInfo(pointer.child)) {
        .@"struct" => |info| return if (info.is_tuple) info.field_types else null,
        .array => |info| return &.{info.child},
        else => {},
    }
    if (pointer.size == .slice) return &.{pointer.child};
    return null;
}

/// Check whether `T` is a byte slice or a pointer to a byte array.
pub fn isText(comptime T: type) bool {
    const pointer = switch (@typeInfo(T)) {
        .pointer => |info| info,
        else => return false,
    };
    return switch (pointer.size) {
        .slice => pointer.child == u8,
        .one => @typeInfo(pointer.child) == .array and @typeInfo(pointer.child).array.child == u8,
        else => false,
    };
}

fn nameParams(comptime context: []const u8, comptime params: []Param, comptime entries: []const []const u8) void {
    var index = 0;
    var kind: Kind = .positional_or_keyword;
    var slash = false;
    var star = false;

    for (entries, 0..) |entry, position| {
        const next: ?[]const u8 = if (position + 1 < entries.len) entries[position + 1] else null;

        if (std.mem.eql(u8, entry, "/")) {
            if (slash) @compileError(context ++ ": .params has more than one \"/\"");
            if (star) @compileError(context ++ ": \"/\" must come before \"*\" in .params");
            if (index == 0) @compileError(context ++ ": \"/\" must follow at least one parameter in .params");
            for (params[0..index]) |*param| param.kind = .positional_only;
            slash = true;
            continue;
        }
        if (std.mem.eql(u8, entry, "*")) {
            if (star) @compileError(context ++ ": .params can have only one \"*\" or \"*name\"");
            if (next == null or std.mem.startsWith(u8, next.?, "**")) {
                @compileError(context ++ ": \"*\" must be followed by a parameter name in .params");
            }
            star = true;
            kind = .keyword_only;
            continue;
        }

        if (index == params.len) {
            @compileError(context ++ ": .params names more parameters than the function has (" ++ count(params.len) ++ ")");
        }
        const param = &params[index];
        index += 1;

        if (std.mem.startsWith(u8, entry, "**")) {
            if (next != null) @compileError(context ++ ": \"" ++ entry ++ "\" must be last in .params");
            param.kind = .var_keyword;
            param.name = identifier(context, entry[2..]);
            if (param.type != Kwargs) {
                @compileError(context ++ ": parameter \"" ++ entry ++ "\" must be a py.Kwargs, got " ++ @typeName(param.type));
            }
        } else if (std.mem.startsWith(u8, entry, "*")) {
            if (star) @compileError(context ++ ": .params can have only one \"*\" or \"*name\"");
            star = true;
            kind = .keyword_only;
            param.kind = .var_positional;
            param.name = identifier(context, entry[1..]);
            if (param.type != Args) {
                @compileError(context ++ ": parameter \"" ++ entry ++ "\" must be a py.Args, got " ++ @typeName(param.type));
            }
        } else {
            param.kind = kind;
            param.name = identifier(context, entry);
            if (param.type == Args) @compileError(context ++ ": parameter '" ++ entry ++ "' is a py.Args, so write it as \"*" ++ entry ++ "\"");
            if (param.type == Kwargs) @compileError(context ++ ": parameter '" ++ entry ++ "' is a py.Kwargs, so write it as \"**" ++ entry ++ "\"");
        }

        for (params[0 .. index - 1]) |previous| {
            if (std.mem.eql(u8, previous.name.?, param.name.?)) {
                @compileError(context ++ ": .params has '" ++ param.name.? ++ "' more than once");
            }
        }
    }

    if (index != params.len) {
        @compileError(context ++ ": .params names " ++ count(index) ++ ", but the function has " ++ count(params.len));
    }
}

fn count(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d} parameter{s}", .{ n, if (n == 1) "" else "s" });
}

fn kindsWithoutNames(comptime context: []const u8, comptime params: []Param) void {
    var args = false;
    for (params, 0..) |*param, i| {
        if (param.type == Kwargs) {
            if (i + 1 != params.len) @compileError(context ++ ": a py.Kwargs parameter must be the last one");
            param.kind = .var_keyword;
        } else if (param.type == Args) {
            if (args) @compileError(context ++ ": only one parameter can be a py.Args");
            args = true;
            param.kind = .var_positional;
        } else if (args) {
            @compileError(context ++ ": parameters after a py.Args are keyword-only, so they need names in .params");
        }
    }
}

fn explicitDefaults(comptime context: []const u8, comptime params: []Param, comptime defaults: anytype) void {
    const info = @typeInfo(@TypeOf(defaults));
    if (info != .@"struct" or (info.@"struct".is_tuple and info.@"struct".field_names.len > 0)) {
        @compileError(context ++ ": .defaults must be a struct such as .{ .greeting = \"Hello\" }");
    }

    for (info.@"struct".field_names) |field| {
        const param = findParam(params, field) orelse
            @compileError(context ++ ": .defaults has '" ++ field ++ "', which isn't in .params");
        if (param.kind == .var_positional or param.kind == .var_keyword) {
            @compileError(context ++ ": '" ++ field ++ "' collects extra arguments, so it can't have a default");
        }
        param.default = .value;
    }
}

fn findParam(comptime params: []Param, comptime name: []const u8) ?*Param {
    for (params) |*param| {
        if (std.mem.eql(u8, param.name.?, name)) return param;
    }
    return null;
}

fn implicitNulls(comptime params: []Param) void {
    var omittable = true;
    var i = params.len;
    while (i > 0) {
        i -= 1;
        const param = &params[i];
        if (param.kind == .var_positional or param.kind == .var_keyword) continue;

        if (param.default == .none and omittable and @typeInfo(param.type) == .optional) param.default = .null;
        omittable = omittable and param.default != .none;
    }
}

fn identifier(comptime context: []const u8, comptime name: []const u8) [:0]const u8 {
    syntax.checkName(context, "parameter name", name);
    return std.fmt.comptimePrint("{s}", .{name});
}

fn isMarker(entry: []const u8) bool {
    return std.mem.eql(u8, entry, "/") or std.mem.eql(u8, entry, "*");
}

fn render(comptime T: type, comptime value: anytype, comptime what: []const u8) []const u8 {
    const V = @TypeOf(value);
    if (V == @TypeOf(null)) return "None";
    if (V == T and @typeInfo(T) == .@"struct" and @hasDecl(T, "zypy_owned")) {
        return render(@FieldType(T, "value"), value.value, what);
    }
    if (isPlain(T)) return renderValue(T, coerce(T, value, what));
    return renderValue(V, value);
}

fn renderValue(comptime T: type, comptime value: T) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => if (value) "True" else "False",
        .int, .comptime_int => std.fmt.comptimePrint("{d}", .{value}),
        .float, .comptime_float => syntax.float(value) orelse "...",
        .optional => |info| if (value) |inner| renderValue(info.child, inner) else "None",
        // inspect accepts only literals in text signatures, so enum members cannot appear here.
        .@"enum" => if (enum_class.isEnumClass(T)) "..." else syntax.string(@tagName(value), '\'') orelse "...",
        .enum_literal => syntax.string(@tagName(value), '\'') orelse "...",
        .pointer => renderText(T, value),
        else => "...",
    };
}

fn renderText(comptime T: type, comptime value: T) []const u8 {
    if (T == []const u8) return syntax.bytes(value);
    if (!isText(T)) return "...";
    return syntax.string(value, '\'') orelse "...";
}
