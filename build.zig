const std = @import("std");

const bundle = @import("build/bundle.zig");
const executable = @import("build/executable.zig");
const extension = @import("build/extension.zig");
const module = @import("build/module.zig");

/// A Python installation to build against, found by `findPython` or `bundledPython`.
pub const Python = @import("build/Python.zig");

pub const ExtensionOptions = extension.Options;
pub const addExtension = extension.add;

pub const ExecutableOptions = executable.Options;
pub const addExecutable = executable.add;
pub const linkPython = executable.linkPython;

pub const ModuleOptions = module.Options;
pub const addModule = module.add;

pub const findPython = Python.find;
pub const bundledPython = bundle.python;
pub const bundled_python_version = bundle.version;

pub fn build(b: *std.Build) void {
    _ = b;
}
