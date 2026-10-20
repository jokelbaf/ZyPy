const std = @import("std");

const keywords = [_][]const u8{
    "False",   "None",     "True",     "and",    "as",   "assert", "async",  "await",
    "break",   "class",    "continue", "def",    "del",  "elif",   "else",   "except",
    "finally", "for",      "from",     "global", "if",   "import", "in",     "is",
    "lambda",  "nonlocal", "not",      "or",     "pass", "raise",  "return", "try",
    "while",   "with",     "yield",
};

/// Validate `name` as an ASCII Python identifier, rejecting keywords.
/// `what` names it in errors, such as "parameter name".
pub fn checkName(comptime context: []const u8, comptime what: []const u8, comptime name: []const u8) void {
    if (!isIdentifier(name)) {
        @compileError(context ++ ": '" ++ name ++ "' isn't a valid Python " ++ what ++ " (use ASCII letters, digits and _)");
    }
    if (isKeyword(name)) @compileError(context ++ ": '" ++ name ++ "' is a Python keyword, so it can't be a " ++ what);
}

fn isIdentifier(comptime name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    }
    return true;
}

fn isKeyword(comptime name: []const u8) bool {
    return contains(&keywords, name);
}

/// Check whether `names`, such as `&.{ "a", "b" }`, contains `name`.
pub fn contains(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |known| {
        if (std.mem.eql(u8, known, name)) return true;
    }
    return false;
}

/// Write UTF-8 text as an ASCII Python string literal using `quote`. Return `null` for invalid UTF-8.
pub fn string(comptime text: []const u8, comptime quote: u8) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const view = std.unicode.Utf8View.init(text) catch return null;
    var characters = view.iterator();
    var out: []const u8 = &.{quote};
    while (characters.nextCodepoint()) |character| out = out ++ escape(character, quote);
    return out ++ &[_]u8{quote};
}

/// Write `data` as a Python bytes literal, such as `b'raw\n'`.
pub fn bytes(comptime data: []const u8) []const u8 {
    @setEvalBranchQuota(100_000);
    var out: []const u8 = "b'";
    for (data) |byte| out = out ++ escape(byte, '\'');
    return out ++ "'";
}

/// Write a Python float literal with a decimal point or exponent. Return `null` for infinity or NaN.
pub fn float(comptime value: f64) ?[]const u8 {
    if (!std.math.isFinite(value)) return null;

    const magnitude = @abs(value);
    if (magnitude != 0 and (magnitude < 1e-4 or magnitude >= 1e16)) return std.fmt.comptimePrint("{e}", .{value});

    const text = std.fmt.comptimePrint("{d}", .{value});
    return if (std.mem.indexOfScalar(u8, text, '.') == null) text ++ ".0" else text;
}

fn escape(comptime character: u21, comptime quote: u8) []const u8 {
    if (character == quote or character == '\\') return &[_]u8{ '\\', @intCast(character) };
    return switch (character) {
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        ' '...'~' => &[_]u8{@intCast(character)},
        0...8, 0x0b, 0x0c, 0x0e...0x1f, 0x7f...0xff => std.fmt.comptimePrint("\\x{x:0>2}", .{character}),
        0x100...0xffff => std.fmt.comptimePrint("\\u{x:0>4}", .{character}),
        else => std.fmt.comptimePrint("\\U{x:0>8}", .{character}),
    };
}
