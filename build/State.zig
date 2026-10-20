const std = @import("std");

const Python = @import("Python.zig");

const State = @This();

b: *std.Build,
python: ?Python = null,
abi3: ?(?[]const u8) = null,
downloader: ?*std.Build.Step.Compile = null,
installed_bundle: bool = false,
bundled: std.ArrayList(Bundled) = .empty,

/// A Python bundle for this CPU, operating system, and ABI.
pub const Bundled = struct {
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,
    abi: std.Target.Abi,
    python: Python,
};

var states: std.ArrayList(*State) = .empty;

/// Get the state of `b`, creating it on first use.
pub fn of(b: *std.Build) *State {
    for (states.items) |state| {
        if (state.b == b) return state;
    }

    const state = b.graph.arena.create(State) catch @panic("OOM");
    state.* = .{ .b = b };
    states.append(b.graph.arena, state) catch @panic("OOM");
    return state;
}
