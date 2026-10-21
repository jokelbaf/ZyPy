const std = @import("std");

const syntax = @import("../syntax.zig");
const defaults = @import("defaults.zig");
const parameters = @import("parameters.zig");

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

/// Build a Python signature from `.params` and `.defaults`. `hidden` marks the parameters ZyPy fills in.
pub fn init(
    comptime name: [:0]const u8,
    comptime types: []const type,
    comptime entries: ?[]const []const u8,
    comptime default_values: anytype,
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
        parameters.applyNames(context, &params, names);
    } else {
        parameters.applyKinds(context, &params);
    }

    if (@typeInfo(@TypeOf(default_values)).@"struct".field_names.len > 0) {
        if (entries == null) @compileError(context ++ ": .defaults needs .params, because defaults are given by name");
        parameters.applyDefaults(context, &params, default_values);
    }
    parameters.applyImplicitNulls(&params);

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
    comptime default_values: anytype,
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
        if (parameters.isMarker(entry)) continue;

        const param = self.params[index];
        index += 1;
        if (self.renderDefault(param, default_values)) |value| text = text ++ "=" ++ value;
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
pub fn renderDefault(comptime self: Signature, comptime param: Param, comptime default_values: anytype) ?[]const u8 {
    return switch (param.default) {
        .none => null,
        .null => "None",
        .value => defaults.render(param.type, @field(default_values, param.name.?), self.defaultContext(param)),
    };
}

/// Identify a parameter default in compile errors, such as "'greet': the default for 'loud'".
pub fn defaultContext(comptime self: Signature, comptime param: Param) []const u8 {
    return "'" ++ self.name ++ "': the default for '" ++ param.name.? ++ "'";
}
