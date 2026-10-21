const std = @import("std");

const function = @import("../function.zig");
const syntax = @import("../syntax.zig");
const Args = @import("../types/Args.zig");
const Kwargs = @import("../types/Kwargs.zig");
const Kind = @import("Signature.zig").Kind;
const Param = @import("Signature.zig").Param;

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
        if (!function.isText(Item)) return false;
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

/// Set the names and kinds of `params` from `entries`, the `.params` option.
pub fn applyNames(comptime context: []const u8, comptime params: []Param, comptime entries: []const []const u8) void {
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

/// Set the kinds of `params` without `.params`: positional-only, `py.Args` or a last `py.Kwargs`.
pub fn applyKinds(comptime context: []const u8, comptime params: []Param) void {
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

/// Apply the `.defaults` values to the matching parameters.
pub fn applyDefaults(comptime context: []const u8, comptime params: []Param, comptime defaults: anytype) void {
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

/// Give trailing optional parameters a `null` default.
pub fn applyImplicitNulls(comptime params: []Param) void {
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

/// Check whether a `.params` entry is the marker `"/"` or `"*"`.
pub fn isMarker(entry: []const u8) bool {
    return std.mem.eql(u8, entry, "/") or std.mem.eql(u8, entry, "*");
}
